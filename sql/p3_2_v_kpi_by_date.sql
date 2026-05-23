-- =============================================================================
-- Phase 3.2: Replace v_kpi_by_date
--
-- Old version read from daily_aggregates (retired).
-- New version reads from daily_snapshots (live source) and adds capital_tied.
--
-- capital_tied = ZAR value of stock tied up in slow movers
--   (in-stock items with zero period_qty, excluding placeholders)
--
-- RUN THIS FIRST (before mv_kpi_by_date and mv_sparkline_14d).
-- Safe to re-run: CREATE OR REPLACE.
-- =============================================================================


CREATE OR REPLACE VIEW v_kpi_by_date AS
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
GROUP BY store_code, store_name, snapshot_date;


-- Grant read access
GRANT SELECT ON v_kpi_by_date TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT store_code, snapshot_date, capital_tied
FROM   v_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  5;
-- Expected: 5 rows, capital_tied is a non-zero positive number (e.g. 45000.00)
-- If capital_tied is 0 on all rows, unit_cost is null -- investigate daily_snapshots.
