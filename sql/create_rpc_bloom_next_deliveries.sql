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

CREATE OR REPLACE FUNCTION public.rpc_bloom_next_deliveries(
  p_store_code text,
  p_route text,
  p_anchor_date date DEFAULT NULL
)
RETURNS TABLE(delivery_date date, following_date date)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_anchor date := COALESCE(p_anchor_date, CURRENT_DATE);
  v_dows smallint[];
  v_cutoff smallint;
  v_cycle_weeks smallint;
  v_cycle_anchor date;
  v_dates date[];
  v_week date;
  v_wb int;
  d date;
BEGIN
  SELECT sc.delivery_dows, sc.order_cutoff_days, sc.cycle_weeks, sc.cycle_anchor_week_start
    INTO v_dows, v_cutoff, v_cycle_weeks, v_cycle_anchor
  FROM public.supplier_calendar sc
  WHERE sc.store_code = p_store_code AND sc.route_key = p_route;

  IF v_dows IS NULL THEN
    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;

  v_dates := ARRAY[]::date[];
  d := v_anchor + COALESCE(v_cutoff, 2);
  WHILE array_length(v_dates,1) IS NULL OR array_length(v_dates,1) < 2 LOOP
    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      IF COALESCE(v_cycle_weeks,1) = 1 OR v_cycle_anchor IS NULL THEN
        v_dates := v_dates || d;                         -- weekly: every qualifying dow lands
      ELSE
        -- budget-week (Saturday) of d, the same anchoring the recipe uses
        v_week := d - ((EXTRACT(ISODOW FROM d)::int + 1) % 7);
        v_wb := ((v_week - v_cycle_anchor) / 7)::int;     -- whole weeks from the anchor week
        IF ((v_wb % v_cycle_weeks) + v_cycle_weeks) % v_cycle_weeks = 0 THEN
          v_dates := v_dates || d;                        -- on-cycle week only
        END IF;
      END IF;
    END IF;
    d := d + 1;
    IF d > v_anchor + GREATEST(28, COALESCE(v_cycle_weeks,1)*21 + 14) THEN
      RAISE EXCEPTION 'no two delivery dates found for store % route % (cycle_weeks %)', p_store_code, p_route, v_cycle_weeks;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_dates[1], v_dates[2];
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) TO anon, authenticated;
