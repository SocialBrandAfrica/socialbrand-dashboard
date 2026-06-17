-- =============================================================================
-- SB-RET-002 -- Step 2: purge_old_snapshots() v2 (aggregate-then-delete)
--
-- Replaces sb_ret_001_purge_function.sql.
-- New behaviour: aggregates rows into quarterly_aggregates BEFORE deleting,
-- so trend history is preserved beyond the 16-month rolling window.
--
-- Run AFTER sb_ret_002_quarterly_aggregates.sql.
-- Uses CREATE OR REPLACE -- pg_cron job id=4 continues unchanged.
--
-- Decision basis: SB-RET-002-BRIEF-2026-05-24.md (PM approved 2026-05-24)
-- =============================================================================


CREATE OR REPLACE FUNCTION public.purge_old_snapshots()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_retention_months  int     := 16;
    v_cutoff            date;
    v_agg_rows          bigint;
    v_del_snapshots     bigint;
    v_del_push_log      bigint;
    v_del_push_errors   bigint;
BEGIN
    -- Cutoff: first day of (current month minus retention window).
    -- Keeps 16 full calendar months including the current partial month.
    v_cutoff := DATE_TRUNC('month', CURRENT_DATE)
                - (v_retention_months || ' months')::interval;

    RAISE NOTICE 'purge_old_snapshots v2: cutoff=%, retention=% months',
        v_cutoff, v_retention_months;

    -- -------------------------------------------------------------------------
    -- STEP 1: Aggregate daily rows older than cutoff into quarterly_aggregates.
    --
    -- Must run BEFORE the DELETE so data is preserved.
    -- ON CONFLICT DO UPDATE overwrites with re-computed values -- idempotent on
    -- re-run because the source rows are the same until the DELETE commits.
    -- -------------------------------------------------------------------------
    INSERT INTO public.quarterly_aggregates (
        store_code, ean, year_month,
        total_sales, total_qty, days_with_data,
        avg_soh, min_price, max_price, description
    )
    SELECT
        store_code,
        ean,
        DATE_TRUNC('month', snapshot_date)::date  AS year_month,
        SUM(today_sales)                           AS total_sales,
        ROUND(SUM(today_qty))::integer             AS total_qty,
        COUNT(*)                                   AS days_with_data,
        AVG(soh)                                   AS avg_soh,
        MIN(sell_price)                            AS min_price,
        MAX(sell_price)                            AS max_price,
        MAX(description)                           AS description
    FROM public.daily_snapshots
    WHERE snapshot_date < v_cutoff
    GROUP BY store_code, ean, DATE_TRUNC('month', snapshot_date)::date
    ON CONFLICT (store_code, ean, year_month)
    DO UPDATE SET
        total_sales    = EXCLUDED.total_sales,
        total_qty      = EXCLUDED.total_qty,
        days_with_data = EXCLUDED.days_with_data,
        avg_soh        = EXCLUDED.avg_soh,
        min_price      = EXCLUDED.min_price,
        max_price      = EXCLUDED.max_price,
        description    = COALESCE(EXCLUDED.description,
                                  quarterly_aggregates.description),
        aggregated_at  = now();

    GET DIAGNOSTICS v_agg_rows = ROW_COUNT;
    RAISE NOTICE 'Aggregated % EAN-month rows into quarterly_aggregates',
        v_agg_rows;

    -- -------------------------------------------------------------------------
    -- STEP 2: Purge supporting tables (FK order: errors -> log)
    -- -------------------------------------------------------------------------
    DELETE FROM push_errors
    WHERE push_id IN (
        SELECT push_id FROM push_log
        WHERE completed_at < v_cutoff
    );
    GET DIAGNOSTICS v_del_push_errors = ROW_COUNT;

    DELETE FROM push_log
    WHERE completed_at < v_cutoff;
    GET DIAGNOSTICS v_del_push_log = ROW_COUNT;

    -- -------------------------------------------------------------------------
    -- STEP 3: Delete daily_snapshots (must come AFTER aggregation)
    -- -------------------------------------------------------------------------
    DELETE FROM public.daily_snapshots
    WHERE snapshot_date < v_cutoff;
    GET DIAGNOSTICS v_del_snapshots = ROW_COUNT;

    RAISE NOTICE 'Deleted: daily_snapshots=%, push_log=%, push_errors=%',
        v_del_snapshots, v_del_push_log, v_del_push_errors;

    -- -------------------------------------------------------------------------
    -- STEP 4: Refresh materialized views (best-effort -- failures do not abort purge)
    --
    -- The nightly pg_cron job (nightly-kpi-refresh, 22:00 UTC) handles
    -- mv_kpi_by_date independently, so a failed refresh here is harmless.
    -- Exception blocks create implicit savepoints -- Steps 1-3 always commit.
    -- -------------------------------------------------------------------------
    BEGIN
        REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;
        RAISE NOTICE 'mv_kpi_by_date refreshed.';
    EXCEPTION WHEN others THEN
        RAISE WARNING 'mv_kpi_by_date refresh failed (non-fatal): %', SQLERRM;
    END;

    BEGIN
        REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_sparkline_14d;
        RAISE NOTICE 'mv_sparkline_14d refreshed.';
    EXCEPTION WHEN others THEN
        RAISE WARNING 'mv_sparkline_14d refresh failed (non-fatal): %', SQLERRM;
    END;
END;
$$;


-- Grant unchanged from v1
REVOKE ALL ON FUNCTION public.purge_old_snapshots() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_old_snapshots() TO postgres;


-- Verify pg_cron job id=4 is still active and unchanged
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'sb-monthly-purge';
-- Expected: 1 row, active = true, command = 'SELECT public.purge_old_snapshots();'
-- The job does not need to be re-registered -- function name/signature unchanged.
