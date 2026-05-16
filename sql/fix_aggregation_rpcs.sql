-- =============================================================================
-- SB-AP-001  Aggregation RPC Fix
-- Run the full script in Supabase SQL Editor in one go.
-- Fixes the multi-date / multi-store summing bug by moving all aggregation
-- to Postgres, eliminating the 1 000-row client-side cap.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  Normalise department names  (H.M.R. → HMR)
--     Affects all existing rows; re-run is safe (idempotent WHERE clause).
-- -----------------------------------------------------------------------------
UPDATE daily_snapshots
SET    dept_name = TRIM(REPLACE(dept_name, '.', ''))
WHERE  dept_name LIKE '%.%';


-- -----------------------------------------------------------------------------
-- 2.  rpc_dept_summary
--     Returns ONE row per department: total sales / cost / qty
--     aggregated across ALL supplied stores and dates.
--     Called whenever the store or date selection changes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[]          -- ISO dates e.g. ARRAY['2026-05-10','2026-05-09']
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
    WHERE store_code    = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
      AND today_sales   > 0
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;


-- -----------------------------------------------------------------------------
-- 3.  rpc_top20
--     Returns up to 40 rows (union of top-20-by-value ∪ top-20-by-qty)
--     aggregated across ALL supplied stores and dates.
--     Accepts optional dept and sub-dept filters.
--     Called whenever store, date, dept, OR sub-dept selection changes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_top20(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text DEFAULT NULL,
    p_subdept      text DEFAULT NULL
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
        WHERE store_code     = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND today_sales    > 0
          AND is_placeholder = FALSE
          AND (p_dept    IS NULL OR dept_name     = p_dept)
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
        GROUP BY ean
    )
    -- Union of top-20 by value and top-20 by qty so the client can switch
    -- between modes without a second round-trip
    (SELECT * FROM agg ORDER BY total_sales DESC LIMIT 20)
    UNION
    (SELECT * FROM agg ORDER BY total_qty   DESC LIMIT 20);
$$;
