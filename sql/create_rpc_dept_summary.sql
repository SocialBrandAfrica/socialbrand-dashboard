-- =============================================================================
-- create_rpc_dept_summary.sql
-- SB-CC-DASH-SOURCE-002 Step 3 (SB-INDEX-005 Phase 2).
-- Deployed 2026-06-13 via Supabase MCP migrations
--   dash_source_002_step3_rpc_dept_summary_sales_to_sigma +
--   dash_source_002_step3_rpc_dept_summary_unmapped_bucket. Canonical source.
-- =============================================================================
-- WHAT THIS STEP DOES:
--   Re-sources the SALES FACTS of rpc_dept_summary (dept-aware KPI cards incl.
--   LY/WoW per RULE-BOOK selection-scope) onto sigma_sales (DBUMBA exact ledger):
--     total_sales        = SUM(sales_incl_vat)
--     total_cost         = SUM(cost_value)  (dEKUmsatz)
--     total_sales_ex_vat = SUM(sales_incl_vat - vat_value)  native per-line VAT
--   NEW COLUMN total_sales_ex_vat: the frontend already reads
--   r.total_sales_ex_vat (page.jsx) but the function never returned it -> the
--   dept-path GP% was blank. Now returned, real, ex-VAT -> correct dept GP%.
--
--   Sigma-native dept grouping: sigma_articles.department_nr ->
--   sigma_departments.name (24/24 aligned to daily_snapshots.dept_name at 10116).
--   LEFT JOINs + COALESCE(...,'UNMAPPED') so sigma_sales rows whose product_code
--   has no article/department (recycled/deleted codes, ~0.035%) are surfaced in
--   an UNMAPPED dept row, never silently dropped (R22/R23). Result reconciles to
--   sigma_sales to the rand on all 5 stores.
--   Filters reproduced sigma-side: p_subdept via sigma_subdepts.name
--   (merch_group_nr; 432/438 names aligned); p_eans via product_catalog bridge
--   ean -> sigma_product_code = sigma_articles.product_code (96.8% of eans
--   bridge; the rest are unresolved/identity codes).
--
-- SB-CC-RETIRE-003 (2026-07-02) -- R28 lineage:
--   * total_qty RESTORED from sigma_sales SUM(qty) (selling-units convention,
--     RULE-BOOK section 2 quantity family: units sold, never weight). It was
--     dropped at RETIRE-001 because the PRSSALE today_qty source diverged ~20%
--     from Sigma; summing the Sigma ledger itself has no divergence.
--   * capital_tied repointed l2_stock_position raw (class=NORMAL, soh>0) ->
--     ENGINE PURIFIED scope (l2_classification latest snapshot/store, bucket IN
--     HEALTHY/COUNT/AMBIGUOUS/LEAVE_COUNTED, canon 8.8) so dept-filtered cards
--     match the purified Capital Tied headline (v_l2_capital_by_store). The raw
--     chip stays available whole-store via v_kpi_by_date.capital_tied.
--   Prior daily_snapshots stock facts retired at RETIRE-001 (e875402,
--   2026-06-28); the old "HELD on PRSSALE" note here was stale prose.
--   FULL OUTER on dept_name so a dept with sales-but-no-qualifying-stock (or
--   vice versa) still returns.
--
-- Reconcile (2026-06-13, 06-12): whole-store rpc total == sigma_sales to the
--   rand x5 (UNMAPPED = R81.00 at 10116); GP% 10116 18.3% (real ex-VAT).
--
-- Function-change protocol (RULE-BOOK §8): single overload; DROP then CREATE
--   (return signature gains total_sales_ex_vat); reload schema. SECURITY DEFINER,
--   anon + authenticated EXECUTE.
--
-- PERF (2026-06-13): converted to plpgsql, v_dates pre-cast ONCE so the date
--   predicates keep their indexes (same gotcha that timed out rpc_focus_top5).
--   Helps the sigma leg; whole-call 2.86s -> 2.43s on the 5-store x 14-day period
--   view, 170ms on the single-store/date page default. The daily_snapshots
--   capital residual cleared at RETIRE-001; the capital leg now reads the
--   engine table at its latest snapshot per store (small, indexed).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text, text[]);

