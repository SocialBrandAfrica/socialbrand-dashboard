-- =============================================================================
-- Add pg_cron job: nightly refresh of mv_kpi_by_date
--
-- Root cause: Supabase Kong gateway enforces a 60-second HTTP timeout that
-- cannot be bypassed from within PostgreSQL (even with set_config). Calling
-- refresh_kpi_view() via the REST API consistently fails with error 57014 on
-- a table with 18M+ rows. The push scripts suffer the same failure silently.
--
-- Fix: schedule the REFRESH directly via pg_cron, bypassing the REST API
-- entirely. pg_cron runs inside the database as a superuser background worker
-- and is not subject to the PostgREST/Kong timeout.
--
-- Schedule: 22:00 UTC = 00:00 SAST (after all 5 nightly pushes are done).
-- The latest push is TOPS Dice at 20:12 UTC (20:00 + 12 min stagger).
-- 22:00 UTC gives 108 minutes of headroom.
--
-- mv_sparkline_14d is already refreshed CONCURRENTLY (non-blocking, no lock)
-- so it does not need a separate pg_cron job.
--
-- Run this in the Supabase SQL Editor.
-- =============================================================================

-- Add nightly pg_cron job for mv_kpi_by_date refresh
SELECT cron.schedule(
    'nightly-kpi-refresh',                  -- job name (unique, for reference)
    '0 22 * * *',                           -- cron: 22:00 UTC every night
    $$REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;$$
);

-- Verify all cron jobs
SELECT jobid, jobname, schedule, command, active
FROM   cron.job
ORDER  BY jobid;
-- Expected: existing job id=4 (purge_old_snapshots) + new nightly-kpi-refresh
