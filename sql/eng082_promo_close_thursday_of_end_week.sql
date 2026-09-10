-- eng082_promo_close_thursday_of_end_week.sql
--
-- ENG-082 -- A DC PROMOTION STAYS ORDERABLE UNTIL THE THURSDAY OF THE WEEK IT ENDS.
-- Pieter ruling 2026-09-10, from the floor: "it's still open till thursdays for all
-- promos ending during that week. that's the real solution and judgement call."
-- APPLIED 2026-09-10 as migration eng082_promo_close_thursday_of_end_week.
--
-- WHY. The engine closed a promo at the last delivery on or before its end date, so a
-- promo ending Monday to Wednesday fell off the promo sheet for that week's weekend
-- delivery while the DC still takes it at promo price. RH4 (ended Tue 2026-09-08) was
-- the worked case: its Saturday 12-09 lines rode the normal TLX at both SPARs.
--
-- TWO LEGS, AND BOTH ARE NEEDED.
--   1. rpc_bloom_promo_for_delivery: on a DC route (a route with no bloom_route_config
--      row), a delivery also matches a promo when its placement date, the delivery less
--      the route's derived order_cutoff_days, falls on or before the closing day of the
--      promo's end week. The day and the week start are config, never literals:
--      forge_config promo_order_close_dow = 4 (Thursday) and promo_order_week_start_dow
--      = 1 (Monday), both DEMO_CALIBRATION, evidence RULING. A missing key switches the
--      leg off and the old delivery-day bound stands alone.
--   2. rpc_bloom_order_recipe: promo_active (promo sheet membership) and promo_geared
--      (the shelf promo still runs on the delivery date) are separated. A line matched
--      after its shelf end rides the promo sheet at its NORMAL quantity, never the geared
--      one (ORDERING-CANON §C4, the last-day rule). Without this leg the window change
--      alone gears every post-end line up (milk 1674 @ 10116: 830 -> 1,348 packs).
--
-- WHAT IT DOES NOT COVER, named.
--   * Fresh: 6H5 and 6H6 were observed SHUT at +1 on 2026-09-09, so the rule is not
--     asserted for fresh. The DC ambient pool carries no fresh department, so no fresh
--     line reaches a desk through this change (80175 R22: only RH4, RH5 and RH6 moved).
--   * A promo ending Friday to Sunday gains nothing: its closing Thursday falls before
--     its end date and the delivery-day bound already covers it.
--   * Direct and dropship routes are untouched (leg 1 reads DC routes only).
--
-- PINS. rpc_bloom_order_recipe 49960b1265f3bad8839d763cd0088eef / 44,371 ->
--   70d99c33906f4e69fc243d1de9fbfeb0 / 44,828 (+457 chars, the six patches below).
--   rpc_bloom_promo_for_delivery 5267db982bfb3e03ee758b9085d60c93 ->
--   e09d55868beaddf74e2d10243b66913e / 2,379.
--
-- R22, a method not a literal: rebuild every orderable DC sheet and prove the same
--   lines, suggested_packs identical on every line and value identical to the cent,
--   with only promo membership moving. A six-sheet baseline was taken first, and two
--   control rebuilds on the OLD code matched it on every line (10116 DC_AMBIENT 2,401,
--   80176 DC_TOPS 218), so the inputs were stable and any difference after is the patch.
--   80175 DC_AMBIENT 12-09, both caches: 855 / 842 lines identical, suggested_packs
--   identical on every line, value R218,788.68 / R206,193.35 to the cent, 162 lines
--   moved onto promo (RH4, RH5, RH6), 96 of them ordering, 0 moved off.
--   The remaining desks are recorded in DEPLOY-LOG as they are rebuilt.
--
-- REVERT. Both prior definitions are saved verbatim in public._cc_r22_promoclose_fndefs
--   (proname, md5, def). EXECUTE each def to restore, then rebuild the caches.
--
-- The patch asserts both prior pins and every replacement count, so running it again
-- against the patched functions fails loudly rather than double-applying.

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, retired_on, notes) VALUES
('promo_order_close_dow', '*', 4, 'DEMO_CALIBRATION', DATE '2026-09-10', NULL,
 $n$RULING (Pieter, 2026-09-10, from the floor): the DC keeps a promotion orderable until this ISO weekday (4 = Thursday) of the week in which the promotion ends; the week starts on promo_order_week_start_dow. Consistent with every ambient probe observation of 2026-09-09 (RH4 open at +1; QH1, QH2, PH6 and PH1 shut at +9 to +23, both SPARs). The fresh promos 6H5 and 6H6 were shut at +1, so the rule is not asserted for fresh, and it is read only for DC routes (a route with no bloom_route_config row). Read by rpc_bloom_promo_for_delivery (ENG-082). Store #6 reads its own DC promotion order screen.$n$),
('promo_order_week_start_dow', '*', 1, 'DEMO_CALIBRATION', DATE '2026-09-10', NULL,
 $n$RULING (Pieter, 2026-09-10): the week promo_order_close_dow counts in starts on this ISO weekday (1 = Monday), the plain reading of "the week the promo ends". It adds nothing for a promo ending Friday to Sunday, because the closing Thursday then falls before the end date and the delivery-day bound already covers it. Read by rpc_bloom_promo_for_delivery (ENG-082).$n$)
ON CONFLICT (config_key, store_format) DO NOTHING;

DO $patch$
DECLARE
  s text; n int;
  f1o text := $v$SELECT sc.delivery_dows, sc.promo_buyin_lead_days$v$;
  f1n text := $v$SELECT sc.delivery_dows, sc.promo_buyin_lead_days, sc.order_cutoff_days,
           NOT EXISTS (SELECT 1 FROM public.bloom_route_config rc WHERE rc.store_code = sc.store_code AND rc.route_key = sc.route_key) AS is_dc$v$;
  f2o text := $v$AND p_delivery_date <= ($v$;
  f2n text := $v$AND (p_delivery_date <= ($v$;
  f3o text := $v$ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC$v$;
  f3n text := $v$OR (cal.is_dc
        AND (p_delivery_date - cal.order_cutoff_days::int) <= (
              pa.end_date
              - ((EXTRACT(ISODOW FROM pa.end_date)::int - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_week_start_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL) + 7) % 7)
              + (((SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_close_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL)
                  - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_week_start_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL) + 7) % 7))))
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC$v$;
  p1o text := $v$) AS promo_suffix_calc$v$;
  p1n text := $v$) AS promo_suffix_calc,
        (pm.promo_nr IS NOT NULL AND pm.end_date >= %23$L::date) AS promo_geared$v$;
  p2o text := $v$OR w.promo_active$v$;
  p2n text := $v$OR w.promo_geared$v$;
  p3o text := $v$WHEN g.promo_active THEN g.geared_packs_calc$v$;
  p3n text := $v$WHEN g.promo_geared THEN g.geared_packs_calc$v$;
  p4o text := $v$pk.geared_packs_calc AS geared_packs,$v$;
  p4n text := $v$(CASE WHEN pk.promo_active AND NOT pk.promo_geared THEN pk.normal_packs_calc ELSE pk.geared_packs_calc END)::int AS geared_packs,$v$;
  p5o text := $v$ROUND(pk.gear,4) AS promo_uplift,$v$;
  p5n text := $v$(CASE WHEN pk.promo_active AND NOT pk.promo_geared THEN 1.0 ELSE ROUND(pk.gear,4) END) AS promo_uplift,$v$;
  p6o text := $v$CASE WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,$v$;
  p6n text := $v$CASE WHEN pk.promo_nr IS NOT NULL AND NOT pk.promo_geared THEN format(' | promo %%s->%%s ended before this delivery and is ordered in its closing week at promo: normal quantity, no gear', pk.promo_start, pk.promo_end) WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,$v$;