CREATE FUNCTION public.rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_subdept     text   DEFAULT NULL,
    p_eans        text[] DEFAULT NULL
)
RETURNS TABLE(dept_name text, total_sales numeric, total_cost numeric, total_qty numeric, total_sales_ex_vat numeric, capital_tied numeric)
-- NOT marked STABLE: the body does SET LOCAL statement_timeout, which Postgres
-- forbids in non-volatile functions (caught live 2026-07-02, hotfixed minutes
-- later via retire003_rpc_dept_summary_fix_volatility).
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_dates date[] := p_dates::date[];   -- pre-cast ONCE
BEGIN
    SET LOCAL statement_timeout = '60s';
  RETURN QUERY
  WITH sigma_dept AS (
    SELECT COALESCE(sd.name, 'UNMAPPED') AS dept_name,
           ROUND(SUM(ss.sales_incl_vat)::numeric, 2)               AS total_sales,
           ROUND(SUM(ss.cost_value)::numeric, 2)                   AS total_cost,
           ROUND(SUM(ss.qty)::numeric, 2)                          AS total_qty,
           ROUND(SUM(ss.sales_incl_vat - ss.vat_value)::numeric, 2) AS total_sales_ex_vat
    FROM   sigma_sales ss
    LEFT   JOIN sigma_articles a    ON a.store_code = ss.store_code AND a.product_code = ss.product_code
    LEFT   JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
    LEFT   JOIN sigma_subdepts sub  ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
    WHERE  ss.store_code = ANY(p_store_codes)
      AND  ss.sale_date  = ANY(v_dates)                  -- pre-cast date[] (index-safe, Rule 4)
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
      AND  (p_subdept IS NULL OR sub.name = p_subdept)
      AND  (p_eans IS NULL OR a.product_code IN (
              SELECT NULLIF(regexp_replace(pc.sigma_product_code, '\D', '', 'g'), '')::bigint
              FROM   product_catalog pc
              WHERE  pc.store_code = ANY(p_store_codes)
                AND  pc.ean = ANY(p_eans)
                AND  pc.sigma_product_code ~ '^[0-9]+$'))
    GROUP  BY COALESCE(sd.name, 'UNMAPPED')
  ),
  -- SB-CC-RETIRE-003: capital_tied = ENGINE PURIFIED (canon 8.8), mirroring
  -- v_l2_capital_by_store scope rules at dept grain: l2_classification at the
  -- latest snapshot per store, SUM(capital_value) over the include-set buckets
  -- HEALTHY / COUNT / AMBIGUOUS / LEAVE_COUNTED. Depts holding only excluded
  -- buckets (NON_STOCK, COST_ERROR, DEPOSIT, zeros) return NULL capital by
  -- design -- excluded capital is surfaced in its own reports, never here.
  -- p_eans filter via v_ean_bridge is an EAN-FILTERED selection (R20 addendum:
  -- INNER-style is correct for selections, never for totals).
  latest AS (
    SELECT lc.store_code, MAX(lc.snapshot_date) AS d
    FROM   l2_classification lc
    WHERE  lc.store_code = ANY(p_store_codes)
    GROUP  BY lc.store_code
  ),
  sigma_cap AS (
    SELECT
      COALESCE(lc.dept_name, 'UNMAPPED') AS dept_name,
      ROUND(SUM(lc.capital_value) FILTER (
        WHERE lc.bucket IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED')
      )::numeric, 2) AS capital_tied
    FROM l2_classification lc
    JOIN latest l ON l.store_code = lc.store_code AND lc.snapshot_date = l.d
    WHERE (p_subdept IS NULL OR lc.subdept_name = p_subdept)
      AND (p_eans    IS NULL OR lc.product_code IN (
            SELECT b.product_code FROM v_ean_bridge b
            WHERE b.store_code = ANY(p_store_codes) AND b.ean = ANY(p_eans)
          ))
    GROUP BY COALESCE(lc.dept_name, 'UNMAPPED')
  )
  SELECT COALESCE(s.dept_name, c.dept_name) AS dept_name,
         s.total_sales,
         s.total_cost,
         s.total_qty,
         s.total_sales_ex_vat,
         c.capital_tied
  FROM   sigma_dept s
  FULL OUTER JOIN sigma_cap c ON c.dept_name = s.dept_name
  ORDER  BY COALESCE(s.dept_name, c.dept_name);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text, text[]) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
