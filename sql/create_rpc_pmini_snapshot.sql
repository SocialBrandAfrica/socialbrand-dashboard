-- ============================================================================
-- rpc_pmini_snapshot -- current SOH/price/description for a fixed EAN list
-- ============================================================================
-- R30 repair (2026-07-06). Pulse Mini's product tiles (src/app/api/dev-corner/
-- lines/route.js) read daily_snapshots directly for the "current snapshot"
-- per EAN. daily_snapshots is frozen at 2026-06-28 (RETIRE-002/003) and its
-- own RLS has no anon SELECT policy -- the route was serving stale, silently
-- degrading data every day since the freeze. This RPC reads the always-latest
-- sigma-native engine table (l2_stock_position) instead, resolved to EAN via
-- v_ean_bridge, so the route can drop its direct table reads entirely.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_pmini_snapshot(p_store_code text, p_eans text[])
 RETURNS TABLE(ean text, description text, dept_name text, sub_dept_name text, soh numeric, sell_price numeric, unit_cost numeric, last_sale_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  SELECT b.ean, sp.description, sp.dept_name, sp.subdept_name AS sub_dept_name,
         sp.soh, sp.sell_price_incl_vat AS sell_price, sp.unit_cost, sp.last_sale_date
  FROM public.v_ean_bridge b
  JOIN public.l2_stock_position sp ON sp.store_code = b.store_code AND sp.product_code = b.product_code
  WHERE b.store_code = p_store_code AND b.ean = ANY(p_eans);
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_pmini_snapshot(text,text[]) TO anon, authenticated;
