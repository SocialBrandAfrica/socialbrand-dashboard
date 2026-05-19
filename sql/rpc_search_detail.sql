-- =============================================================================
-- Search, Product Detail, and Sub-Dept RPCs
-- Run once in the Supabase SQL Editor.
-- Replaces direct daily_snapshots reads (blocked by RLS for the anon key)
-- with SECURITY DEFINER functions, matching the pattern used by rpc_top20
-- and rpc_dept_summary.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  rpc_search_products
--     Typeahead / product search.  Matches EAN, description, or internal_ref
--     using ILIKE.  Accepts optional dept / sub-dept arrays for filter chips.
--     p_dept_names is an array so callers can pass multiple raw department name
--     variants (e.g. both "HMR" and "H.M.R.") without a client-side normalize.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_search_products(
    p_store_codes  text[],
    p_date         text,
    p_query        text,
    p_dept_names   text[]  DEFAULT NULL,
    p_subdept      text    DEFAULT NULL,
    p_limit        int     DEFAULT 100
)
RETURNS TABLE(
    ean                  text,
    description          text,
    internal_ref         text,
    dept_name            text,
    sub_dept_name        text,
    sell_price           numeric,
    soh                  numeric,
    today_qty            numeric,
    today_sales          numeric,
    today_cost           numeric,
    period_qty           numeric,
    period_cost          numeric,
    period_sales         numeric,
    last_sales_date_iso  text,
    status               text,
    snapshot_date        text,
    store_code           text,
    store_name           text,
    size                 text,
    unit                 text,
    unit_cost            numeric,
    is_placeholder       boolean
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        description,
        internal_ref,
        dept_name,
        sub_dept_name,
        sell_price::numeric,
        soh::numeric,
        today_qty::numeric,
        today_sales::numeric,
        today_cost::numeric,
        period_qty::numeric,
        period_cost::numeric,
        period_sales::numeric,
        last_sales_date_iso::text,
        status::text,
        snapshot_date::text,
        store_code,
        store_name,
        size,
        unit,
        unit_cost::numeric,
        is_placeholder
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = p_date
      AND (
              ean          ILIKE '%' || p_query || '%'
          OR  description  ILIKE '%' || p_query || '%'
          OR  internal_ref ILIKE '%' || p_query || '%'
      )
      AND (p_dept_names IS NULL OR dept_name     = ANY(p_dept_names))
      AND (p_subdept    IS NULL OR sub_dept_name = p_subdept)
    ORDER BY description ASC
    LIMIT p_limit;
$$;


-- -----------------------------------------------------------------------------
-- 2.  rpc_product_detail
--     Returns all daily rows for a single EAN across selected stores and dates.
--     Used by handleProductClick to populate the 5 charts in ProductDetailPanel.
--     p_dates should be the full availableDates array so the chart shows the
--     complete date history, not just the current KPI filter window.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_product_detail(
    p_ean         text,
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    snapshot_date  text,
    store_code     text,
    store_name     text,
    today_qty      numeric,
    today_sales    numeric,
    today_cost     numeric,
    soh            numeric,
    sell_price     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        snapshot_date::text,
        store_code,
        store_name,
        today_qty::numeric,
        today_sales::numeric,
        today_cost::numeric,
        soh::numeric,
        sell_price::numeric
    FROM  daily_snapshots
    WHERE ean                = p_ean
      AND store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    ORDER BY snapshot_date ASC;
$$;


-- -----------------------------------------------------------------------------
-- 3.  rpc_subdepts
--     Returns distinct sub-department names for the current store + date
--     selection.  Used to power the sub-dept dropdown chip row.
--     When p_dept_names is provided, restricts to that department set
--     (handles "H.M.R." / "HMR" variants via the caller passing both).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_subdepts(
    p_store_codes  text[],
    p_dates        text[],
    p_dept_names   text[] DEFAULT NULL
)
RETURNS TABLE(sub_dept_name text)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT DISTINCT sub_dept_name
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
      AND is_placeholder     = FALSE
      AND today_sales        > 0
      AND sub_dept_name      IS NOT NULL
      AND (p_dept_names IS NULL OR dept_name = ANY(p_dept_names))
    ORDER BY sub_dept_name;
$$;


-- -----------------------------------------------------------------------------
-- 4.  rpc_all_rows
--     Paginated full-row fetch used by the 9 on-demand reports (DIWAAIS,
--     Sales, Full Export, etc.).  Mirrors the COLS constant in page.jsx.
--     Caller pages through results using p_from / p_limit.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_all_rows(
    p_store_codes  text[],
    p_dates        text[],
    p_from         int  DEFAULT 0,
    p_limit        int  DEFAULT 1000
)
RETURNS TABLE(
    ean                  text,
    description          text,
    size                 text,
    unit                 text,
    sell_price           numeric,
    vat_pct              numeric,
    today_qty            numeric,
    today_cost           numeric,
    today_sales          numeric,
    period_qty           numeric,
    period_cost          numeric,
    period_sales         numeric,
    soh                  numeric,
    dept_code            text,
    dept_name            text,
    sub_dept_code        text,
    sub_dept_name        text,
    internal_ref         text,
    status               text,
    last_sales_date_iso  text,
    is_placeholder       boolean,
    snapshot_date        text,
    store_code           text,
    store_name           text,
    unit_cost            numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        description,
        size,
        unit,
        sell_price::numeric,
        vat_pct::numeric,
        today_qty::numeric,
        today_cost::numeric,
        today_sales::numeric,
        period_qty::numeric,
        period_cost::numeric,
        period_sales::numeric,
        soh::numeric,
        dept_code,
        dept_name,
        sub_dept_code,
        sub_dept_name,
        internal_ref,
        status::text,
        last_sales_date_iso::text,
        is_placeholder,
        snapshot_date::text,
        store_code,
        store_name,
        unit_cost::numeric
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    LIMIT  p_limit
    OFFSET p_from;
$$;
