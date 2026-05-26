-- =============================================================================
-- add_supplier_to_rpc_search.sql
--
-- Two changes to rpc_search_products:
--
--   1. SUPERSEDES fix_rpc_search_products_date_cast.sql
--      The date cast fix (snapshot_date = p_date::date) is included here.
--      If you have not yet run fix_rpc_search_products_date_cast.sql, run
--      this file instead -- it covers both.
--
--   2. Adds supplier_name as a 4th match field.
--      Searching "Coca Cola" or "Simba" now returns all products where
--      product_catalog.supplier_name matches the query.
--      TOPS products (not in product_catalog) will still match by EAN,
--      description, or internal_ref as before.
--
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Add index on product_catalog(ean) for supplier lookups
-- The PK is (store_code, ean). The EXISTS subquery below matches on ean alone
-- so we add a covering index to avoid a sequential scan of the 42k-row catalog.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS product_catalog_ean_only_idx
    ON public.product_catalog (ean);


-- ---------------------------------------------------------------------------
-- STEP 2 -- Replace function
-- ---------------------------------------------------------------------------
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
          OR  EXISTS (
                  SELECT 1
                  FROM   product_catalog pc
                  WHERE  pc.ean           = daily_snapshots.ean
                    AND  pc.supplier_name ILIKE '%' || p_query || '%'
                  LIMIT  1
              )
      )
      AND (p_dept_names IS NULL OR dept_name     = ANY(p_dept_names))
      AND (p_subdept    IS NULL OR sub_dept_name = p_subdept)
    ORDER BY description ASC
    LIMIT p_limit;
$$;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Reload PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY -- test supplier match (should return Coca-Cola products)
-- Replace '10116' and today's date as needed.
-- ---------------------------------------------------------------------------
-- SELECT ean, description FROM rpc_search_products(
--     ARRAY['10116'], CURRENT_DATE::text, 'coca', NULL, NULL, 10
-- );
