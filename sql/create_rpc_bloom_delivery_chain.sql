-- =============================================================================
-- create_rpc_bloom_delivery_chain.sql
-- SB-CC-BLOOM-008 item 16(a) -- THE DELIVERY CHAIN, two-drop if-then.
--
-- "order 1 for delivery D1, projected order 2 for D2 computed on simulated
-- SOH (proj + order1 units − demand×(D2−D1)), needing D3 for drop 2's own
-- cover" -- the brief's own formula, implemented LITERALLY against order
-- 1's own recipe run (the same one the desk screen already generates and
-- shows -- p_next_delivery=D2, i.e. the calendar drop-cover lead already
-- used for every real order this session, ENG-012). Order 2 is never a
-- parallel/hand-rolled formula (R21): it is a genuine second call to
-- rpc_bloom_order_recipe, at D2 with D3 as its own next_delivery (so its
-- own band/review math is the real thing a drop-2 order would use), fed
-- the simulated per-line SOH via the new p_soh_override parameter
-- (SB-CC-BLOOM-008 item 16(a) addition to the recipe itself).
--
-- p_order1_overrides lets the caller pass the BUYER'S OWN on-screen edited
-- quantities for order 1 (product_code -> qty) instead of the recipe's raw
-- suggested_packs -- "shown beside the generate" means this teaser reacts
-- to what the buyer is actually about to submit, not a hypothetical.
-- Omitted/NULL for every product falls back to suggested_packs.
--
-- D3 resolution: rpc_bloom_next_deliveries anchored at D1 (not today) --
-- walks forward from D1+order_cutoff_days, which for every route currently
-- live (cutoff < the gap between two real drops) lands on D2 as its own
-- first result and D3 as its second, without a separate calendar-walk
-- formula (R21, reuses the existing interface).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_delivery_chain(text,text,jsonb);

CREATE FUNCTION public.rpc_bloom_delivery_chain(
  p_store_code text,
  p_route text,
  p_order1_overrides jsonb DEFAULT NULL::jsonb
)
RETURNS TABLE(
  store_code text, route text,
  d1 date, d2 date, d3 date,
  order1_lines integer, order1_value numeric,
  order2_projected_lines integer, order2_projected_value numeric,
  story text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_d1 date; v_d2 date; v_d2_check date; v_d3 date;
  v_order1_lines int; v_order1_value numeric;
  v_order2_lines int; v_order2_value numeric;
  v_soh_override jsonb;
BEGIN
  SET LOCAL statement_timeout = '30s';

  SELECT nd.delivery_date, nd.following_date INTO v_d1, v_d2
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, CURRENT_DATE) nd;

  SELECT nd.delivery_date, nd.following_date INTO v_d2_check, v_d3
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, v_d1) nd;

  IF v_d2_check IS DISTINCT FROM v_d2 THEN
    RAISE WARNING 'rpc_bloom_delivery_chain: D2 mismatch walking from D1 (% vs %) -- calendar cadence may be irregular for store % route %',
      v_d2_check, v_d2, p_store_code, p_route;
  END IF;

  EXECUTE 'DROP TABLE IF EXISTS _chain_order1';
  CREATE TEMP TABLE _chain_order1 AS
  SELECT r.product_code, r.rhythm_adjusted_demand AS demand, r.projected_soh AS proj,
    r.pack_size, r.pack_cost, r.suggested_packs, r.value
  FROM public.rpc_bloom_order_recipe(p_store_code, v_d1, v_d2, NULL, NULL, NULL, false, 15, 24, 25, 3.0, p_route) r;

  -- Unedited lines (no key in p_order1_overrides) sum the recipe's own
  -- already-rounded `value` column -- exact match to what the desk screen
  -- itself totals, never a re-derived figure. Only an edited line's own
  -- value is recomputed off the buyer's override qty.
  SELECT
    count(*) FILTER (WHERE COALESCE((p_order1_overrides ->> (c.product_code::text))::int, c.suggested_packs) > 0),
    SUM(CASE WHEN p_order1_overrides ? c.product_code::text
          THEN (p_order1_overrides ->> (c.product_code::text))::int * c.pack_cost
          ELSE c.value END)
  INTO v_order1_lines, v_order1_value
  FROM _chain_order1 c;

  -- Simulated SOH at D2, the brief's own literal formula: this order's proj
  -- (soh depleted over the D1-D2 lead, the SAME figure the desk screen
  -- already shows) + order 1's own units landing - further demand over the
  -- D1-D2 gap again. Not clamped at 0 -- a genuinely over-committed line
  -- should show as a real negative simulated position, not be silently
  -- floored.
  SELECT jsonb_object_agg(
    c.product_code::text,
    c.proj + (COALESCE((p_order1_overrides ->> (c.product_code::text))::int, c.suggested_packs) * c.pack_size) - c.demand * (v_d2 - v_d1)
  )
  INTO v_soh_override
  FROM _chain_order1 c;

  EXECUTE 'DROP TABLE IF EXISTS _chain_order2';
  CREATE TEMP TABLE _chain_order2 AS
  SELECT r.product_code, r.suggested_packs, r.value
  FROM public.rpc_bloom_order_recipe(p_store_code, v_d2, v_d3, NULL, NULL, NULL, false, 15, 24, 25, 3.0, p_route, v_soh_override) r;

  SELECT count(*) FILTER (WHERE c2.suggested_packs > 0), SUM(c2.value)
  INTO v_order2_lines, v_order2_value
  FROM _chain_order2 c2;

  EXECUTE 'DROP TABLE IF EXISTS _chain_order1';
  EXECUTE 'DROP TABLE IF EXISTS _chain_order2';

  RETURN QUERY SELECT
    p_store_code, p_route, v_d1, v_d2, v_d3,
    v_order1_lines, ROUND(v_order1_value, 2),
    v_order2_lines, ROUND(COALESCE(v_order2_value, 0), 2),
    format('If this lands %s, %s''s order will be ~R%s',
      to_char(v_d1, 'Dy DD Mon'), to_char(v_d2, 'Dy DD Mon'),
      to_char(ROUND(COALESCE(v_order2_value, 0), 0), 'FM999,999,999'));
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_delivery_chain(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_delivery_chain(text,text,jsonb) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
