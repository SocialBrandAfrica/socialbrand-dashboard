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


-- =============================================================================
-- 2026-08-24 (ENG-088, SB-CC-BLOOM-026 §13 Ruling C, CC). READS THE CACHE.
--
-- Order 1 now reads bloom_order_cache_line. Order 2 returns a LABELLED
-- "not precomputed" -- NULL lines and NULL value with the reason in `story`.
--
-- WHY ORDER 2 IS NOT BUILT, and it is sequencing not laziness (PM ruling):
-- order 2 re-ran the recipe with a p_soh_override, and no cache holds an
-- override variant. Mechanism (e5) -- the pre-order stock pull with its
-- permanent import leg -- will OWN override variants. Precomputing them now is
-- work (e5) throws away. Half a fix is acceptable when the other half is
-- scheduled and the alternative is throwaway work.
--
-- Verified 2026-08-24 00:3x SAST, 80175 DC_AMBIENT: d1 2026-08-26, d2 08-29,
-- d3 09-02, order 1 = 206 lines / R108,250.50 -- ties EXACTLY to PM's
-- independently measured figure for that desk.
--
-- 🔴 NULL means NOT COMPUTED and must never render as R0. A cache MISS RAISES
-- rather than returning a zero-line chain, because a zero-line chain reads as
-- "the next drop needs nothing", which is a lie about the buyer's next order
-- (R22 §3). A miss and a failure stay distinguishable on screen (ENG-097).
--
-- The in-body SET LOCAL statement_timeout that stood here is GONE: it was
-- decorative (ENG-096, proven by probe). The bound is armed by the caller or
-- the role, never in-body.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_delivery_chain(p_store_code text, p_route text, p_order1_overrides jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(store_code text, route text, d1 date, d2 date, d3 date, order1_lines integer, order1_value numeric, order2_projected_lines integer, order2_projected_value numeric, story text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_d1 date; v_d2 date; v_d2_check date; v_d3 date;
  v_order1_lines int; v_order1_value numeric;
  v_cache_id bigint; v_avail text;
BEGIN
  SELECT nd.delivery_date, nd.following_date INTO v_d1, v_d2
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, CURRENT_DATE) nd;

  SELECT nd.delivery_date, nd.following_date INTO v_d2_check, v_d3
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, v_d1) nd;

  IF v_d2_check IS DISTINCT FROM v_d2 THEN
    RAISE WARNING 'rpc_bloom_delivery_chain: D2 mismatch walking from D1 (% vs %) -- calendar cadence may be irregular for store % route %',
      v_d2_check, v_d2, p_store_code, p_route;
  END IF;

  SELECT c.cache_id INTO v_cache_id
    FROM public.bloom_order_cache c
   WHERE c.store_code = p_store_code AND c.route_key = p_route
     AND c.delivery_date = v_d1 AND c.next_delivery = v_d2
     AND c.preset = 'standard' AND c.fit_to_budget = false
   ORDER BY c.generated_at DESC LIMIT 1;

  IF v_cache_id IS NULL THEN
    SELECT string_agg(DISTINCT c.delivery_date::text || ' to ' || c.next_delivery::text, ', ')
      INTO v_avail
      FROM public.bloom_order_cache c
     WHERE c.store_code = p_store_code AND c.route_key = p_route
       AND c.delivery_date >= CURRENT_DATE - 1;
    RAISE EXCEPTION
      'Delivery chain unavailable: no cached order for % % delivery % to %. Cached on this desk: %. Failing loudly rather than returning a zero-line chain, because that would read as "the next drop needs nothing".',
      p_store_code, p_route, v_d1, v_d2,
      COALESCE(v_avail, 'nothing yet -- the nightly rebuild runs 01:30 SAST');
  END IF;

  -- Order 1 off the CACHED lines. Overrides applied arithmetically; the engine
  -- keeps ownership of pool membership, an unknown code is ignored not added.
  SELECT
    count(*) FILTER (WHERE COALESCE((p_order1_overrides ->> (l.product_code::text))::int, l.suggested_packs) > 0),
    SUM(CASE WHEN p_order1_overrides ? l.product_code::text
          THEN (p_order1_overrides ->> (l.product_code::text))::int * l.pack_cost
          ELSE l.value END)
  INTO v_order1_lines, v_order1_value
  FROM public.bloom_order_cache_line l
  WHERE l.cache_id = v_cache_id;

  RETURN QUERY SELECT
    p_store_code, p_route, v_d1, v_d2, v_d3,
    v_order1_lines, ROUND(COALESCE(v_order1_value,0), 2),
    NULL::integer, NULL::numeric,
    format('If this lands %s, the next drop is %s. The %s projection is NOT PRECOMPUTED -- it needs a stock-override run the cache does not hold, and that lands with the pre-order stock pull (SB-CC-BLOOM-026 mechanism e5). Not a failure and not zero: not computed.',
      to_char(v_d1, 'Dy DD Mon'), to_char(v_d2, 'Dy DD Mon'), to_char(v_d2, 'Dy DD Mon'));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_delivery_chain(text,text,jsonb) TO anon, authenticated;
