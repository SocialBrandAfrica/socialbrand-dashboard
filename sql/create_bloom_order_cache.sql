-- =====================================================================
-- create_bloom_order_cache.sql
-- ENG-088 -- the Bloom order desk READS a precomputed order (R32).
--
-- WHY THIS EXISTS, measured at source 2026-08-16 on a QUIET database:
--   rpc_bloom_order_recipe('10116', '2026-08-20','2026-08-22', ... 'DC_AMBIENT')
--   costs ~36s (43.6s including the persist write). The ceiling is a 30s
--   statement_timeout carried as a ROLE setting by BOTH anon and authenticated,
--   so the on-screen error is the POSTGRES message, not a Kong error, and the
--   screen could never legally finish. Proven through PostgREST as anon:
--     live recipe   -> HTTP 500 in 31.6s, 57014 canceling statement due to statement timeout
--     cached read   -> HTTP 200 in  3.0s, 1,065 of 1,065 lines
--
-- WHY NOT "CUT THE 23%": Path A was executed to its conclusion first. The
-- dynamic SQL was extracted from the function body and EXPLAIN (ANALYZE, BUFFERS)
-- run on it directly. There is NO hotspot to cut. The named suspects were
-- REFUTED by measurement:
--   * promo_match's per-row generate_series ran 58,910 times but costs ~0.5s;
--     constant-folding it away measured SLOWER (35.3s vs 32.7s, alternating A/B).
--     It only LOOKED like a 21s node because the banded2 CTE materialisation
--     sits inside it.
--   * raising work_mem 2.1MB -> 96MB measured WORSE (65.6s vs 37.9s). Do not.
-- The ~32s is the honest cost of building 12,741 wide rows through a 37-CTE
-- chain; every node estimates rows=83 against 12,741 actual. Earlier sessions
-- already banked the localised wins (52.7 -> 38.1s).
--
-- THIS FILE TOUCHES rpc_bloom_order_recipe IN NO WAY. It is purely additive.
-- Generate-on-demand stays for off-calendar dates, where slow is acceptable
-- because it is the exception.
--
-- Owner: CC. Canon: ORDERING-CANON SSA4 (drop cover / supplier_calendar),
-- R32 SS3 (the pantry is stocked applet-ready, an applet READS), R30 add.2
-- (writes via published functions), R22/R29 (provenance travels).
-- =====================================================================

-- ---------- header ----------
CREATE TABLE IF NOT EXISTS public.bloom_order_cache (
  cache_id      bigserial PRIMARY KEY,
  client_id     text        NOT NULL DEFAULT 'socialbrand',
  store_code    text        NOT NULL,
  route_key     text        NOT NULL,
  delivery_date date        NOT NULL,
  next_delivery date        NOT NULL,
  preset        text        NOT NULL DEFAULT 'standard',
  fit_to_budget boolean     NOT NULL DEFAULT false,
  generated_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  generation_ms integer,
  line_count    integer,
  engine_md5    text,
  source        text        NOT NULL DEFAULT 'nightly',
  CONSTRAINT bloom_order_cache_key UNIQUE
    (client_id, store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget)
);

COMMENT ON TABLE public.bloom_order_cache IS
  'ENG-088. Header for a precomputed rpc_bloom_order_recipe run. The desk READS this; it never computes the recipe on the request thread (R32). engine_md5 pins which recipe body produced the rows, so a stale cache is detectable rather than silent (R22/R29).';

-- ---------- lines ----------
-- Generated from the recipe's OWN RETURNS TABLE spec, never hand-enumerated, so
-- the cache cannot silently drift from the function's column set.
DO $mk$
DECLARE spec text; cols text;
BEGIN
  IF to_regclass('public.bloom_order_cache_line') IS NOT NULL THEN RETURN; END IF;
  SELECT pg_get_function_result(p.oid) INTO spec
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_bloom_order_recipe';
  IF spec IS NULL OR left(spec,6) <> 'TABLE(' THEN
    RAISE EXCEPTION 'recipe result spec not in expected TABLE(...) form: %', left(spec,40);
  END IF;
  cols := substring(spec from 7 for length(spec)-7);
  EXECUTE 'CREATE TABLE public.bloom_order_cache_line (
             cache_id bigint NOT NULL REFERENCES public.bloom_order_cache(cache_id) ON DELETE CASCADE,
             line_no  integer NOT NULL, ' || cols || ')';
END $mk$;

-- R29: every cached line carries its own provenance.
ALTER TABLE public.bloom_order_cache_line ADD COLUMN IF NOT EXISTS generated_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_bloom_order_cache_line_cache
  ON public.bloom_order_cache_line (cache_id, line_no);
CREATE INDEX IF NOT EXISTS idx_bloom_order_cache_lookup
  ON public.bloom_order_cache (store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget);

