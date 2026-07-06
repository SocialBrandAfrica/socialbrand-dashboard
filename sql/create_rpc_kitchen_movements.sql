-- ============================================================================
-- rpc_kitchen_movements -- non-sale movements for a fixed product list (Kitchen tab)
-- ============================================================================
-- R30 repair (2026-07-06). Companion to rpc_kitchen_sales -- same broken
-- direct-read pattern in fetchKitchen(), same fix. Excludes movement_type='K'
-- (till sale) since that's covered by rpc_kitchen_sales already.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_kitchen_movements(p_store_code text, p_product_codes bigint[], p_from_date date)
 RETURNS TABLE(product_code bigint, movement_type text, movement_process text, movement_date date, qty numeric, new_soh numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  SELECT sm.product_code, sm.movement_type, sm.movement_process, sm.movement_date, sm.qty, sm.new_soh
  FROM public.sigma_movements sm
  WHERE sm.store_code = p_store_code AND sm.product_code = ANY(p_product_codes)
    AND sm.movement_date >= p_from_date AND sm.movement_type <> 'K'
  ORDER BY sm.movement_date;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_kitchen_movements(text,bigint[],date) TO anon, authenticated;
