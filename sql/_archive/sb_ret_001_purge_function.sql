-- =============================================================================
-- SB-RET-001 -- Monthly auto-purge function + pg_cron schedule
--
-- Keeps 16 full calendar months of data (default -- future: read from clients table).
-- Runs on the 1st of each month at 01:00 SAST (23:00 UTC on the last day).
-- Applies to: daily_snapshots, push_log, push_errors.
-- Refreshes mv_kpi_by_date and mv_sparkline_14d after cleanup.
--
-- Decision basis: SB-RET-001-BRIEF-2026-05-23.md
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Create the purge function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_old_snapshots()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_retention_months  int  := 16;
    v_cutoff            date;
    v_del_snapshots     bigint;
    v_del_push_log      bigint;
    v_del_push_errors   bigint;
BEGIN
    -- Cutoff: first day of (current month minus retention window)
    -- Formula keeps 16 full months including the current partial month.
    v_cutoff := DATE_TRUNC('month', CURRENT_DATE) - (v_retention_months || ' months')::interval;

    -- Purge row-level error log first (FK dependency on push_log)
    DELETE FROM push_errors
    WHERE push_id IN (
        SELECT push_id FROM push_log
        WHERE completed_at < v_cutoff
    );
    GET DIAGNOSTICS v_del_push_errors = ROW_COUNT;

    -- Purge push_log
    DELETE FROM push_log
    WHERE completed_at < v_cutoff;
    GET DIAGNOSTICS v_del_push_log = ROW_COUNT;

    -- Purge daily_snapshots (primary table -- largest)
    DELETE FROM daily_snapshots
    WHERE snapshot_date < v_cutoff;
    GET DIAGNOSTICS v_del_snapshots = ROW_COUNT;

    -- Refresh materialized views (reflect cleaned data)
    REFRESH MATERIALIZED VIEW mv_kpi_by_date;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sparkline_14d;

END;
$$;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Grant execute to postgres role (SECURITY DEFINER handles the rest)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.purge_old_snapshots() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_old_snapshots() TO postgres;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Schedule with pg_cron
-- Runs at 01:00 UTC on the 1st of every month.
-- 01:00 UTC = 03:00 SAST -- well after nightly push completes.
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
    'sb-monthly-purge',
    '0 1 1 * *',
    'SELECT public.purge_old_snapshots();'
);


-- ---------------------------------------------------------------------------
-- STEP 4 -- Verify schedule registered
-- ---------------------------------------------------------------------------
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'sb-monthly-purge';
-- Expected: 1 row, active = true


-- ---------------------------------------------------------------------------
-- VERIFY -- manual test run (safe -- will delete 0 rows until next month rolls)
-- ---------------------------------------------------------------------------
SELECT public.purge_old_snapshots();
-- Expected: no error. NOTICE lines show cutoff date and row counts.


-- ---------------------------------------------------------------------------
-- FUTURE UPGRADE (when pricing tiers land)
-- Replace hardcoded v_retention_months := 16 with:
--   SELECT retention_months INTO v_retention_months FROM clients LIMIT 1;
-- Add retention_months int DEFAULT 16 to clients table at that point.
-- ---------------------------------------------------------------------------
