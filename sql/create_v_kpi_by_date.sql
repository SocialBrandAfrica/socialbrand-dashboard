-- =============================================================================
-- create_v_kpi_by_date.sql
-- SB-CC-DASH-SOURCE-002 Step 1 (SB-INDEX-005 Phase 2).
-- Deployed 2026-06-13 via Supabase MCP migration
--   dash_source_002_step1_v_kpi_by_date_leftjoin_pushdown. Canonical source.
-- =============================================================================
-- WHAT THIS STEP DOES:
--   Re-sources the SALES FACTS of v_kpi_by_date (the dashboard's primary KPI
--   view) from PRSSALE (daily_snapshots) onto the Sigma-native exact ledger
--   (sigma_sales / DBUMBA, period_kind='T' AND txn_kind=1):
--     total_sales        = SUM(sales_incl_vat)             was SUM(today_sales)
--     total_cost         = SUM(cost_value)  (dEKUmsatz)    was SUM(today_cost)
--     total_sales_ex_vat = SUM(sales_incl_vat - vat_value) native VAT
--                          (was today_sales/(1 + vat_pct/100), flat-1.15 approx)
--   Real GP% is now derivable downstream from exact ex-VAT + exact cost.
--   Reconcile (2026-06-13, latest date 06-12): view total_sales/ex_vat/cost ==
--   direct sigma_sales sums to the rand on all 5 stores; GP% 10116 18.3 / 21355
--   13.0 / 80175 19.4 / 80176 17.1 / 80579 14.8 %.
--
-- HELD ON PRSSALE THIS STEP (deliberate):
--   total_qty -- Sigma qty diverges ~+20% at 10116 (7,361 PRSSALE vs 8,835
--   Sigma on 06-12); unit definition (weighed/scale vs each) unconfirmed.
--   Stock facts (neg_soh_count, slow_mover_count, capital_tied,
--   ghost_stock_value, store_name) stay on daily_snapshots -- a later step.
--
-- DATE SET: unchanged (driven by daily_snapshots) so single-date card queries
--   keep predicate pushdown into idx_ds_store_date (94ms). A FULL OUTER union
--   with sigma_sales (to surface missed-EOD days like 10116 2026-05-29) blocked
--   pushdown and full-scanned 18M rows (51s -- would time out live). The date
--   picker is fed by push_log + mv_kpi_by_date (NOT this view), so sigma-only
--   missed-EOD days are not selectable here anyway; recovering them belongs to
--   the later step that moves the driving/stock source + mv_kpi_by_date onto
--   sigma-native.
--
-- Rule 19: DROP + clean CREATE. No dependent views (verified). anon SELECT.
-- =============================================================================

DROP VIEW IF EXISTS public.v_kpi_by_date;

CREATE VIEW public.v_kpi_by_date AS
WITH sales AS (
  SELECT
    ss.store_code,
    ss.sale_date,
    round(sum(ss.sales_incl_vat), 2) AS total_sales,
    round(sum(ss.cost_value), 2) AS total_cost,
    round(sum(ss.sales_incl_vat - ss.vat_value), 2) AS total_sales_ex_vat
  FROM sigma_sales ss
  WHERE ss.period_kind = 'T' AND ss.txn_kind = 1
  GROUP BY ss.store_code, ss.sale_date
)
SELECT
  ds.store_code,
  ds.store_name,
  ds.snapshot_date,
  sa.total_sales,
  sa.total_cost,
  sum(ds.today_qty) AS total_qty,
  count(*) FILTER (WHERE ds.soh < 0::numeric) AS neg_soh_count,
  count(*) FILTER (WHERE ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) IS NULL
      AND NOT (is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
               AND (ds.last_sales_date_iso IS NULL OR ds.last_sales_date_iso < (CURRENT_DATE - '30 days'::interval)))
    ) AS slow_mover_count,
  round(sum(
      CASE WHEN ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
            AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) IS NULL
            AND NOT (is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                     AND (ds.last_sales_date_iso IS NULL OR ds.last_sales_date_iso < (CURRENT_DATE - '30 days'::interval)))
           THEN ds.soh * COALESCE(ds.unit_cost, 0::numeric) ELSE 0::numeric END), 2) AS capital_tied,
  sa.total_sales_ex_vat,
  round(sum(
      CASE WHEN ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
            AND ((classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) = ANY (ARRAY['PRODUCTION'::text, 'NON_STOCK'::text]))
                 OR is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                    AND (ds.last_sales_date_iso IS NULL OR ds.last_sales_date_iso < (CURRENT_DATE - '30 days'::interval)))
           THEN ds.soh * COALESCE(ds.unit_cost, 0::numeric) ELSE 0::numeric END), 2) AS ghost_stock_value
FROM daily_snapshots ds
LEFT JOIN sales sa
  ON sa.store_code = ds.store_code AND sa.sale_date = ds.snapshot_date
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date, sa.total_sales, sa.total_cost, sa.total_sales_ex_vat;

GRANT SELECT ON public.v_kpi_by_date TO anon, authenticated;
