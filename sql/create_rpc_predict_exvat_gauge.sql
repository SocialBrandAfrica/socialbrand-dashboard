-- create_rpc_predict_exvat_gauge.sql
-- SB-CC-PREDICT-001 step 1: the ex-VAT finance gauge (canon RULE-BOOK §3, PREDICT-001 §1/§7.1).
-- Applied live 2026-07-18, migrations predict_01_purchases_to_sales_target_config +
-- predict_02b_gauge_pct_literal_fix.
--
-- Source-only, whole-store (PREDICT-001 §10 ruling 2), the one number finance needs today. Corrects
-- the VAT basis: sales_exvat = sales_incl_vat - vat_value (native, never a flat /1.15); purchases and
-- COGS at cost_value (already ex-VAT). The 82% purchases-to-sales target is only meaningful ex-VAT --
-- on an incl-VAT basis it reads ~62-73% and is meaningless. COGS is cost-error-clean (l2_classification
-- bucket='COST_ERROR' excluded, canon §12c); an implausible GP is SURFACED via gp_health, not hidden --
-- the gauge's job is to EXPOSE contamination. Layer-2 published interface (R30/R32): outputs read it,
-- never recompute. Ratios are ACTUALS (R22); the projection/need is step 2 and carries PROVISIONAL.
--
-- R22 proof (last 8 budget weeks 2026-05-23..07-17): ex-VAT ratio 77.1/83.5/74.3/71.1/41.4 (matches the
-- spec's 71-84%), incl-VAT 69.0/72.6/66.3/62.0/36.2 (62-73%), GP ex-VAT 19.8/-0.7/19.4/16.5/10.5 (the
-- healthy SPARs 15-19%, 21355 -0.7% = the cost-error contamination the gauge is meant to expose).

-- Config: the target ratio (DEMO_CALIBRATION, canon v11 item 3). forge_config is the generic registry.
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
  ('purchases_to_sales_target', '*', 0.82, 'DEMO_CALIBRATION', '2026-07-18',
   'PREDICT-001: target ratio of purchases(cost) to EX-VAT sales (canon v11 item 3). The gauge reads on sales_exvat = sales_incl_vat - vat_value; on an incl-VAT basis the 82% target is meaningless (reads ~62-73%).')
ON CONFLICT (config_key, store_format) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpc_predict_exvat_gauge(
  p_date_from   date,
  p_date_to     date,
  p_store_codes text[] DEFAULT NULL,
  p_gp_floor_pct numeric DEFAULT 5
)
RETURNS TABLE (
  store_code text,
  sales_incl numeric, sales_exvat numeric,
  purchases_cost numeric,
  cogs_raw numeric, cogs_clean numeric, cost_error_cogs numeric, cost_error_lines int,
  ratio_exvat_pct numeric, ratio_incl_pct numeric, target_pct numeric, vs_target_pp numeric,
  gp_exvat_clean_pct numeric, gp_exvat_raw_pct numeric,
  gp_health text, evidence text
)
LANGUAGE sql STABLE SET search_path = public AS $fn$
WITH params AS (
  SELECT COALESCE((SELECT value_num FROM forge_config WHERE config_key='purchases_to_sales_target' AND store_format='*'), 0.82) AS tgt
),
stores_scope AS (
  SELECT s.store_code FROM stores s
  WHERE s.is_active AND (p_store_codes IS NULL OR s.store_code = ANY(p_store_codes))
),
cost_err AS (
  SELECT DISTINCT c.store_code, c.product_code
  FROM l2_classification c
  JOIN (SELECT store_code, max(snapshot_date) msd FROM l2_classification GROUP BY 1) mx
    ON mx.store_code=c.store_code AND mx.msd=c.snapshot_date
  WHERE c.bucket='COST_ERROR'
),
sales AS (
  SELECT ss.store_code,
    SUM(ss.sales_incl_vat) AS sales_incl,
    SUM(ss.sales_incl_vat - ss.vat_value) AS sales_exvat,
    SUM(ss.cost_value) AS cogs_raw,
    SUM(ss.cost_value) FILTER (WHERE ce.product_code IS NULL) AS cogs_clean,
    SUM(ss.cost_value) FILTER (WHERE ce.product_code IS NOT NULL) AS cost_error_cogs,
    count(DISTINCT ss.product_code) FILTER (WHERE ce.product_code IS NOT NULL) AS cost_error_lines
  FROM sigma_sales ss
  JOIN stores_scope sc ON sc.store_code = ss.store_code
  LEFT JOIN cost_err ce ON ce.store_code=ss.store_code AND ce.product_code=ss.product_code
  WHERE ss.period_kind='T' AND ss.txn_kind=1
    AND ss.sale_date BETWEEN p_date_from AND p_date_to
  GROUP BY ss.store_code
),
purch AS (
  SELECT m.store_code, SUM(m.cost_value) AS purchases_cost
  FROM sigma_movements m
  JOIN stores_scope sc ON sc.store_code = m.store_code
  WHERE m.movement_type='R' AND m.movement_process='W'
    AND m.movement_date BETWEEN p_date_from AND p_date_to
  GROUP BY m.store_code
)
SELECT
  sc.store_code,
  round(COALESCE(s.sales_incl,0)) , round(COALESCE(s.sales_exvat,0)),
  round(COALESCE(p.purchases_cost,0)),
  round(COALESCE(s.cogs_raw,0)), round(COALESCE(s.cogs_clean,0)), round(COALESCE(s.cost_error_cogs,0)),
  COALESCE(s.cost_error_lines,0)::int,
  round(100.0*p.purchases_cost/NULLIF(s.sales_exvat,0),1),
  round(100.0*p.purchases_cost/NULLIF(s.sales_incl,0),1),
  round(pr.tgt*100,1),
  round(100.0*p.purchases_cost/NULLIF(s.sales_exvat,0) - pr.tgt*100,1),
  round(100.0*(s.sales_exvat - s.cogs_clean)/NULLIF(s.sales_exvat,0),1),
  round(100.0*(s.sales_exvat - s.cogs_raw)/NULLIF(s.sales_exvat,0),1),
  CASE WHEN 100.0*(s.sales_exvat - s.cogs_clean)/NULLIF(s.sales_exvat,0) < p_gp_floor_pct
       THEN 'REVIEW: GP below '||p_gp_floor_pct||'% -- cost-error contamination likely, feed the cost-error worklist (canon 12c)'
       ELSE 'ok' END,
  format('ex-VAT basis (sales_incl-vat_value) %s..%s; purchases=R/W cost; COGS clean excludes %s COST_ERROR line(s) R%s; target %s%% (DEMO_CALIBRATION, canon v11)',
    p_date_from, p_date_to, COALESCE(s.cost_error_lines,0), round(COALESCE(s.cost_error_cogs,0)), round(pr.tgt*100,1))
FROM stores_scope sc
CROSS JOIN params pr
LEFT JOIN sales s ON s.store_code=sc.store_code
LEFT JOIN purch p ON p.store_code=sc.store_code
ORDER BY sc.store_code
$fn$;

REVOKE ALL ON FUNCTION public.rpc_predict_exvat_gauge(date,date,text[],numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_predict_exvat_gauge(date,date,text[],numeric) TO authenticated;
