-- =============================================================================
-- PULSE-BUG-001 Bug 3: Slow Movers and Negative SOH KPIs ignore DEPT filter
--
-- Root cause: neg_soh_count / slow_mover_count come from mv_kpi_by_date, which
-- is a pre-aggregated materialized view with no dept parameter.  When the user
-- picks a dept, kpiSales/kpiCost/kpiQty already use rpc_dept_summary (which IS
-- dept-aware), but the SOH counts fall through to the undifferentiated MV total.
--
-- Fix: new rpc_kpi_dept_counts returns (dept_name, neg_soh_count,
-- slow_mover_count) for any store+date combo.  Called alongside rpc_dept_summary
-- in loadViews.  Frontend uses these counts when deptFilter != 'all'.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- rpc_kpi_dept_counts
--
-- For each dept that has at least one product in the requested store+date window,
-- returns the count of:
--   neg_soh_count    - unique EAN+store combinations whose latest SOH < 0
--   slow_mover_count - unique EAN+store combinations whose latest SOH > 0 AND
--                      period_qty = 0 (in-stock but sold nothing in the window)
--
-- Uses DISTINCT ON (store_code, ean) to pin to the latest snapshot per EAN per
-- store within the supplied date list, matching the logic in mv_kpi_by_date.
-- dept_name is normalised (dots stripped) to match the UI chip labels.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_kpi_dept_counts(
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    dept_name        text,
    neg_soh_count    bigint,
    slow_mover_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        COUNT(*) FILTER (WHERE soh < 0)                    AS neg_soh_count,
        COUNT(*) FILTER (WHERE soh > 0 AND period_qty = 0) AS slow_mover_count
    FROM (
        SELECT DISTINCT ON (store_code, ean)
            TRIM(REPLACE(dept_name, '.', '')) AS dept_name,
            soh,
            period_qty
        FROM  daily_snapshots
        WHERE store_code         = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND NOT is_placeholder
          AND dept_name           IS NOT NULL
        ORDER BY store_code, ean, snapshot_date DESC
    ) latest
    GROUP BY dept_name
    ORDER BY dept_name;
$$;
