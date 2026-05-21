-- =============================================================================
-- PULSE-BUG-001 Bug 4: All KPI cards ignore the sub-dept filter
--
-- Root cause: rpc_dept_summary and rpc_kpi_dept_counts do not accept or apply
-- a sub-dept parameter. Selecting a sub-dept already filters rpc_top20 (correct)
-- but the KPI values (sales, cost, qty, GP, neg SOH, slow movers) remain at the
-- full-dept level because none of the KPI RPCs receive the sub-dept selection.
--
-- Fix: add optional p_subdept text DEFAULT NULL to both RPCs.
-- Existing callers that omit p_subdept continue to work without change.
-- page.jsx passes subDeptFilter != 'all' to both RPCs in loadViews.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  rpc_dept_summary — add optional p_subdept filter
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_eans        text[] DEFAULT NULL,
    p_subdept     text   DEFAULT NULL
)
RETURNS TABLE(
    dept_name   text,
    total_sales numeric,
    total_cost  numeric,
    total_qty   numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        ROUND(SUM(today_sales)::numeric, 2)  AS total_sales,
        ROUND(SUM(today_cost)::numeric,  2)  AS total_cost,
        SUM(today_qty)::numeric              AS total_qty
    FROM  daily_snapshots
    WHERE store_code          = ANY(p_store_codes)
      AND snapshot_date::text  = ANY(p_dates)
      AND today_sales          > 0
      AND (p_eans    IS NULL OR ean           = ANY(p_eans))
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;


-- -----------------------------------------------------------------------------
-- 2.  rpc_kpi_dept_counts — add optional p_subdept filter
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_kpi_dept_counts(
    p_store_codes text[],
    p_dates       text[],
    p_subdept     text DEFAULT NULL
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
        WHERE store_code          = ANY(p_store_codes)
          AND snapshot_date::text  = ANY(p_dates)
          AND NOT is_placeholder
          AND dept_name            IS NOT NULL
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
        ORDER BY store_code, ean, snapshot_date DESC
    ) latest
    GROUP BY dept_name
    ORDER BY dept_name;
$$;