ALTER TABLE public.bloom_order_cache      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bloom_order_cache_line ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bloom_order_cache_read      ON public.bloom_order_cache;
DROP POLICY IF EXISTS bloom_order_cache_line_read ON public.bloom_order_cache_line;
CREATE POLICY bloom_order_cache_read      ON public.bloom_order_cache      FOR SELECT USING (true);
CREATE POLICY bloom_order_cache_line_read ON public.bloom_order_cache_line FOR SELECT USING (true);
GRANT SELECT ON public.bloom_order_cache, public.bloom_order_cache_line TO anon, authenticated;

-- ---------- the WRITER (off the request thread; arms its own long timer) ----------
CREATE OR REPLACE FUNCTION public.refresh_bloom_order_cache(
  p_store_code    text,
  p_route         text,
  p_delivery_date date    DEFAULT NULL,
  p_next_delivery date    DEFAULT NULL,
  p_preset        text    DEFAULT NULL,
  p_fit_to_budget boolean DEFAULT false,
  p_source        text    DEFAULT 'nightly')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_del date; v_next date; v_cache_id bigint;
  v_t0 timestamptz; v_ms int; v_n int; v_md5 text; v_gen timestamptz;
BEGIN
  SET LOCAL statement_timeout = '300s';

  -- The desk almost always opens the NEXT SCHEDULED delivery, which the calendar
  -- already knows (ORDERING-CANON SSA4). Resolve it rather than making a caller guess.
  IF p_delivery_date IS NULL OR p_next_delivery IS NULL THEN
    SELECT nd.delivery_date, nd.following_date INTO v_del, v_next
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route) nd LIMIT 1;
  END IF;
  v_del  := COALESCE(p_delivery_date, v_del);
  v_next := COALESCE(p_next_delivery, v_next);

  IF v_del IS NULL OR v_next IS NULL THEN
    RETURN jsonb_build_object('status','no_calendar_dates','store',p_store_code,'route',p_route);
  END IF;

  SELECT md5(pg_get_functiondef(p.oid)) INTO v_md5
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_bloom_order_recipe';

  DELETE FROM public.bloom_order_cache
   WHERE store_code=p_store_code AND route_key=p_route
     AND delivery_date=v_del AND next_delivery=v_next
     AND preset=COALESCE(p_preset,'standard') AND fit_to_budget=p_fit_to_budget;

  v_gen := clock_timestamp();
  INSERT INTO public.bloom_order_cache
    (store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget,
     engine_md5, source, generated_at)
  VALUES (p_store_code, p_route, v_del, v_next, COALESCE(p_preset,'standard'), p_fit_to_budget,
          v_md5, p_source, v_gen)
  RETURNING cache_id INTO v_cache_id;

  v_t0 := clock_timestamp();
  INSERT INTO public.bloom_order_cache_line
  SELECT v_cache_id,
         row_number() OVER (ORDER BY r.rhythm_adjusted_demand DESC NULLS LAST, r.product_code),
         r.*, v_gen
  FROM public.rpc_bloom_order_recipe(
         p_store_code, v_del, v_next, NULL, p_preset, NULL, p_fit_to_budget,
         NULL, NULL, NULL, NULL, p_route) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;

  UPDATE public.bloom_order_cache SET line_count=v_n, generation_ms=v_ms WHERE cache_id=v_cache_id;

  RETURN jsonb_build_object('status','ok','cache_id',v_cache_id,'lines',v_n,
                            'generation_ms',v_ms,'delivery',v_del,'next_delivery',v_next,
                            'engine_md5',v_md5);
END $fn$;

REVOKE EXECUTE ON FUNCTION public.refresh_bloom_order_cache(text,text,date,date,text,boolean,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_bloom_order_cache(text,text,date,date,text,boolean,text) TO authenticated, service_role;

-- ---------- the READER (what the screen calls) ----------
-- RETURNS jsonb, ONE row, deliberately. MEASURED 2026-08-16: PostgREST answered
-- the SETOF form with "206 Partial Content, Content-Range: 0-999/1065" -- a
-- 1000-row cap IS live on this project, correcting the prior reading that none
-- exists. A SETOF read would have silently dropped 65 lines off a 1,065-line
-- order. Same pattern rpc_report_rows already uses here: a max-rows cap cannot
-- truncate a single row. `served` vs `line_count` is the R22 tripwire.
CREATE OR REPLACE FUNCTION public.rpc_bloom_order_cached(
  p_store_code    text,
  p_route         text,
  p_delivery_date date    DEFAULT NULL,
  p_next_delivery date    DEFAULT NULL,
  p_preset        text    DEFAULT NULL,
  p_fit_to_budget boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH want AS (
    SELECT COALESCE(p_delivery_date, (SELECT nd.delivery_date  FROM public.rpc_bloom_next_deliveries(p_store_code,p_route) nd LIMIT 1)) AS del,
           COALESCE(p_next_delivery, (SELECT nd.following_date FROM public.rpc_bloom_next_deliveries(p_store_code,p_route) nd LIMIT 1)) AS nxt
  ), hdr AS (
    SELECT c.cache_id, c.generated_at, c.line_count, c.delivery_date, c.next_delivery
    FROM public.bloom_order_cache c, want w
    WHERE c.store_code=p_store_code AND c.route_key=p_route
      AND c.delivery_date=w.del AND c.next_delivery=w.nxt
      AND c.preset=COALESCE(p_preset,'standard') AND c.fit_to_budget=p_fit_to_budget
    ORDER BY c.generated_at DESC LIMIT 1
  )
  SELECT jsonb_build_object(
    'found',        (SELECT count(*) FROM hdr) > 0,
    'generated_at', (SELECT generated_at FROM hdr),
    'delivery_date',(SELECT delivery_date FROM hdr),
    'next_delivery',(SELECT next_delivery FROM hdr),
    'line_count',   (SELECT line_count FROM hdr),
    'served',       (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id),
    'lines',        COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
                              FROM public.bloom_order_cache_line l
                              JOIN hdr ON hdr.cache_id=l.cache_id), '[]'::jsonb)
  );
