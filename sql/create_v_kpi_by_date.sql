-- =============================================================================
-- create_v_kpi_by_date.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 1.
-- Supersedes: SB-CC-DASH-SOURCE-002 Step 1 (2026-06-13, transitional).
-- =============================================================================
-- HISTORY:
--   Step 1 (2026-06-13): repointed SALES facts onto sigma_sales; stock facts
--     and date driver still on daily_snapshots (deliberate hold at the time).
--   Step 2 (RETIRE-002): completed the retirement. daily_snapshots write path
--     removed 2026-06-28 (Push-SigmaToSupabase.ps1 tasks removed on all
--     servers), table frozen at 2026-06-28. Any date >= 2026-06-29 returned no
--     row -- the single-date dashboard showed R0. Step 2 flipped the driving
--     table to sigma_sales and repointed the four stock facts onto
--     l2_soh_daily + l2_stock_position, computed INLINE in this view.
--   Step 3 (this file, ENG-100, 2026-08-23, PM surgical display-lane migration
--     under FILE-GOVERNANCE SS0d; CC regenerated this file and closed the
--     divergence): the INLINE stock CTE is RETIRED. The four point-in-time
--     stock columns are now READ from mv_kpi_by_date.
--
-- WHY STEP 3 (the defect it closes):
--   Step 2's inline stock CTE was UNBOUNDED -- it aggregated l2_soh_daily
--   across every date rather than the requested one, scanning ~20M rows on a
--   single-date read. Measured through PostgREST as anon: 32.07s, HTTP 500,
--   killed by the anon role's 30s statement_timeout. The single-date KPI cards
--   were dead on arrival. After the repoint: 7.7s for all 5 stores.
--   R22 GREEN: the four stock columns are byte-identical to the live Step-2
--   computation on all 5 stores for 2026-08-23.
--
-- 🔴 KNOWN BOUND, and the frontend MUST honour it (R22 SS3, surface never hide):
--   mv_kpi_by_date is refreshed nightly at 20:30 SAST by pg_cron job 11. For a
--   date NEWER than that matview's max -- i.e. the ~19:30 to 20:30 window after
--   the push lands but before the refresh runs -- the four stock columns come
--   back NULL. NULL means "not yet computed for this date", never zero.
--   Render it as an em-dash. A zero here is a false statement about the client's
--   capital and stock position, and it is exactly the silent-degradation class
--   R30 SS2 and R22 SS3 exist to stop.
--   SALES columns are unaffected and populate for any date in sigma_sales.
--
-- NULLS (R22 -- surface not hide), carried from Step 2:
--   Stock facts are also NULL for dates before the l2_soh_daily ingestion floor:
--     2026-06-11 x stores 10116, 21355, 80175, 80176
--     2026-06-21 x store 80579
--
-- PERFORMANCE:
--   sigma_sales driver: idx_sigma_sales_store_date (store_code, sale_date),
--     carries the single-date pushdown predicate.
--   Stock side is now a LEFT JOIN to mv_kpi_by_date on (store_code,
--     snapshot_date) -- a pre-aggregated matview read, one row per store-date,
--     replacing the ~20M-row scan. This is the same precompute-and-read shape
--     ENG-088 used for the order (R32 SS3: an applet READS, it never computes).
--
-- COLUMN ORDER: preserved exactly from the replaced view (zero client breakage).
-- GRANT: anon + authenticated SELECT (unchanged).
--
-- CASCADE NOTE (CLEANUP-ENGINE-CANON SS13): v_kpi_by_date is a CASCADE-class
--   dependent of l2_stock_position. It is one of the EIGHT objects that must be
--   rebuilt in the same transaction as any l2_stock_position rebuild. Re-derive
--   that list at the rebuild, never quote it -- it has gone stale three times.
--   CREATE OR REPLACE is used here rather than DROP ... CASCADE precisely so
--   this file can never take v_kpi_by_date's own dependents down with it.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_kpi_by_date AS
 WITH sales AS (
         SELECT ss.store_code,
            ss.sale_date,
            round(sum(ss.sales_incl_vat), 2) AS total_sales,
            round(sum(ss.cost_value), 2) AS total_cost,
            round(sum(ss.sales_incl_vat - ss.vat_value), 2) AS total_sales_ex_vat,
            round(sum(ss.qty), 2) AS total_qty
           FROM sigma_sales ss
          WHERE ss.period_kind = 'T'::text AND ss.txn_kind = 1
          GROUP BY ss.store_code, ss.sale_date
        )
 SELECT sa.store_code,
    s.store_name,
    sa.sale_date AS snapshot_date,
    sa.total_sales,
    sa.total_cost,
    sa.total_qty,
    m.neg_soh_count,
    m.slow_mover_count,
    m.capital_tied,
    sa.total_sales_ex_vat,
    m.ghost_stock_value
   FROM sales sa
     LEFT JOIN stores s ON s.store_code = sa.store_code
     LEFT JOIN mv_kpi_by_date m ON m.store_code = sa.store_code AND m.snapshot_date = sa.sale_date;

GRANT SELECT ON public.v_kpi_by_date TO anon, authenticated;

-- PostgREST schema cache reload (commit 6182b15 -- belt, never the control;
-- if a fresh object still 404s, use the Dashboard "Reload schema" button,
-- CLEANUP-ENGINE-CANON SS13 rule 2).
SELECT pg_notify('pgrst', 'reload schema');
