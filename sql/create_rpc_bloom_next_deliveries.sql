-- create_rpc_bloom_next_deliveries.sql
-- SB-CC-BLOOM-007 item 1: one interface every consumer reads for delivery
-- dates (R30) -- the desk screen's date prepopulation and any future caller.
-- Returns the next two delivery dates on a route's calendar, inclusive of
-- p_anchor_date (today counts as "next" if today is itself a delivery day).
--
-- R22 proof (2026-07-11, anchor 2026-07-11 a Saturday): 10116 DC_AMBIENT ->
-- (11 Jul, 16 Jul); 80175 DC_AMBIENT -> (11 Jul, 15 Jul); 21355/80579
-- DC_TOPS -> (13 Jul, 16 Jul); 80176 DC_TOPS -> (11 Jul, 15 Jul); 21355
-- DIRECT_BEER -> (17 Jul, 24 Jul); 80176 DIRECT_BEER -> (14 Jul, 21 Jul).
-- All internally consistent with the seeded delivery_dows.

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
  v_dates date[];
  d date;
BEGIN
  SELECT sc.delivery_dows INTO v_dows
  FROM public.supplier_calendar sc
  WHERE sc.store_code = p_store_code AND sc.route_key = p_route;

  IF v_dows IS NULL THEN
    RAISE EXCEPTION 'no supplier_calendar row for store % route %', p_store_code, p_route;
  END IF;

  v_dates := ARRAY[]::date[];
  d := v_anchor;
  WHILE array_length(v_dates,1) IS NULL OR array_length(v_dates,1) < 2 LOOP
    IF EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows) THEN
      v_dates := v_dates || d;
    END IF;
    d := d + 1;
    IF d > v_anchor + 21 THEN
      RAISE EXCEPTION 'no two delivery dates found within 21 days for store % route %', p_store_code, p_route;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_dates[1], v_dates[2];
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_next_deliveries(text,text,date) TO anon, authenticated;
