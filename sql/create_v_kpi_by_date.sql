-- =============================================================================
-- create_v_kpi_by_date.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 1.
-- Supersedes: SB-CC-DASH-SOURCE-002 Step 1 (2026-06-13, transitional).
-- =============================================================================
-- HISTORY:
--   Step 1 (2026-06-13): repointed SALES facts onto sigma_sales; stock facts
--     and date driver still on daily_snapshots (deliberate hold at the time).
--   Step 2 (this file, RETIRE-002): completes the retirement.
--     daily_snapshots write path removed 2026-06-28 (Push-SigmaToSupabase.ps1
--     tasks removed on all servers). daily_snapshots frozen at 2026-06-28.
--     Any date >= 2026-06-29 returned no row -- single-date dashboard showed R0.
--
-- WHAT THIS STEP DOES:
--   Flips the driving table from daily_snapshots to sigma_sales so a row exists
--   for every trading date in sigma_sales (period_kind='T', txn_kind=1).
--   Stock facts (neg_soh_count, slow_mover_count, capital_tied, ghost_stock_value)
--   repointed from daily_snapshots inline aggregation to l2_soh_daily +
--   l2_stock_position -- the same proven CTEs used in mv_kpi_by_date (RETIRE-001).
--   store_name from stores (same pattern as mv_kpi_by_date).
--   total_qty from sigma_sales.qty (PRSSALE qty retired with the pipeline).
--   daily_snapshots dependency dropped entirely from this view.
--
-- NULLS (R22 -- surface not hide):
--   Stock facts are NULL for dates before l2_soh_daily ingestion floor:
--     2026-06-11 x stores 10116, 21355, 80175, 80176
--     2026-06-21 x store 80579
--   Sales facts populate for any date present in sigma_sales.
--
-- PERFORMANCE:
--   sigma_sales driver: idx_sigma_sales_store_date (store_code, sale_date) --
--     confirmed present; carries the single-date pushdown predicate.
--   l2_soh_daily stock CTE: idx_l2_soh_store_date (store_code, snapshot_date DESC)
--     -- confirmed present; carries the stock CTE predicate.
--   PG15 CTEs inline by default -- WHERE snapshot_date = $1 from the caller is
--     rewritten to sale_date = $1 on sigma_sales and snapshot_date = $1 on
--     l2_soh_daily; both hit their indexes. No sequential scan regression.
--
-- COLUMN ORDER: preserved exactly from the replaced view (zero client breakage).
-- GRANT: anon + authenticated SELECT (same as before).
--
-- Out of scope (RETIRE-001 do-not-touch list): purge_old_snapshots,
--   check_l1_feed_freshness, rpc_feed_health_daily, rpc_layer_freshness,
--   fn_diag_snapshot_counts, v_deleted_lines_audit, refresh_l2_pipeline.
--
-- Acceptance (R22): single-date total_sales reconciles to sigma_sales direct
--   sum on all 5 stores for 2026-06-29+; stock facts NULL for pre-floor dates.
--
-- Rule 19: DROP + clean CREATE. No dependent views (verified pre-deploy).
-- =============================================================================

DROP VIEW IF EXISTS public.v_kpi_by_date;

CREATE VIEW public.v_kpi_by_date AS
WITH sales AS (
  SELECT
    ss.store_code,
    ss.sale_date,
    round(sum(ss.sales_incl_vat), 2)                 AS total_sales,
    round(sum(ss.cost_value), 2)                     AS total_cost,
    round(sum(ss.sales_incl_vat - ss.vat_value), 2) AS total_sales_ex_vat,
    round(sum(ss.qty), 2)                            AS total_qty
  FROM public.sigma_sales ss
  WHERE ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY ss.store_code, ss.sale_date
),
stock AS (
  SELECT
    ls.store_code,
    ls.snapshot_date,
    SUM(CASE WHEN ls.soh < 0 THEN 1 ELSE 0 END)::bigint               AS neg_soh_count,
    SUM(CASE WHEN sp.slow_mover_signal THEN 1 ELSE 0 END)::bigint     AS slow_mover_count,
    COALESCE(ROUND(SUM(
      CASE WHEN sp.class = 'NORMAL' AND ls.soh > 0
           THEN ls.soh * COALESCE(sp.unit_cost, 0)
      END)::numeric, 2), 0)                                            AS capital_tied,
    COALESCE(ROUND(SUM(
      CASE WHEN sp.class IN ('PRODUCTION', 'NON_STOCK') AND ls.soh > 0
           THEN ls.soh * COALESCE(sp.unit_cost, 0)
      END)::numeric, 2), 0)                                            AS ghost_stock_value
  FROM public.l2_soh_daily ls
  JOIN public.l2_stock_position sp
    ON  sp.store_code   = ls.store_code
    AND sp.product_code = ls.product_code
  GROUP BY ls.store_code, ls.snapshot_date
)
SELECT
  sa.store_code,
  s.store_name,
  sa.sale_date                AS snapshot_date,
  sa.total_sales,
  sa.total_cost,
  sa.total_qty,
  st.neg_soh_count,
  st.slow_mover_count,
  st.capital_tied,
  sa.total_sales_ex_vat,
  st.ghost_stock_value
FROM sales sa
LEFT JOIN public.stores s
  ON  s.store_code   = sa.store_code
LEFT JOIN stock st
  ON  st.store_code   = sa.store_code
  AND st.snapshot_date = sa.sale_date;

GRANT SELECT ON public.v_kpi_by_date TO anon, authenticated;
