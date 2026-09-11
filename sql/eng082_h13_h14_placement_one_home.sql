-- ENG-082 H13 with H14, STAGE 1 -- ONE PLACEMENT DERIVATION, AND THE DESK STOPS OFFERING A DC DELIVERY WHOSE
-- PLACEMENT DAY HAS PASSED. ORDERING-CANON-REGISTERS H13 and H14 (PM 2026-09-10), scope Pieter 2026-09-10: DC only.
-- (1) key placement_dow_min_orders 5, SEED UNDERIVED, H14 (b): one key, one meaning (it was borrowed from
--     in_transit_min_received_orders).
-- (2) rpc_derive_placement_day, the one home. SECURITY DEFINER, search_path pinned, EXECUTE to anon and
--     authenticated because rpc_bloom_next_deliveries is anon-callable and runs as its caller.
-- (3) rpc_bloom_promo_for_delivery 8feb43c04c694b4fa6118c87cfa0c7cd -> 3291e2b932b7684a78759d47dc6d3ea4: the inline derivation is
--     replaced by a read of the one home. Same key value, same window, same population, so membership is
--     unchanged while every admitted share clears dow_confidence_min (simulated 2026-09-11: 40 of 40 desk-dates).
-- (4) rpc_bloom_next_deliveries a5cd4735d9b4eb97adde0d8f93cd9a2f -> 0c8cdf2632201d9238aecf6737bb153f: on a DC route a date whose
--     derived placement day has passed is not offered, and the income-leg deadline is the derived placement day
--     (the non-trading-day walk still applies). Direct and dropship routes byte-unchanged.
-- NOT IN THIS STAGE: the cutoff fallback (rpc_derive_order_cutoff), the four direct VERIFY stamps, the direct
-- floor moves and the two Coca-Cola calendar rows. Stage 2.
-- Generated 2026-09-11 by CC from md5-verified live bodies; every patch asserts exactly one match.

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT 'placement_dow_min_orders', '*', 5, 'DEMO_CALIBRATION', (now() AT TIME ZONE 'Africa/Johannesburg')::date,
       'SEED, UNDERIVED. ORDERING-CANON-REGISTERS H14 (b), PM ruling 2026-09-10: a weekday is a placement day on a DC route when it carries at least this many of the store DC orders in dow_regime_lookback_days. The value is borrowed from in_transit_min_received_orders (5), which carried this second meaning inside rpc_bloom_promo_for_delivery until 2026-09-11. Chosen, not derived. Read by rpc_derive_placement_day.'
WHERE NOT EXISTS (SELECT 1 FROM public.forge_config WHERE config_key = 'placement_dow_min_orders' AND store_format = '*' AND retired_on IS NULL);

