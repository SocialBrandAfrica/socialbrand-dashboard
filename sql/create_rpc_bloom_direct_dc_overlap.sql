-- SB-CC / ENG-025 step 4 : the DC-overlap double-count guard (PM ruling 2026-07-18).
-- A DIRECT_<brand> desk scopes its pool by supplier LINK (bloom_route_config.direct_supplier_nrs);
-- the DC desk scopes by DEPARTMENT (bloom_dc_config.dc_cycle_dept_nrs). A product in both pools
-- would be ordered twice. This surfaces the overlap so a desk is never activated on an unchecked
-- assumption (R22/R29 -- flag, never block). Runnable BEFORE the calendar is seeded (reads config +
-- the DC recipe only), so it gates activation. Applied 2026-07-18, migration
-- cadence_law_07_direct_dc_overlap_guard. Live proof: DIRECT_COCACOLA@21355 and DIRECT_NATBRANDS@80175
-- both return overlap_lines=0 ("clean").
CREATE OR REPLACE FUNCTION public.rpc_bloom_direct_dc_overlap(
  p_store_code text,
  p_route_key  text
)
RETURNS TABLE (
  store_code text, direct_route text, dc_route text,
  direct_linked_products int, dc_ordered_lines int,
  overlap_lines int, overlap_products bigint[], verdict text
)
LANGUAGE plpgsql STABLE SET search_path = public AS $fn$
DECLARE
  v_snrs bigint[];
  v_fmt text;
  v_dc_route text;
  v_del date; v_next date;
BEGIN
  SELECT rc.direct_supplier_nrs::bigint[] INTO v_snrs
  FROM bloom_route_config rc WHERE rc.store_code=p_store_code AND rc.route_key=p_route_key AND rc.status='RULED';
  IF v_snrs IS NULL THEN
    RAISE EXCEPTION 'no RULED bloom_route_config row (with direct_supplier_nrs) for store % route %', p_store_code, p_route_key;
  END IF;

  SELECT dc.format_group INTO v_fmt FROM bloom_dc_config dc WHERE dc.store_code=p_store_code AND dc.status='RULED';
  v_dc_route := CASE WHEN v_fmt='SPAR' THEN 'DC_AMBIENT' WHEN v_fmt='TOPS' THEN 'DC_TOPS' ELSE NULL END;
  IF v_dc_route IS NULL THEN
    RAISE EXCEPTION 'no RULED bloom_dc_config format_group for store %', p_store_code;
  END IF;

  SELECT nd.delivery_date, nd.following_date INTO v_del, v_next
  FROM rpc_bloom_next_deliveries(p_store_code, v_dc_route, CURRENT_DATE) nd;

  RETURN QUERY
  WITH dc AS (
    SELECT r.product_code
    FROM rpc_bloom_order_recipe(p_store_code, v_del, v_next, NULL, NULL, NULL, false, 15,24,25,3.0, v_dc_route) r
    WHERE r.suggested_packs > 0
  ),
  linked AS (
    SELECT DISTINCT sl.product_code FROM sigma_supplier_link sl
    WHERE sl.store_code=p_store_code AND sl.supplier_nr = ANY(v_snrs)
  ),
  ov AS (SELECT d.product_code FROM dc d JOIN linked l USING(product_code))
  SELECT p_store_code, p_route_key, v_dc_route,
         (SELECT count(*)::int FROM linked),
         (SELECT count(*)::int FROM dc),
         (SELECT count(*)::int FROM ov),
         COALESCE((SELECT array_agg(product_code ORDER BY product_code) FROM ov), '{}'::bigint[]),
         CASE WHEN (SELECT count(*) FROM ov)=0 THEN 'clean -- no DC double-count'
              ELSE format('REVIEW: %s product(s) in BOTH the %s pool and %s -- would be ordered twice',
                          (SELECT count(*) FROM ov), p_route_key, v_dc_route) END;
END $fn$;

REVOKE ALL ON FUNCTION public.rpc_bloom_direct_dc_overlap(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_direct_dc_overlap(text,text) TO authenticated;
