-- =============================================================================
-- vacuum_analyze_post_ean_fix.sql
--
-- Run after sb_ean_002_fix.sql to reclaim disk and update planner statistics.
-- The EAN fix deleted ~54,193 rows and updated ~131,801 rows. Without VACUUM,
-- PostgreSQL cannot reuse that dead space and the query planner uses stale row
-- estimates.
--
-- IMPORTANT: VACUUM cannot run inside a transaction. Paste each step
-- separately in the SQL Editor (not as one block).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- ANALYZE only (Supabase SQL Editor cannot run VACUUM)
--
-- VACUUM is blocked by the SQL Editor's 60-second timeout and implicit
-- transaction wrapper. Skip it -- Supabase autovacuum reclaims dead tuples
-- automatically in the background within a few hours.
--
-- ANALYZE updates the query planner statistics immediately (the part that
-- actually matters for query performance after the EAN fix deletions).
-- ---------------------------------------------------------------------------
ANALYZE daily_snapshots;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Refresh materialized views to reflect the cleaned data
-- Run after Step 1 completes.
-- CONCURRENTLY allows reads during refresh (no exclusive lock).
-- ---------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_kpi_by_date;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_rate_of_sale;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sparkline_14d;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Confirm pg_cron jobs are alive (read-only check)
-- Expected: 4 rows (nightly MV refresh, purge_old_snapshots, upsert_search_index, kpi refresh)
-- ---------------------------------------------------------------------------
SELECT jobid, schedule, command, active
FROM   cron.job
ORDER  BY jobid;