CREATE OR REPLACE FUNCTION public.rpc_derive_placement_day(p_store_code text, p_route_key text, p_delivery_date date)
 RETURNS TABLE(placement_date date, is_dc boolean, admitted_dows smallint[], admitted_share numeric, placements integer, verify boolean, basis text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- ENG-082 H13/H14 (ORDERING-CANON-REGISTERS H14, PM ruling 2026-09-10; scope Pieter 2026-09-10: DC routes only).
  -- ONE placement derivation, read by the promo test (rpc_bloom_promo_for_delivery), the desk deadline
  -- (rpc_bloom_next_deliveries) and, in the next pass, the cutoff fallback (rpc_derive_order_cutoff).
  -- On a DC route a weekday is a placement day when it carries >= placement_dow_min_orders of the store's DC
  -- orders (sigma_orders headers, direct suppliers out, the 1990 sentinel out) in the dow_regime_lookback_days
  -- before the delivery. Delivery D places on the latest admitted weekday on or before D less order_cutoff_days.
  -- The admitted weekdays must hold >= dow_confidence_min percent of the placements, else VERIFY and the
  -- calendar-day answer (D less the cutoff) carries the flag. On a direct or dropship route no weekday binds
  -- and the placement is D less the cutoff (ENG-110 add.1). SECURITY DEFINER because sigma_orders carries RLS
  -- and rpc_bloom_next_deliveries runs as its anon or authenticated caller (the ENG-068 trap).
  WITH cal AS (
    SELECT sc.order_cutoff_days::int AS cut,
           NOT EXISTS (SELECT 1 FROM bloom_route_config rc WHERE rc.store_code = sc.store_code AND rc.route_key = sc.route_key) AS is_dc
      FROM supplier_calendar sc
     WHERE sc.store_code = p_store_code AND sc.route_key = p_route_key
     LIMIT 1),
  cfg AS (
    SELECT (SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'dow_regime_lookback_days' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS lb,
           (SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'placement_dow_min_orders' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS minr,
           (SELECT fc.value_num::numeric FROM forge_config fc WHERE fc.config_key = 'dow_confidence_min' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS conf),
  wk AS (
    SELECT EXTRACT(ISODOW FROM o.order_date)::int AS dw, count(*)::int AS n
      FROM sigma_orders o
      JOIN v_supplier_class vc ON vc.store_code = o.store_code AND vc.supplier_nr = o.supplier_nr AND vc.supplier_class = 'DC'
     WHERE (SELECT cal.is_dc FROM cal)
       AND o.store_code = p_store_code
       AND o.order_date <> DATE '1990-01-01'
       AND o.order_date >= p_delivery_date - (SELECT cfg.lb FROM cfg)
       AND o.order_date < p_delivery_date
       AND NOT EXISTS (SELECT 1 FROM bloom_route_config dr WHERE dr.store_code = o.store_code AND o.supplier_nr = ANY(dr.direct_supplier_nrs))
     GROUP BY 1),
  adm AS (
    SELECT array_agg(wk.dw::smallint ORDER BY wk.dw) FILTER (WHERE wk.n >= (SELECT cfg.minr FROM cfg)) AS dows,
           COALESCE(sum(wk.n) FILTER (WHERE wk.n >= (SELECT cfg.minr FROM cfg)), 0)::int AS adm_n,
           COALESCE(sum(wk.n), 0)::int AS tot
      FROM wk),
  calc AS (
    SELECT cal.cut, cal.is_dc, adm.dows, adm.tot,
           ROUND(100.0 * adm.adm_n / NULLIF(adm.tot, 0), 1) AS share,
           (SELECT max(g.d)::date FROM generate_series(p_delivery_date - cal.cut - 6, p_delivery_date - cal.cut, interval '1 day') g(d)
             WHERE EXTRACT(ISODOW FROM g.d)::int = ANY(adm.dows)) AS derived
      FROM cal CROSS JOIN adm)
  SELECT CASE WHEN NOT calc.is_dc THEN p_delivery_date - calc.cut
              WHEN calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg) THEN calc.derived
              ELSE p_delivery_date - calc.cut END,
         calc.is_dc, calc.dows, calc.share, calc.tot,
         calc.is_dc AND NOT (calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg)),
         CASE WHEN NOT calc.is_dc THEN 'calendar days: direct or dropship route, no placement gate (ENG-110 add.1)'
              WHEN calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg) THEN 'derived from the order ledger (ORDERING-CANON-REGISTERS H14)'
              ELSE 'VERIFY: no admitted placement weekday clears dow_confidence_min; the calendar-day answer is carried (H14 c)' END
    FROM calc
$function$;

REVOKE ALL ON FUNCTION public.rpc_derive_placement_day(text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_derive_placement_day(text, text, date) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.rpc_derive_placement_day(text, text, date) IS 'GRADE: VERDICT. The placement day of one delivery on one route. Rule: a weekday is admitted at placement_dow_min_orders DC orders in dow_regime_lookback_days. Confidence: the admitted weekdays hold dow_confidence_min percent of placements. Falsifier: the ledger itself, a DC order placed on a weekday outside the admitted set. ORDERING-CANON-REGISTERS H14, the one home read by rpc_bloom_promo_for_delivery and rpc_bloom_next_deliveries. On a direct or dropship route it returns the delivery less the cutoff, no placement gate. verify true means the admitted set is below the floor and the calendar-day answer is carried. ENG-082 H13/H14 stage 1, 2026-09-11.';

DO $h13p$
DECLARE
  src text;
  i int;
  j int;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery') <> 1 THEN RAISE EXCEPTION 'rpc_bloom_promo_for_delivery: overloads <> 1'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery';
  IF md5(src) <> '8feb43c04c694b4fa6118c87cfa0c7cd' THEN RAISE EXCEPTION 'rpc_bloom_promo_for_delivery: live pin is %', md5(src); END IF;
  IF (length(src) - length(replace(src, $ps$COALESCE((
             SELECT max(g.d)::date$ps$, ''))) / length($ps$COALESCE((
             SELECT max(g.d)::date$ps$) <> 1 THEN RAISE EXCEPTION 'promo start marker not unique'; END IF;
  IF (length(src) - length(replace(src, $pe$), p_delivery_date - sc.order_cutoff_days::int) AS placement_date$pe$, ''))) / length($pe$), p_delivery_date - sc.order_cutoff_days::int) AS placement_date$pe$) <> 1 THEN RAISE EXCEPTION 'promo end marker not unique'; END IF;
  i := position($ps$COALESCE((
             SELECT max(g.d)::date$ps$ IN src);
  j := position($pe$), p_delivery_date - sc.order_cutoff_days::int) AS placement_date$pe$ IN src);
  src := substr(src, 1, i - 1) || $pn$(SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, p_delivery_date) pd) AS placement_date$pn$ || substr(src, j + length($pe$), p_delivery_date - sc.order_cutoff_days::int) AS placement_date$pe$));
  IF md5(src) <> '3291e2b932b7684a78759d47dc6d3ea4' THEN RAISE EXCEPTION 'rpc_bloom_promo_for_delivery: patched md5 is %', md5(src); END IF;
  EXECUTE src;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery';
  IF md5(src) <> '3291e2b932b7684a78759d47dc6d3ea4' THEN RAISE EXCEPTION 'rpc_bloom_promo_for_delivery: installed pin is %', md5(src); END IF;
