-- ============================================================================
-- rpc_kitchen_sales -- till sales for a fixed product list (Kitchen tab)
-- ============================================================================
-- R30 repair (2026-07-06). public/StockFlow-DevCorner-Demo.html and
-- public/pmini.html's fetchKitchen() read sigma_sales directly with the anon
-- key -- fails silently, sigma_sales has RLS with no anon SELECT policy
-- (the R30 sweep finding: "one access pattern for every surface, published
-- interfaces only"). Same shape and filters as the broken client-side call,
-- just behind a SECURITY DEFINER RPC.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_kitchen_sales(p_store_code text, p_product_codes bigint[], p_from_date date)
 RETURNS TABLE(sale_date date, product_code bigint, sales_incl_vat numeric, qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  SELECT ss.sale_date, ss.product_code, ss.sales_incl_vat, ss.qty
  FROM public.sigma_sales ss
  WHERE ss.store_code = p_store_code AND ss.product_code = ANY(p_product_codes)
    AND ss.period_kind = 'T' AND ss.txn_kind = 1
    AND ss.sale_date >= p_from_date
  ORDER BY ss.sale_date;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_kitchen_sales(text,bigint[],date) TO anon, authenticated;