BEGIN
  -- leg 1
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery';
  IF md5(s) <> '5267db982bfb3e03ee758b9085d60c93' THEN RAISE EXCEPTION 'promo_for_delivery pin moved: %', md5(s); END IF;
  n := (length(s) - length(replace(s, f1o, ''))) / length(f1o); IF n <> 1 THEN RAISE EXCEPTION 'f1 count %', n; END IF; s := replace(s, f1o, f1n);
  n := (length(s) - length(replace(s, f2o, ''))) / length(f2o); IF n <> 1 THEN RAISE EXCEPTION 'f2 count %', n; END IF; s := replace(s, f2o, f2n);
  n := (length(s) - length(replace(s, f3o, ''))) / length(f3o); IF n <> 1 THEN RAISE EXCEPTION 'f3 count %', n; END IF; s := replace(s, f3o, f3n);
  EXECUTE s;

  -- leg 2
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe';
  IF md5(s) <> '49960b1265f3bad8839d763cd0088eef' THEN RAISE EXCEPTION 'recipe pin moved: %', md5(s); END IF;
  n := (length(s) - length(replace(s, p1o, ''))) / length(p1o); IF n <> 1 THEN RAISE EXCEPTION 'p1 count %', n; END IF; s := replace(s, p1o, p1n);
  n := (length(s) - length(replace(s, p2o, ''))) / length(p2o); IF n <> 2 THEN RAISE EXCEPTION 'p2 count %', n; END IF; s := replace(s, p2o, p2n);
  n := (length(s) - length(replace(s, p3o, ''))) / length(p3o); IF n <> 1 THEN RAISE EXCEPTION 'p3 count %', n; END IF; s := replace(s, p3o, p3n);
  n := (length(s) - length(replace(s, p4o, ''))) / length(p4o); IF n <> 1 THEN RAISE EXCEPTION 'p4 count %', n; END IF; s := replace(s, p4o, p4n);
  n := (length(s) - length(replace(s, p5o, ''))) / length(p5o); IF n <> 1 THEN RAISE EXCEPTION 'p5 count %', n; END IF; s := replace(s, p5o, p5n);
  n := (length(s) - length(replace(s, p6o, ''))) / length(p6o); IF n <> 1 THEN RAISE EXCEPTION 'p6 count %', n; END IF; s := replace(s, p6o, p6n);
  EXECUTE s;
END $patch$;
