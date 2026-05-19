-- =============================================================================
-- Focus Area RPCs
-- Run once in the Supabase SQL Editor.
-- Replaces direct daily_snapshots reads (blocked by RLS for the anon key)
-- with SECURITY DEFINER functions that bypass RLS, matching the pattern
-- used by rpc_top20 and rpc_dept_summary.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  rpc_focus_top5
--     Returns the top 5 products by period sales for the Focus Area basket.
--     Accepts optional dept / sub-dept filters (pass NULL for "all").
--     Returns one row per ean + store_code combination so the chart can
--     show per-store lines when multiple stores are selected.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_focus_top5(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text DEFAULT NULL,
    p_subdept      text DEFAULT NULL
)
RETURNS TABLE(
    ean           text,
    description   text,
    store_code    text,
    dept_name     text,
    sub_dept_name text,
    period_sales  numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        MAX(description)                    AS description,
        store_code,
        MAX(dept_name)                      AS dept_name,
        MAX(sub_dept_name)                  AS sub_dept_name,
        ROUND(SUM(today_sales)::numeric, 2) AS period_sales
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
      AND today_sales        > 0
      AND (p_dept    IS NULL OR dept_name     = p_dept)
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
    GROUP BY ean, store_code
    ORDER BY period_sales DESC
    LIMIT 50;
$$;


-- -----------------------------------------------------------------------------
-- 2.  rpc_focus_chart
--     Returns individual daily rows for a set of EANs / stores / dates.
--     Used by FocusAreaPanel to draw the time-series comparison chart.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_focus_chart(
    p_eans        text[],
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    ean           text,
    description   text,
    size          text,
    unit          text,
    snapshot_date text,
    store_code    text,
    today_sales   numeric,
    today_qty     numeric,
    soh           numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        description,
        size,
        unit,
        snapshot_date::text,
        store_code,
        ROUND(today_sales::numeric, 2) AS today_sales,
        today_qty::numeric             AS today_qty,
        soh::numeric                   AS soh
    FROM  daily_snapshots
    WHERE ean                = ANY(p_eans)
      AND store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    ORDER BY snapshot_date ASC;
$$;
