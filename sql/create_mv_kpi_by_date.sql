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

-- SB-CC-PRSSALE-RETIRE-001: stock CTE migrated from daily_snapshots to
-- l2_soh_daily (historical SOH by date) + l2_stock_position (class signals).
-- total_qty dropped (PRSSALE ~20% divergence from Sigma; NULL for backward compat).
-- store_name sourced from stores LEFT JOIN in main SELECT (was ds.store_name).
-- LY stock will be NULL for dates pre-dating l2_soh_daily ingestion -- R22: surface not hide.
CREATE MATERIALIZED VIEW public.mv_kpi_by_date AS
WITH stock AS (
  SELECT
    ls.store_code,
    ls.snapshot_date,
    SUM(CASE WHEN ls.soh < 0 THEN 1 ELSE 0 END)::bigint             AS neg_soh_count,
    SUM(CASE WHEN sp.slow_mover_signal THEN 1 ELSE 0 END)::bigint   AS slow_mover_count,
    COALESCE(ROUND(SUM(
      CASE WHEN sp.class = 'NORMAL' AND ls.soh > 0
      THEN ls.soh * COALESCE(sp.unit_cost, 0) END)::numeric, 2), 0) AS capital_tied,
    COALESCE(ROUND(SUM(
      CASE WHEN sp.class IN ('PRODUCTION', 'NON_STOCK') AND ls.soh > 0
      THEN ls.soh * COALESCE(sp.unit_cost, 0) END)::numeric, 2), 0) AS ghost_stock_value
  FROM l2_soh_daily ls
  JOIN l2_stock_position sp
    ON sp.store_code = ls.store_code AND sp.product_code = ls.product_code
  GROUP BY ls.store_code, ls.snapshot_date
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
  COALESCE(st.store_code, sa.store_code)     AS store_code,
  s.store_name,
  COALESCE(st.snapshot_date, sa.sale_date)   AS snapshot_date,
  sa.total_sales,
  sa.total_sales_ex_vat,
  sa.total_cost,
  NULL::numeric                               AS total_qty,
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

-- PATCH 2026-07-01 (CC, post-outage): see create_v_kpi_by_date.sql for the full
-- note. Schema-reload protocol (RULE-BOOK §8); verify live, don't assume this
-- alone clears PostgREST's cache -- the Dashboard "Reload schema" button may
-- be required.
SELECT pg_notify('pgrst', 'reload schema');

-- ENG-172 / SB-CC-GROUND-001 leg 1: the grade travels with the object (ENGINE-CANON-LAYERS §L4).
COMMENT ON MATERIALIZED VIEW public.mv_kpi_by_date IS
    'GRADE: CALCULATED. Pre-aggregated KPIs per store per date.';
