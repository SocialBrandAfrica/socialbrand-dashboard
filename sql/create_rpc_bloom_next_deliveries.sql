-- create_rpc_bloom_next_deliveries.sql
-- SB-CC-BLOOM-007 item 1: one interface every consumer reads for delivery
-- dates (R30) -- the desk screen's date prepopulation and any future caller.
-- Returns the next two delivery dates on a route's calendar.
--
-- BUG-LOG ENG-011 (2026-07-11, found during the PM walk): the original
-- version searched inclusive of the anchor date, so a call placed ON a
-- delivery day (or too close to one) offered a delivery that has already
-- run, or one closer than the route's real order lead -- verified live:
-- 21355/DC_TOPS on Monday 2026-07-13 returned delivery 2026-07-13 itself,
-- Monday's own truck, uncatchable. Fixed: the search now starts at
-- anchor + order_cutoff_days (supplier_calendar, DEMO_CALIBRATION, default
-- 2 -- "one must order 2 days in advance at least", Pieter 2026-07-11),
-- never at the anchor itself. Reverified against the exact walk scenario:
-- anchor=2026-07-13 (Monday) now returns delivery=2026-07-16 (Thursday).

DROP FUNCTION IF EXISTS public.rpc_bloom_next_deliveries(text,text,date);

CREATE FUNCTION public.rpc_bloom_next_deliveries(
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
  v_dates date[];
  d date;
BEGIN
  SELECT sc.delivery_dows, sc.order_cutoff_days INTO v_dows, v_cutoff
  FROM public.supplier_calendar sc
  WHERE sc.store_code = p_store_code AND sc.route_key = p_route;

  IF v_dows IS NULL THEN
    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;

  v_dates := ARRAY[]::date[];
  d := v_anchor + COALESCE(v_cutoff, 2);
  WHILE array_length(v_dates,1) IS NULL OR array_length(v_dates,1) < 2 LOOP
    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      v_dates := v_dates || d;
    END IF;
    d := d + 1;
    IF d > v_anchor + 28 THEN
      RAISE EXCEPTION 'no two delivery dates found within 28 days for store % route %', p_store_code, p_route;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_dates[1], v_dates[2];
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) TO anon, authenticated;