$fn$;

REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_cached(text,text,date,date,text,boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_order_cached(text,text,date,date,text,boolean) TO anon, authenticated;

-- ---------- freshness surface (never a silent stale read) ----------
CREATE OR REPLACE FUNCTION public.rpc_bloom_order_cache_status(
  p_store_code text DEFAULT NULL, p_route text DEFAULT NULL)
RETURNS TABLE(store_code text, route_key text, delivery_date date, next_delivery date,
              preset text, fit_to_budget boolean, generated_at timestamptz,
              age_minutes numeric, line_count int, generation_ms int, engine_current boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT c.store_code, c.route_key, c.delivery_date, c.next_delivery, c.preset, c.fit_to_budget,
         c.generated_at,
         round(extract(epoch from (clock_timestamp()-c.generated_at))/60.0, 1),
         c.line_count, c.generation_ms,
         (c.engine_md5 = (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p
                          JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='rpc_bloom_order_recipe'))
  FROM public.bloom_order_cache c
  WHERE (p_store_code IS NULL OR c.store_code=p_store_code)
    AND (p_route IS NULL OR c.route_key=p_route)
  ORDER BY c.generated_at DESC;
$fn$;

REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_cache_status(text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_order_cache_status(text,text) TO anon, authenticated;

-- ---------- nightly builder ----------
-- Scoped to the DC desks: they are the heavy ones that breach the ceiling.
-- Direct desks answer inside the ceiling live, so they are deliberately NOT
-- precomputed (named, not silently omitted -- R21 SS5).
CREATE OR REPLACE FUNCTION public.refresh_bloom_order_cache_all(p_routes text[] DEFAULT ARRAY['DC_AMBIENT','DC_TOPS'])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  rec record; r jsonb; v_ok int := 0; v_skip int := 0; v_err int := 0; v_detail jsonb := '[]'::jsonb;
BEGIN
  SET LOCAL statement_timeout = '0';
  FOR rec IN
    SELECT sc.store_code, sc.route_key, f.fit
    FROM public.supplier_calendar sc
    CROSS JOIN (VALUES (false),(true)) AS f(fit)
    WHERE sc.route_key = ANY(p_routes)
    ORDER BY sc.store_code, sc.route_key, f.fit
  LOOP
    BEGIN
      r := public.refresh_bloom_order_cache(rec.store_code, rec.route_key, NULL, NULL, NULL, rec.fit, 'nightly');
      IF r->>'status' = 'ok' THEN v_ok := v_ok + 1; ELSE v_skip := v_skip + 1; END IF;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'store',rec.store_code,'route',rec.route_key,'fit',rec.fit,
        'status',r->>'status','lines',r->>'lines','ms',r->>'generation_ms'));
    EXCEPTION WHEN OTHERS THEN
      -- one bad desk never silently kills the rest, and the failure is reported (R22 SS3)
      v_err := v_err + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'store',rec.store_code,'route',rec.route_key,'fit',rec.fit,'status','error','error',SQLERRM));
    END;
  END LOOP;
  RETURN jsonb_build_object('ok',v_ok,'skipped',v_skip,'errors',v_err,
                            'ran_at',clock_timestamp(),'detail',v_detail);
END $fn$;

REVOKE EXECUTE ON FUNCTION public.refresh_bloom_order_cache_all(text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_bloom_order_cache_all(text[]) TO authenticated, service_role;

-- 23:30 UTC = 01:30 SAST: after refresh-l2-pipeline (20:15 UTC job 15),
-- refresh-search-index (20:30), nightly-ros-refresh (22:30 job 8) and
-- refresh-sparkline-14d (23:00 job 10), so the cache is built on the night's
-- FINISHED pantry, never mid-chain.
-- SELECT cron.schedule('bloom-order-cache-refresh', '30 23 * * *',
--                      $$SELECT public.refresh_bloom_order_cache_all();$$);
