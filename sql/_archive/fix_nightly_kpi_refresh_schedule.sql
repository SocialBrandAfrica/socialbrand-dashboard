-- =============================================================================
-- fix_nightly_kpi_refresh_schedule.sql
-- Move nightly-kpi-refresh pg_cron job from 22:00 UTC to 18:30 UTC.
--
-- Root cause: mv_kpi_by_date was refreshing 4 hours after nightly pushes.
-- Stores push at 18:00-18:12 UTC (20:00-20:12 SAST). The push script calls
-- refresh_kpi_view() via the REST API, but Supabase Kong gateway kills the
-- HTTP connection at ~30s (error 57014). So the API call always fails silently.
-- The only successful refresh was the pg_cron job at 22:00 UTC (midnight SAST).
-- During 18:12-22:00 UTC (3h 48min), the trend showed yesterday's data even
-- though today's data was in daily_snapshots and push_log.
--
-- Fix: move the cron to 18:30 UTC (20:30 SAST) -- 18 min after last push.
-- The cron runs SQL directly in the DB (no Kong timeout), so it always works.
--
-- Deployed 2026-05-31 (run manually via Supabase SQL Editor).
-- =============================================================================

SELECT cron.unschedule('nightly-kpi-refresh');

SELECT cron.schedule(
    'nightly-kpi-refresh',
    '30 18 * * *',   -- 18:30 UTC = 20:30 SAST, 18 min after last store push
    $$REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;$$
);

-- Verify all jobs
SELECT jobname, schedule, command, active FROM cron.job ORDER BY jobname;
-- Expected:
--   nightly-kpi-refresh  | 30 18 * * * | REFRESH MATERIALIZED VIEW ... | true
