-- =============================================================================
-- fix_rpc_search_products_date_cast.sql
--
-- Bug: rpc_search_products used snapshot_date::text = p_date (casts the
-- indexed column), which prevented PostgreSQL from using the snapshot_date
-- index and caused a full 18M-row sequential scan → statement_timeout (500).
--
-- Fix: compare snapshot_date = p_date::date instead — keeps the column
-- uncast so the existing (store_code, snapshot_date) index is used.
-- Query now scans only ~7k rows (one day, one store) before ILIKE.
--
-- Run in Supabase SQL Editor → New query.
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

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
    WHERE store_code    = ANY(p_store_codes)
      AND snapshot_date = p_date::date
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

-- Reload PostgREST schema cache
SELECT pg_notify('pgrst', 'reload schema');
