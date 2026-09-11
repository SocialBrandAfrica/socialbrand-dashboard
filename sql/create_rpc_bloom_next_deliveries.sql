-- create_rpc_bloom_next_deliveries.sql
-- SB-CC-BLOOM-007 item 1: one interface every consumer reads for delivery
-- dates (R30) -- the desk screen's date prepopulation and any future caller.
-- Returns the next two delivery dates on a route's calendar.
--
-- BUG-LOG ENG-011 (2026-07-11): the search starts at anchor + order_cutoff_days
-- (supplier_calendar, DEMO_CALIBRATION, default 2), never at the anchor itself --
-- a call placed on/too close to a delivery day must not offer a truck that has
-- already run or is closer than the real order lead.
--
-- ENG-025 (2026-07-18, migration cadence_law_05_next_deliveries_cycle_aware):
-- the calendar now OWNS cadence (canon section 14 v9 item 7e). This function
-- honours supplier_calendar.cycle_weeks, skipping off-weeks via a FLOORED,
-- non-negative-safe modulo (correction 2 -- Postgres % goes negative for weeks
-- before the anchor, and callers evaluate past weeks by design: the delivery
-- chain, the month projection, and rpc_backtest_l2_sales_budget all anchor in
-- the past). At cycle_weeks=1 (or a NULL anchor, only legal at cycle_weeks=1)
-- the week gate is a no-op and output is byte-identical to the pre-cycle
-- behaviour -- that identity is the zero-delta proof (verified live 2026-07-18,
-- all 11 direct desks + DC/BEER unchanged at anchor 2026-07-18).

-- RE-SPLICED FROM LIVE 2026-09-11 by CC (ENG-082 H13, migration eng082_h13_h14_placement_one_home): the body is
-- live 0c8cdf2632201d9238aecf6737bb153f / 6,445 chars, via the MCP result file as base64, hash-gated on disk. On a DC
-- route a date whose derived placement day has passed is not offered, and the deadline is the derived placement
-- day (rpc_derive_placement_day). Direct and dropship routes byte-unchanged. Prior body a5cd4735d9b4eb97adde0d8f93cd9a2f,
-- retired 2026-09-11 (R28).

