-- =============================================================================
-- Phase 3.2: Create mv_sparkline_14d
--
-- Materialized view: one row per store per date for the 14 most recent dates.
-- Provides sparkline data for KPI cards regardless of active date filter.
--
-- Refresh: nightly via Push-SigmaToSupabase.ps1 (added in Phase 3.2).
-- Manual refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sparkline_14d;
--   (CONCURRENTLY requires the unique index below and allows reads during refresh)
--
-- RUN THIS AFTER p3_2_mv_kpi_by_date.sql.
-- =============================================================================


CREATE MATERIALIZED VIEW IF NOT EXISTS mv_sparkline_14d AS
WITH latest_14_dates AS (
    SELECT DISTINCT snapshot_date
    FROM   daily_snapshots
    ORDER  BY snapshot_date DESC
    LIMIT  14
)
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,
    SUM(ds.today_sales)                                                                    AS total_sales,
    SUM(ds.today_cost)                                                                     AS total_cost,
    SUM(ds.today_qty)                                                                      AS total_qty,
    COUNT(*) FILTER (WHERE ds.soh < 0)                                                    AS neg_soh_count,
    COUNT(*) FILTER (WHERE ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE) AS slow_mover_count,
    ROUND(SUM(
        CASE WHEN ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                         AS capital_tied
FROM   daily_snapshots ds
WHERE  ds.snapshot_date IN (SELECT snapshot_date FROM latest_14_dates)
GROUP  BY ds.store_code, ds.store_name, ds.snapshot_date
ORDER  BY ds.store_code, ds.snapshot_date ASC;


-- Index so the dashboard can filter by store efficiently
-- Also required for CONCURRENT refresh
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_sparkline_store_date
    ON mv_sparkline_14d (store_code, snapshot_date);


-- Grant read access
GRANT SELECT ON mv_sparkline_14d TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT store_code, snapshot_date, capital_tied
FROM   mv_sparkline_14d
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC;
-- Expected: exactly 14 rows, capital_tied non-null positive number.

SELECT store_code, COUNT(*) AS row_count
FROM   mv_sparkline_14d
GROUP  BY store_code
ORDER  BY store_code;
-- Expected: 5 rows (one per store), each with count = 14.


-- =============================================================================
-- Step 5: Update refresh_kpi_view to also refresh mv_sparkline_14d
--
-- The push script calls refresh_kpi_view() after every successful push.
-- Adding mv_sparkline_14d here means no push script changes are needed.
-- CONCURRENTLY requires the unique index created above (idx_mv_sparkline_store_date).
-- =============================================================================

DROP FUNCTION IF EXISTS public.refresh_kpi_view CASCADE;

CREATE FUNCTION public.refresh_kpi_view()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
    PERFORM set_config('statement_timeout', '0', true);
    REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_sparkline_14d;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_kpi_view()
    TO anon, authenticated, service_role;

-- Verify
SELECT proname, pg_get_function_arguments(oid)
FROM   pg_proc
WHERE  proname = 'refresh_kpi_view'
  AND  pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
-- Expected: 1 row, arguments = ''
