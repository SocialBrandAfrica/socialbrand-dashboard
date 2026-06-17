-- =============================================================================
-- create_purge_old_snapshots.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for purge_old_snapshots.
-- Supersedes sb_ret_001_purge_function.sql + sb_ret_002_purge_function_v2.sql
-- (sediment). Extracted verbatim from LIVE 2026-06-17. 16-month rolling retention:
-- aggregates old daily_snapshots into quarterly_aggregates, then purges
-- daily_snapshots + push_log + push_errors, then refreshes the KPI matviews.
-- SCHEDULE: pg_cron monthly (0 1 1 * *) -- see commented cron.schedule for fresh deploy.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.purge_old_snapshots()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_retention_months  int     := 16;
    v_cutoff            date;
    v_agg_rows          bigint;
    v_del_snapshots     bigint;
    v_del_push_log      bigint;
    v_del_push_errors   bigint;
BEGIN
    -- Cutoff: first day of (current month minus retention window).
    v_cutoff := DATE_TRUNC('month', CURRENT_DATE)
                - (v_retention_months || ' months')::interval;

    RAISE NOTICE 'purge_old_snapshots v2: cutoff=%, retention=% months',
        v_cutoff, v_retention_months;

    -- STEP 1: Aggregate daily rows older than cutoff into quarterly_aggregates
    -- (must run BEFORE the DELETE so data is preserved; idempotent on re-run).
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
    RAISE NOTICE 'Aggregated % EAN-month rows into quarterly_aggregates', v_agg_rows;

    -- STEP 2: Purge supporting tables (FK order: errors -> log)
    DELETE FROM push_errors
    WHERE push_id IN (
        SELECT push_id FROM push_log
        WHERE completed_at < v_cutoff
    );
    GET DIAGNOSTICS v_del_push_errors = ROW_COUNT;

    DELETE FROM push_log
    WHERE completed_at < v_cutoff;
    GET DIAGNOSTICS v_del_push_log = ROW_COUNT;

    -- STEP 3: Delete daily_snapshots (after aggregation)
    DELETE FROM public.daily_snapshots
    WHERE snapshot_date < v_cutoff;
    GET DIAGNOSTICS v_del_snapshots = ROW_COUNT;

    RAISE NOTICE 'Deleted: daily_snapshots=%, push_log=%, push_errors=%',
        v_del_snapshots, v_del_push_log, v_del_push_errors;

    -- STEP 4: Refresh materialized views (best-effort -- failures do not abort purge)
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
$function$;

-- Fresh-deploy schedule (monthly, 1st @ 01:00 UTC). Commented to avoid altering
-- the live pg_cron job on apply; uncomment on a new deployment.
-- SELECT cron.schedule('purge-old-snapshots', '0 1 1 * *', $$SELECT purge_old_snapshots();$$);
