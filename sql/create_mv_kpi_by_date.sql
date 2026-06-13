-- =============================================================================
-- create_mv_kpi_by_date.sql
-- SB-CC-DASH-SOURCE-002 Step 2 (SB-INDEX-005 Phase 2).
-- Deployed 2026-06-13 via Supabase MCP migration
--   dash_source_002_step2_mv_kpi_by_date_sales_to_sigma. Canonical source.
-- =============================================================================
-- WHAT THIS STEP DOES:
--   (a) Re-sources the SALES FACTS of mv_kpi_by_date (date-picker source +
--       multi-date KPI source) onto sigma_sales (DBUMBA exact ledger,
--       period_kind='T' AND txn_kind=1):
--         total_sales        = SUM(sales_incl_vat)
--         total_sales_ex_vat = SUM(sales_incl_vat - vat_value)  native VAT
--         total_cost         = SUM(cost_value)  (dEKUmsatz)
--   (b) RECOVERS the missed-EOD days PRSSALE dropped. Because this matview is
--       pre-aggregated and refreshed nightly (NOT latency-bound), the FULL OUTER
--       (store_code, date) union is used here -- unlike v_kpi_by_date (step 1),
--       where it would have blocked predicate pushdown. 45 trading days return:
--       10116 x11 (incl. 2026-05-29 R383,387.74 = the FEED-001 day), 80579 x32,
--       21355 x1, 80176 x1.
--
-- HELD on PRSSALE: total_qty (Sigma qty diverges ~20% at 10116; unit def
--   unconfirmed). Stock facts (neg_soh_count, slow_mover_count, capital_tied,
--   ghost_stock_value) keep THIS matview's existing formulas (note: no
--   is_fresh_perishable exclusion -- intentionally unchanged from prior def),
--   from daily_snapshots -- a later migration step.
--   On sigma-only recovered days stock facts are NULL (no snapshot; R22
--   surface-not-hide). On prssale-only days (e.g. 80176 2025-12-25 Christmas,
--   store closed -> no sigma trade) sales are NULL.
--
-- Reconcile (2026-06-13): sales/ex_vat/cost delta 0.00 to the rand on all 5
--   stores at 06-12; 10116 2026-05-29 present at R383,387.74.
--
-- TRANSITIONAL NOTE: the date picker (push_log + this matview) will now offer
--   the 45 recovered days, but v_kpi_by_date single-date cards (step 1, still
--   daily_snapshots-driven date set) have no row for them yet. Resolves when a
--   later step moves v_kpi_by_date's driving/stock source onto sigma-native.
--
-- Rule 19: DROP + clean CREATE. Atomic txn. anon/authenticated SELECT.
-- =============================================================================
SET statement_timeout = '10min';

DROP MATERIALIZED VIEW IF EXISTS public.mv_kpi_by_date;

CREATE MATERIALIZED VIEW public.mv_kpi_by_date AS
WITH stock AS (
  SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,
    sum(ds.today_qty) AS total_qty,
    count(*) FILTER (WHERE ds.soh < 0::numeric) AS neg_soh_count,
    count(*) FILTER (WHERE ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
        AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) IS NULL) AS slow_mover_count,
    round(sum(
        CASE WHEN ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
              AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) IS NULL
             THEN ds.soh * COALESCE(ds.unit_cost, 0::numeric) ELSE 0::numeric END), 2) AS capital_tied,
    round(sum(
        CASE WHEN ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
              AND (classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso) = ANY (ARRAY['PRODUCTION'::text, 'NON_STOCK'::text]))
             THEN ds.soh * COALESCE(ds.unit_cost, 0::numeric) ELSE 0::numeric END), 2) AS ghost_stock_value
  FROM daily_snapshots ds
  GROUP BY ds.store_code, ds.store_name, ds.snapshot_date
),
sales AS (
  SELECT
    ss.store_code,
    ss.sale_date,
    round(sum(ss.sales_incl_vat), 2) AS total_sales,
    round(sum(ss.sales_incl_vat - ss.vat_value), 2) AS total_sales_ex_vat,
    round(sum(ss.cost_value), 2) AS total_cost
  FROM sigma_sales ss
  WHERE ss.period_kind = 'T' AND ss.txn_kind = 1
  GROUP BY ss.store_code, ss.sale_date
)
SELECT
  COALESCE(st.store_code, sa.store_code) AS store_code,
  COALESCE(st.store_name, s.store_name) AS store_name,
  COALESCE(st.snapshot_date, sa.sale_date) AS snapshot_date,
  sa.total_sales,
  sa.total_sales_ex_vat,
  sa.total_cost,
  st.total_qty,
  st.neg_soh_count,
  st.slow_mover_count,
  st.capital_tied,
  st.ghost_stock_value
FROM stock st
FULL OUTER JOIN sales sa
  ON sa.store_code = st.store_code AND sa.sale_date = st.snapshot_date
LEFT JOIN stores s
  ON s.store_code = COALESCE(st.store_code, sa.store_code);

CREATE UNIQUE INDEX idx_mv_kpi_store_date ON public.mv_kpi_by_date (store_code, snapshot_date);
GRANT SELECT ON public.mv_kpi_by_date TO anon, authenticated;
