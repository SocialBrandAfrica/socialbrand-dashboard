-- eng082_promo_placement_day.sql
--
-- ENG-082 addendum 8 -- THE PROMO TEST READS THE DAY THE ORDER IS PLACED, DERIVED FROM THE
-- ORDER LEDGER, NOT THE DELIVERY LESS THE CUTOFF IN CALENDAR DAYS.
-- APPLIED 2026-09-10 as migration eng082_promo_placement_day.
--
-- WHY. The Thursday rule (eng082_promo_close_thursday_of_end_week, earlier the same day) took
-- the placement day as the delivery less order_cutoff_days. For a Saturday delivery that is
-- Thursday, the day the order goes in. For a Monday delivery it is Saturday, a day no TOPS DC
-- order goes in, so RW4 and RW5 (ended Tue 2026-09-08) matched no line on the TOPS Monday
-- sheets at 21355 and 80579 while the same promos matched 80176's Saturday sheet. Pieter,
-- 2026-09-10, from the floor: TOPS orders go in any day, but the Thursday order serves the
-- Saturday or the Monday delivery.
--
-- THE RULE. On a DC route, the placement day for delivery D is the LAST day on or before D less
-- order_cutoff_days whose weekday is one the route actually places orders on. A placement
-- weekday carries at least in_transit_min_received_orders DC orders in the
-- dow_regime_lookback_days window before D (sigma_orders.order_date, header grain, the
-- 1990-01-01 sentinel excluded, a DC-class supplier that is not a direct supplier of the
-- store, the same route test rpc_derive_order_cutoff uses). ORDERING-CANON A5: placement days
-- are derived from the ledger, never typed. Both keys already exist and rpc_derive_order_cutoff
-- reads the first as the same placement evidence floor, so no new key. A route with no weekday
-- clearing the floor keeps D less the cutoff, the old behaviour. The window ends at D, so the
-- answer depends on the inputs and not on the day the function runs.
--
-- EVIDENCE (CONTROLLED, the 84 days to 2026-09-10, DC orders carrying a real order_date).
-- 21355, 80176 and 80579: 134 placements, 0 on a Friday, 0 on a Saturday, 2 on a Sunday
-- (80176), Thursday the modal day at all three. 10116: Monday to Thursday, 2 of 249 on a
-- Saturday. 80175: Monday to Thursday plus Sunday, 2 of 242 on a Friday. expected_grv_date
-- cannot pair an order with its delivery (leads run down to -7,312 days), so the placement
-- weekdays are read directly rather than paired.
--
-- SIMULATED BEFORE APPLYING, as a pure read: every DC desk x every delivery day from
-- 2026-09-11 to 2026-10-02, 29 desk-dates. Only the TOPS Monday deliveries move, at 21355 and
-- 80579: 14-09 placement Sat -> Thu, post-end promo products 0 -> 333 and 0 -> 302. 21-09:
-- 0 -> 5 at each. 28-09: 0 -> 140 and 0 -> 123. Every Saturday, Wednesday and Thursday
-- delivery at all five stores keeps its placement day and its match count.
--
-- PIN. rpc_bloom_promo_for_delivery e09d55868beaddf74e2d10243b66913e -> DEPLOY-LOG 2026-09-10.
-- rpc_bloom_order_recipe does not move: it reads this home.
--
-- REVERT. The prior body is sql/create_rpc_bloom_promo_for_delivery.sql at commit 32781fb.
-- EXECUTE it, then rebuild the caches.
--
-- The patch asserts the prior pin and both replacement counts, so running it again against
-- the patched function fails loudly rather than double-applying.

DO $patch$
DECLARE
  s text; n int;
  f1o text := $v$rc.route_key = sc.route_key) AS is_dc$v$;
  f1n text := $v$rc.route_key = sc.route_key) AS is_dc,
           COALESCE((
             SELECT max(g.d)::date
             FROM generate_series(p_delivery_date - sc.order_cutoff_days::int - 6, p_delivery_date - sc.order_cutoff_days::int, interval '1 day') g(d)
             WHERE EXTRACT(ISODOW FROM g.d)::int IN (
               SELECT EXTRACT(ISODOW FROM o.order_date)::int
               FROM public.sigma_orders o
               JOIN public.v_supplier_class vc ON vc.store_code = o.store_code AND vc.supplier_nr = o.supplier_nr AND vc.supplier_class = 'DC'
               WHERE o.store_code = p_store_code
                 AND o.order_date <> DATE '1990-01-01'
                 AND o.order_date >= p_delivery_date - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'dow_regime_lookback_days' AND fc.store_format = '*' AND fc.retired_on IS NULL)
                 AND o.order_date < p_delivery_date
                 AND NOT EXISTS (SELECT 1 FROM public.bloom_route_config rd WHERE rd.store_code = o.store_code AND o.supplier_nr = ANY(rd.direct_supplier_nrs))
               GROUP BY 1
               HAVING count(*) >= (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'in_transit_min_received_orders' AND fc.store_format = '*' AND fc.retired_on IS NULL))
           ), p_delivery_date - sc.order_cutoff_days::int) AS placement_date$v$;
  f2o text := $v$AND (p_delivery_date - cal.order_cutoff_days::int) <= ($v$;
  f2n text := $v$AND cal.placement_date <= ($v$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery';
  IF md5(s) <> 'e09d55868beaddf74e2d10243b66913e' THEN RAISE EXCEPTION 'promo_for_delivery pin moved: %', md5(s); END IF;
  n := (length(s) - length(replace(s, f1o, ''))) / length(f1o); IF n <> 1 THEN RAISE EXCEPTION 'f1 count %', n; END IF; s := replace(s, f1o, f1n);
  n := (length(s) - length(replace(s, f2o, ''))) / length(f2o); IF n <> 1 THEN RAISE EXCEPTION 'f2 count %', n; END IF; s := replace(s, f2o, f2n);
  EXECUTE s;
END $patch$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS $c$ENG-147 + ENG-082. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. A promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC route, the placement day for D falls on or before the promo_order_close_dow of the week the promo ends (Pieter ruling 2026-09-10). The placement day is the last day on or before D less order_cutoff_days whose weekday carried at least in_transit_min_received_orders DC orders in the dow_regime_lookback_days window before D (ORDERING-CANON A5, derived from sigma_orders). Supersedes the 2026-08-27 comment, which stated the end-date bound only and named three inline sites that no longer exist.$c$;

SELECT pg_notify('pgrst', 'reload schema');
