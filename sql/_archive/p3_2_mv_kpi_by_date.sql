-- =============================================================================
-- Phase 3.2: Recreate mv_kpi_by_date with capital_tied column
--
-- The dashboard KPI strip reads from this MV. Adding capital_tied here powers
-- the new "Capital Tied" KPI card without touching v_kpi_by_date.
--
-- DROP + CREATE is required because Postgres cannot ALTER MATERIALIZED VIEW
-- to add columns. The recreated MV is immediately populated by the
-- REFRESH at the end -- no data loss, but the MV is unavailable for ~30s
-- while the refresh runs.
--
-- RUN THIS AFTER p3_2_v_kpi_by_date.sql.
-- Run during low-traffic time (the dashboard will show loading state briefly).
-- Safe to re-run: DROP IF EXISTS guards the drop.
-- =============================================================================


-- Step 1: Drop existing MV (CASCADE drops the unique index automatically)
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_by_date CASCADE;


-- Step 2: Recreate with capital_tied added
CREATE MATERIALIZED VIEW mv_kpi_by_date AS
SELECT
    store_code,
    store_name,
    snapshot_date,
    SUM(today_sales)                                                                    AS total_sales,
    SUM(today_cost)                                                                     AS total_cost,
    SUM(today_qty)                                                                      AS total_qty,
    COUNT(*) FILTER (WHERE soh < 0)                                                    AS neg_soh_count,
    COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0 AND is_placeholder = FALSE)      AS slow_mover_count,
    ROUND(SUM(
        CASE WHEN period_qty = 0 AND soh > 0 AND is_placeholder = FALSE
             THEN soh * COALESCE(unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                      AS capital_tied
FROM daily_snapshots
GROUP BY store_code, store_name, snapshot_date
ORDER BY store_code, snapshot_date DESC;


-- Step 3: Index for fast per-store-per-date lookups (dashboard filter queries)
CREATE UNIQUE INDEX idx_mv_kpi_store_date
    ON mv_kpi_by_date (store_code, snapshot_date);


-- Step 4: Grant access
GRANT SELECT ON mv_kpi_by_date TO anon, authenticated;


-- Step 5: Populate (runs synchronously -- wait for this to complete, ~15-60s)
REFRESH MATERIALIZED VIEW mv_kpi_by_date;


-- ---------------------------------------------------------------------------
-- VERIFY (run after the REFRESH completes)
-- ---------------------------------------------------------------------------
SELECT store_code, snapshot_date, capital_tied
FROM   mv_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;
-- Expected: 3 rows, capital_tied is a non-zero positive number.

SELECT COUNT(DISTINCT snapshot_date) AS date_count
FROM   mv_kpi_by_date
WHERE  store_code = '10116';
-- Expected: same number as before (no dates lost).