CREATE OR REPLACE FUNCTION public.rpc_bloom_next_deliveries(p_store_code text, p_route text, p_anchor_date date DEFAULT NULL::date)
 RETURNS TABLE(delivery_date date, following_date date, income_window_start date, income_window_streams text, last_delivery_before_income date, placement_deadline date, placement_deadline_basis text, income_calendar_state text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  -- ENG-117: was COALESCE(p_anchor_date, CURRENT_DATE). CURRENT_DATE is the SESSION
  -- date and the session is UTC while the store is not, so every nightly build
  -- (all of which run 22:00-00:00 store time) anchored a calendar day behind the
  -- store it was built for. The anchor is now the STORE's own today.
  v_anchor date := COALESCE(p_anchor_date, public.store_local_today(p_store_code));
  v_dows smallint[];
  v_cutoff smallint;
  v_cycle_weeks smallint;
  v_cycle_anchor date;
  v_dates date[];
  v_week date;
  v_wb int;
  d date;
  -- ENG-056 locals
  v_win_start date;
  v_streams text;
  v_last_del date;
  v_deadline date;
  v_basis text;
  v_state text;
  v_steps int;
  v_max_cal date;
  v_hols int := 0;
  v_is_dc boolean;
BEGIN
  SELECT sc.delivery_dows, sc.order_cutoff_days, sc.cycle_weeks, sc.cycle_anchor_week_start
    INTO v_dows, v_cutoff, v_cycle_weeks, v_cycle_anchor
  FROM public.supplier_calendar sc
  WHERE sc.store_code = p_store_code AND sc.route_key = p_route;

  IF v_dows IS NULL THEN
    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;

  -- ENG-082 H13 (ORDERING-CANON-REGISTERS H13; scope Pieter 2026-09-10: DC routes only). A DC route has no
  -- bloom_route_config row. Its offered dates and its deadline read the placement day derived from the
  -- order ledger (rpc_derive_placement_day, the one home of H14). A direct or dropship route is unchanged.
  v_is_dc := NOT EXISTS (SELECT 1 FROM public.bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = p_route);

  -- ===== The two offered delivery dates. Byte-unchanged on a direct or dropship route. On a DC route
  -- (ENG-082 H13, 2026-09-11) a date whose derived placement day has already passed is not offered. =====
  v_dates := ARRAY[]::date[];
  d := v_anchor + COALESCE(v_cutoff, 2);            -- BUG-LOG ENG-011
  WHILE array_length(v_dates,1) IS NULL OR array_length(v_dates,1) < 2 LOOP
    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows)
       AND (NOT v_is_dc OR (SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, d) pd) >= v_anchor) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;
      ELSE
        v_week := d - ((EXTRACT(ISODOW FROM d)::int + 1) % 7);
        v_wb := ((v_week - v_cycle_anchor) / 7)::int;
        IF ((v_wb % v_cycle_weeks) + v_cycle_weeks) % v_cycle_weeks = 0 THEN
          v_dates := v_dates || d;
        END IF;
      END IF;
    END IF;
    d := d + 1;
    IF d > v_anchor + GREATEST(28, COALESCE(v_cycle_weeks,1)*21 + 14) THEN
      RAISE EXCEPTION 'no two delivery dates found for store % route % (cycle_weeks %)', p_store_code, p_route, v_cycle_weeks;
    END IF;
  END LOOP;

  -- ===== ENG-056: THE LAST DELIVERY BEFORE THE INCOME WINDOW, AND ITS DEADLINE =====
  SELECT MIN(ce.event_date) INTO v_win_start
  FROM public.calendar_events ce
  WHERE ce.event_type = 'SASSA_PAYMENT' AND ce.event_date >= v_anchor;

  SELECT MAX(ce.event_date) INTO v_max_cal
  FROM public.calendar_events ce WHERE ce.event_type = 'SASSA_PAYMENT';

  IF v_win_start IS NULL THEN
    v_state := CASE WHEN v_max_cal IS NULL
                 THEN 'no income calendar loaded'
                 ELSE 'income calendar ends ' || v_max_cal::text || ' -- load the next period' END;
  ELSE
    SELECT string_agg(ce.event_stream || ' ' || to_char(ce.event_date,'DD Mon'), ', ' ORDER BY ce.event_date)
      INTO v_streams
    FROM public.calendar_events ce
    WHERE ce.event_type = 'SASSA_PAYMENT'
      AND ce.event_date BETWEEN v_win_start AND v_win_start + 13;

    d := v_win_start - 1;
    WHILE v_last_del IS NULL AND d > v_win_start - 60 LOOP
      IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
        IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
          v_last_del := d;
        ELSE
          v_week := d - ((EXTRACT(ISODOW FROM d)::int + 1) % 7);
          v_wb := ((v_week - v_cycle_anchor) / 7)::int;
          IF ((v_wb % v_cycle_weeks) + v_cycle_weeks) % v_cycle_weeks = 0 THEN v_last_del := d; END IF;
        END IF;
      END IF;
      d := d - 1;
    END LOOP;

    IF v_last_del IS NOT NULL THEN
      IF v_is_dc THEN
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
      WHILE EXISTS (SELECT 1 FROM public.calendar_events ce
                     WHERE ce.is_non_trading AND ce.event_date = d) LOOP
        d := d - 1; v_hols := v_hols + 1;
      END LOOP;
      v_deadline := d;
      v_basis := CASE WHEN v_is_dc THEN 'placement day derived from the order ledger for delivery ' || v_last_del::text || ' (ENG-082 H13)'
                      ELSE 'delivery ' || v_last_del::text || ' less ' || COALESCE(v_cutoff,2)
                 || ' derived cutoff day(s)' END
                 || CASE WHEN v_hols > 0 THEN ', ' || v_hols || ' public holiday(s) skipped (canon §16.4 item 7)'
                         ELSE '' END;
      v_state := CASE WHEN v_deadline < v_anchor THEN 'INCOME BUILD CLOSED'
                      WHEN v_deadline = v_anchor THEN 'INCOME BUILD PLACE TODAY'
                      ELSE 'INCOME BUILD OPEN' END;
    ELSE
      v_state := 'no delivery found before the income window';
    END IF;
  END IF;

  RETURN QUERY SELECT v_dates[1], v_dates[2],
                      v_win_start, v_streams, v_last_del, v_deadline, v_basis, v_state;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) TO anon, authenticated;
