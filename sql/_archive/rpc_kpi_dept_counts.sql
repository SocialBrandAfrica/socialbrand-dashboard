-- =============================================================================
-- rpc_kpi_dept_counts
--
-- Per-department neg_soh_count and slow_mover_count for the KPI cards.
-- Called when deptFilter or subDeptFilter is active so the Neg SOH and
-- Slow Movers KPI cards reflect only the filtered department.
--
-- Definitions match mv_kpi_by_date exactly:
--   neg_soh_count    = rows where soh < 0
--   slow_mover_count = rows where period_qty = 0 AND soh > 0 AND NOT is_placeholder
-- =============================================================================

CREATE OR REPLACE FUNCTION rpc_kpi_dept_counts(
    p_store_codes  text[],
    p_dates        text[],
    p_subdept      text    DEFAULT NULL,
    p_eans         text[]  DEFAULT NULL
)
RETURNS TABLE(
    dept_name        text,
    neg_soh_count    bigint,
    slow_mover_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        COUNT(*) FILTER (WHERE soh < 0)                                              AS neg_soh_count,
        COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0 AND is_placeholder = FALSE) AS slow_mover_count
    FROM  daily_snapshots
    WHERE store_code    = ANY(p_store_codes)
      AND snapshot_date = ANY(p_dates::date[])
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
      AND (p_eans    IS NULL OR ean            = ANY(p_eans))
    GROUP BY dept_name
    ORDER BY dept_name;
$$;

GRANT EXECUTE ON FUNCTION rpc_kpi_dept_counts(text[], text[], text, text[])
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
