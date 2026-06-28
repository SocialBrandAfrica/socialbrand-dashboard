-- =============================================================================
-- create_rpc_lost_sales_oos.sql
-- SB-CC-PRSSALE-RETIRE-001 -- new RPC, replaces direct daily_snapshots OOS
-- query in page.jsx (Lost Sales widget). Source: l2_stock_position (always-
-- latest sigma-native position). No date parameters needed -- position is
-- live, not historical. soh <= 0 AND sales_qty_91d > 0 = active-line OOS.
-- class filter excludes ghost-stock categories from lost-sales signal.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_lost_sales_oos(p_store_codes text[])
RETURNS TABLE(
    ean              text,
    description      text,
    dept_name        text,
    sub_dept_name    text,
    soh              numeric,
    sell_price       numeric,
    last_sales_date_iso text,
    store_name       text,
    store_code       text,
    unit_cost        numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        b.ean::text,
        COALESCE(sp.description, a.description, a.short_description)  AS description,
        COALESCE(sp.dept_name,    'UNMAPPED')                         AS dept_name,
        COALESCE(sp.subdept_name, 'UNMAPPED')                         AS sub_dept_name,
        sp.soh,
        sp.sell_price_incl_vat                                        AS sell_price,
        sp.last_sale_date::text                                       AS last_sales_date_iso,
        st.store_name,
        sp.store_code,
        sp.unit_cost
    FROM l2_stock_position sp
    JOIN   v_ean_bridge b         ON b.store_code = sp.store_code AND b.product_code = sp.product_code
    JOIN   stores st              ON st.store_code = sp.store_code
    LEFT   JOIN sigma_articles a  ON a.store_code  = sp.store_code AND a.product_code = sp.product_code
    WHERE  sp.store_code     = ANY(p_store_codes)
      AND  sp.soh            <= 0
      AND  sp.sales_qty_91d  >  0
      AND  sp.class NOT IN ('NON_STOCK', 'PRODUCTION')
    ORDER  BY sp.soh ASC
    LIMIT  200;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_lost_sales_oos(text[]) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
