-- =============================================================================
-- create_rpc_search_products.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_search_products.
-- DDL previously lived in rpc_search_detail.sql + add_supplier_to_rpc_search.sql +
-- fix_rpc_search_products_date_cast.sql (sediment). Extracted verbatim from LIVE
-- 2026-06-17. Product search by ean/description/internal_ref/supplier_name.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_search_products(p_store_codes text[], p_date text, p_query text, p_dept_names text[] DEFAULT NULL::text[], p_subdept text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS TABLE(ean text, description text, internal_ref text, dept_name text, sub_dept_name text, sell_price numeric, soh numeric, today_qty numeric, today_sales numeric, today_cost numeric, period_qty numeric, period_cost numeric, period_sales numeric, last_sales_date_iso text, status text, snapshot_date text, store_code text, store_name text, size text, unit text, unit_cost numeric, is_placeholder boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_search_products(text[], text, text, text[], text, integer) TO anon, authenticated;