END $h13p$;

DO $h13n$
DECLARE
  src text;
  k int;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_next_deliveries') <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries: overloads <> 1'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_next_deliveries';
  IF md5(src) <> 'a5cd4735d9b4eb97adde0d8f93cd9a2f' THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries: live pin is %', md5(src); END IF;
  k := (length(src) - length(replace(src, $o1$  v_hols int := 0;
$o1$, ''))) / length($o1$  v_hols int := 0;
$o1$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 1 matched % times', k; END IF;
  src := replace(src, $o1$  v_hols int := 0;
$o1$, $n1$  v_hols int := 0;
  v_is_dc boolean;
$n1$);
  k := (length(src) - length(replace(src, $o2$    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;
$o2$, ''))) / length($o2$    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;
$o2$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 2 matched % times', k; END IF;
  src := replace(src, $o2$    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;
$o2$, $n2$    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;

  -- ENG-082 H13 (ORDERING-CANON-REGISTERS H13; scope Pieter 2026-09-10: DC routes only). A DC route has no
  -- bloom_route_config row. Its offered dates and its deadline read the placement day derived from the
  -- order ledger (rpc_derive_placement_day, the one home of H14). A direct or dropship route is unchanged.
  v_is_dc := NOT EXISTS (SELECT 1 FROM public.bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = p_route);
$n2$);
  k := (length(src) - length(replace(src, $o3$  -- ===== UNCHANGED: the two offered delivery dates. Not one byte of this moves. =====
$o3$, ''))) / length($o3$  -- ===== UNCHANGED: the two offered delivery dates. Not one byte of this moves. =====
$o3$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 3 matched % times', k; END IF;
  src := replace(src, $o3$  -- ===== UNCHANGED: the two offered delivery dates. Not one byte of this moves. =====
$o3$, $n3$  -- ===== The two offered delivery dates. Byte-unchanged on a direct or dropship route. On a DC route
  -- (ENG-082 H13, 2026-09-11) a date whose derived placement day has already passed is not offered. =====
$n3$);
  k := (length(src) - length(replace(src, $o4$    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;$o4$, ''))) / length($o4$    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;$o4$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 4 matched % times', k; END IF;
  src := replace(src, $o4$    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;$o4$, $n4$    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows)
       AND (NOT v_is_dc OR (SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, d) pd) >= v_anchor) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;$n4$);
  k := (length(src) - length(replace(src, $o5$      v_steps := COALESCE(v_cutoff, 2);
      d := v_last_del;
      WHILE v_steps > 0 LOOP
        d := d - 1;
        IF EXISTS (SELECT 1 FROM public.calendar_events ce
                    WHERE ce.is_non_trading AND ce.event_date = d)
        THEN v_hols := v_hols + 1;
        ELSE v_steps := v_steps - 1;
        END IF;
      END LOOP;
$o5$, ''))) / length($o5$      v_steps := COALESCE(v_cutoff, 2);
      d := v_last_del;
      WHILE v_steps > 0 LOOP
        d := d - 1;
        IF EXISTS (SELECT 1 FROM public.calendar_events ce
                    WHERE ce.is_non_trading AND ce.event_date = d)
        THEN v_hols := v_hols + 1;
        ELSE v_steps := v_steps - 1;
        END IF;
      END LOOP;
$o5$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 5 matched % times', k; END IF;
  src := replace(src, $o5$      v_steps := COALESCE(v_cutoff, 2);
      d := v_last_del;
      WHILE v_steps > 0 LOOP
        d := d - 1;
        IF EXISTS (SELECT 1 FROM public.calendar_events ce
                    WHERE ce.is_non_trading AND ce.event_date = d)
        THEN v_hols := v_hols + 1;
        ELSE v_steps := v_steps - 1;
        END IF;
      END LOOP;
$o5$, $n5$      IF v_is_dc THEN
        -- ENG-082 H13: a DC deadline is the placement day the ledger derives for that delivery. The
        -- non-trading-day walk below still applies, so it never lands on one (canon 16.4 item 7).
        d := (SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, v_last_del) pd);
      ELSE
      v_steps := COALESCE(v_cutoff, 2);
      d := v_last_del;
      WHILE v_steps > 0 LOOP
        d := d - 1;
        IF EXISTS (SELECT 1 FROM public.calendar_events ce
                    WHERE ce.is_non_trading AND ce.event_date = d)
        THEN v_hols := v_hols + 1;
        ELSE v_steps := v_steps - 1;
        END IF;
      END LOOP;
      END IF;
$n5$);
  k := (length(src) - length(replace(src, $o6$      v_basis := 'delivery ' || v_last_del::text || ' less ' || COALESCE(v_cutoff,2)
                 || ' derived cutoff day(s)'
$o6$, ''))) / length($o6$      v_basis := 'delivery ' || v_last_del::text || ' less ' || COALESCE(v_cutoff,2)
                 || ' derived cutoff day(s)'
$o6$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries patch 6 matched % times', k; END IF;
  src := replace(src, $o6$      v_basis := 'delivery ' || v_last_del::text || ' less ' || COALESCE(v_cutoff,2)
                 || ' derived cutoff day(s)'
$o6$, $n6$      v_basis := CASE WHEN v_is_dc THEN 'placement day derived from the order ledger for delivery ' || v_last_del::text || ' (ENG-082 H13)'
                      ELSE 'delivery ' || v_last_del::text || ' less ' || COALESCE(v_cutoff,2)
                 || ' derived cutoff day(s)' END
$n6$);
  IF md5(src) <> '0c8cdf2632201d9238aecf6737bb153f' THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries: patched md5 is %', md5(src); END IF;
  EXECUTE src;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_next_deliveries';
  IF md5(src) <> '0c8cdf2632201d9238aecf6737bb153f' THEN RAISE EXCEPTION 'rpc_bloom_next_deliveries: installed pin is %', md5(src); END IF;
END $h13n$;

NOTIFY pgrst, 'reload schema';
