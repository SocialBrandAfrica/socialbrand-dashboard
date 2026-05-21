-- =============================================================================
-- PULSE-BUG-001  BUG-1: Add p_eans filter to rpc_dept_summary and rpc_top20
-- Run in Supabase SQL Editor in one go.
-- Both functions gain an optional p_eans text[] DEFAULT NULL parameter.
-- Existing callers that omit p_eans continue to work without change.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  rpc_dept_summary — now accepts optional p_eans filter
--     When p_eans is non-null, only rows whose ean is in the list are counted.
--     Used by KPI cards (sales, cost, qty, GP) when the user filters by product.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_eans        text[] DEFAULT NULL
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
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
      AND today_sales         > 0
      AND (p_eans IS NULL OR ean = ANY(p_eans))
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;


-- -----------------------------------------------------------------------------
-- 2.  rpc_top20 — now accepts optional p_eans filter
--     When p_eans is non-null, only the specified EANs appear in the top-20.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_top20(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text    DEFAULT NULL,
    p_subdept      text    DEFAULT NULL,
    p_eans         text[]  DEFAULT NULL
)
RETURNS TABLE(
    ean           text,
    description   text,
    dept_name     text,
    sub_dept_name text,
    size          text,
    unit          text,
    total_sales   numeric,
    total_qty     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH agg AS (
        SELECT
            ean,
            MAX(description)                    AS description,
            MAX(dept_name)                      AS dept_name,
            MAX(sub_dept_name)                  AS sub_dept_name,
            MAX(size)                           AS size,
            MAX(unit)                           AS unit,
            ROUND(SUM(today_sales)::numeric, 2) AS total_sales,
            SUM(today_qty)::numeric             AS total_qty
        FROM  daily_snapshots
        WHERE store_code         = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND today_sales         > 0
          AND is_placeholder      = FALSE
          AND (p_dept    IS NULL OR dept_name     = p_dept)
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
          AND (p_eans    IS NULL OR ean            = ANY(p_eans))
        GROUP BY ean
    )
    (SELECT * FROM agg ORDER BY total_sales DESC LIMIT 20)
    UNION
    (SELECT * FROM agg ORDER BY total_qty   DESC LIMIT 20);
$$;
