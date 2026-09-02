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
CREATE OR REPLACE FUNCTION public.refresh_bloom_order_cache(p_store_code text, p_route text, p_delivery_date date DEFAULT NULL::date, p_next_delivery date DEFAULT NULL::date, p_preset text DEFAULT NULL::text, p_fit_to_budget boolean DEFAULT false, p_source text DEFAULT 'nightly'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_del date; v_next date; v_cache_id bigint;
  v_t0 timestamptz; v_ms int; v_n int; v_md5 text; v_gen timestamptz;
  v_flagged int; v_appended int; v_max_line int;
  v_bm_anchor date; v_bm_weekly numeric;
BEGIN
  SET LOCAL statement_timeout = '300s';

  IF p_delivery_date IS NULL OR p_next_delivery IS NULL THEN
    SELECT nd.delivery_date, nd.following_date INTO v_del, v_next
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, public.store_local_today(p_store_code)) nd LIMIT 1;  -- ENG-117: explicit store-local anchor, never inherited from the session
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

  -- STEP 1, UNCHANGED. The recipe's own rows, positionally. Not one byte of the
  -- recipe is touched and no quantity moves anywhere below this line.
  v_t0 := clock_timestamp();
  INSERT INTO public.bloom_order_cache_line
  SELECT v_cache_id,
         row_number() OVER (ORDER BY r.rhythm_adjusted_demand DESC NULLS LAST, r.product_code),
         r.*, v_gen
  FROM public.rpc_bloom_order_recipe(
         p_store_code, v_del, v_next, NULL, p_preset, NULL, p_fit_to_budget,
         NULL, NULL, NULL, NULL, p_route) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- STEP 2, SB-CC-BLOOM-026 5(b2). A hidden line ALREADY ON THE SHEET is flagged
  -- IN PLACE, never appended a second time. Measured before building: 19 of the
  -- 396 hidden lines at 80175 DC_AMBIENT are already cache rows, so a naive
  -- append would show the buyer the same product twice.
  UPDATE public.bloom_order_cache_line l
     SET withheld_correction     = true,
         hidden_reason           = v.state_reason,
         hidden_rate_engine_read = v.rate_raw_56d,
         hidden_rate_corrected   = v.rate_corrected_56d,
         hidden_rate_guard       = v.rate_guard_56d,
         hidden_window_days      = 56,
         hidden_days_removed     = v.days_removed_56d,
         hidden_observable_days  = v.observable_days,
         hidden_observable_share = v.observable_share
    FROM public.l2_population_verdict v
   WHERE l.cache_id = v_cache_id
     AND v.store_code = p_store_code AND v.route_key = p_route
     AND v.flag_hidden_seller
     AND v.product_code = l.product_code;
  GET DIAGNOSTICS v_flagged = ROW_COUNT;

  -- STEP 3. The rest become NEW rows at ZERO quantity, pinned above by line_kind.
  -- rhythm_adjusted_demand carries the rate the ORDER READ so the sheet's own
  -- sort stays apples-to-apples; what the corrector measured rides its own
  -- column beside it, which is the whole point of the row (R28 SS5 on the surface).
  SELECT COALESCE(MAX(line_no),0) INTO v_max_line
    FROM public.bloom_order_cache_line WHERE cache_id = v_cache_id;

  INSERT INTO public.bloom_order_cache_line
    (cache_id, line_no, store_code, product_code, ean, description, dept_name, route,
     kvi_band, tier, range_state, rhythm_adjusted_demand, soh, pack_size, pack_cost,
     need_units, normal_packs, geared_packs, suggested_packs, value,
     promo_active, promo_nr, promo_start, promo_end, promo_suffix, promo_naming_gap, count_first, story, generated_at,
     line_kind, withheld_correction, hidden_reason, hidden_rate_engine_read, hidden_rate_corrected,
     hidden_rate_guard, hidden_window_days, hidden_days_removed,
     hidden_observable_days, hidden_observable_share)
  SELECT v_cache_id,
         v_max_line + row_number() OVER (ORDER BY v.rate_corrected_56d DESC NULLS LAST, v.product_code),
         v.store_code, v.product_code, b.ean::text, v.description, v.dept_name, p_route,
         v.kvi_band, v.tier, v.range_state, v.rate_raw_56d, v.soh,
         v.chosen_pack_size, v.chosen_pack_cost,
         0, 0, 0, 0, 0,
         (pm.promo_nr IS NOT NULL), pm.promo_nr, pm.start_date, pm.end_date, pm.promo_suffix, (pm.promo_nr IS NOT NULL AND pm.promo_suffix IS NULL), false, v.state_reason, v_gen,
         'hidden', true, v.state_reason, v.rate_raw_56d, v.rate_corrected_56d,
         v.rate_guard_56d, 56, v.days_removed_56d,
         v.observable_days, v.observable_share
  FROM public.l2_population_verdict v
  LEFT JOIN public.rpc_bloom_promo_for_delivery(p_store_code, p_route, v_del) pm ON pm.product_code = v.product_code LEFT JOIN public.v_ean_bridge b
         ON b.store_code = v.store_code AND b.product_code = v.product_code
  WHERE v.store_code = p_store_code AND v.route_key = p_route
    AND v.flag_hidden_seller
    AND NOT EXISTS (SELECT 1 FROM public.bloom_order_cache_line x
                     WHERE x.cache_id = v_cache_id AND x.product_code = v.product_code);
  GET DIAGNOSTICS v_appended = ROW_COUNT;

  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;

  -- ENG-106 leg (b) / SSD6.1 clause 2: freeze the benchmark AND its anchor onto
  -- the artefact. The ONE HOME computes it; this never re-derives the basis.
  SELECT b.anchor_date, b.weekly_cost_demand INTO v_bm_anchor, v_bm_weekly
  FROM public.rpc_bloom_route_benchmark(p_store_code, p_route, NULL) b;

  UPDATE public.bloom_order_cache_line
     SET line_kind = 'covered'
   WHERE cache_id = v_cache_id
     AND line_kind = 'ordered'
     AND coalesce(suggested_packs, 0) = 0
     AND range_state IN ('CORE', 'HERO')
     AND soh <= min_band
     -- A line kept for its OWN reason keeps that identity. Tagging a
     -- count-first or minimum-presence line 'covered' would let the label say
     -- "no action" about a line that needs one (ENG-123: a display value must
     -- name its own population).
     AND NOT (coalesce(count_first,false) OR coalesce(keep_or_delist,false)
              OR coalesce(pack_forced_review,false) OR coalesce(min_presence_forced,false))
     -- ENG-102 correction: a withheld-correction line is a HIDDEN SELLER and keeps
     -- that identity. Before ENG-102 it was appended as line_kind='hidden' and the
     -- buyer saw it flagged DROPPED. The covered tag must never claim it.
     AND NOT coalesce(withheld_correction, false);

  UPDATE public.bloom_order_cache
     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)
                                       FROM public.bloom_order_cache_line
                                      WHERE cache_id = v_cache_id
                                        AND line_kind = 'covered'),
         hidden_line_count  = v_flagged + v_appended,
         generation_ms      = v_ms,
         benchmark_anchor_date   = v_bm_anchor,
         benchmark_weekly_demand = v_bm_weekly
   WHERE cache_id=v_cache_id;

  RETURN jsonb_build_object('status','ok','cache_id',v_cache_id,
                            'lines',v_n + v_appended,
                            'ordered_lines',v_n,
                            'hidden_flagged_in_place',v_flagged,
                            'hidden_appended',v_appended,
                            'generation_ms',v_ms,'delivery',v_del,'next_delivery',v_next,
                            'engine_md5',v_md5);
END $function$;

REVOKE EXECUTE ON FUNCTION public.refresh_bloom_order_cache(text,text,date,date,text,boolean,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_bloom_order_cache(text,text,date,date,text,boolean,text) TO authenticated, service_role;
-- ---------- the READER (what the screen calls) ----------
-- RETURNS jsonb, ONE row, deliberately. MEASURED 2026-08-16: PostgREST answered
-- the SETOF form with "206 Partial Content, Content-Range: 0-999/1065" -- a
-- 1000-row cap IS live on this project, correcting the prior reading that none
-- exists. A SETOF read would have silently dropped 65 lines off a 1,065-line
-- order. Same pattern rpc_report_rows already uses here: a max-rows cap cannot
-- truncate a single row. `served` vs `line_count` is the R22 tripwire.
--
-- 🔴 ENG-097 (2026-08-23): A CACHE MISS MUST NEVER FALL THROUGH TO THE RECIPE.
-- This function matches EXACTLY on delivery_date AND next_delivery. Any other
-- pairing returned {found:false} with every field NULL, and the desk then
-- called rpc_bloom_order_recipe live -- which dies at the anon role's 30s
-- ceiling (~36s, HTTP 500). The buyer waited thirty seconds for "R 0 / 0 lines"
-- while a complete order sat in the cache one date-pairing away. That is what
-- Pieter was shown.
-- The miss is now SELF-DESCRIBING: `status` HIT|MISS, `requested` (what was
-- looked for, after date defaulting), `available` (what IS cached on this desk)
-- and a plain-language `message`. `found` is retained unchanged so no existing
-- caller can break. The frontend renders MISS and FAILURE differently -- a
-- pairing that was never precomputed is a different fact from a broken read,
-- and conflating them is what let a timeout read as an empty order.
CREATE OR REPLACE FUNCTION public.rpc_bloom_order_cached(p_store_code text, p_route text, p_delivery_date date DEFAULT NULL::date, p_next_delivery date DEFAULT NULL::date, p_preset text DEFAULT NULL::text, p_fit_to_budget boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  ), avail AS (
    -- what IS cached on this desk, so a miss can name the alternatives rather
    -- than leaving the buyer to guess (R21 SS5, the exclusion carries its reason)
    SELECT c.delivery_date, c.next_delivery, c.preset, c.fit_to_budget,
           c.line_count, c.generated_at
    FROM public.bloom_order_cache c
    WHERE c.store_code=p_store_code AND c.route_key=p_route
      AND c.delivery_date >= CURRENT_DATE - 1
    ORDER BY c.delivery_date, c.preset, c.fit_to_budget
    LIMIT 12
  )
  SELECT jsonb_build_object(
    'found',        (SELECT count(*) FROM hdr) > 0,
    'status',       CASE WHEN (SELECT count(*) FROM hdr) > 0 THEN 'HIT' ELSE 'MISS' END,
    'generated_at', (SELECT generated_at FROM hdr),
    'delivery_date',(SELECT delivery_date FROM hdr),
    'next_delivery',(SELECT next_delivery FROM hdr),
    -- ENG-102: the covered rows are withheld from this payload until a surface
    -- can render them, so the count names the population actually served.
    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),
    'covered_withheld', (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                          WHERE l.line_kind = 'covered'),
    -- R22: the array length is reported beside the header's own count, so a
    -- mismatch between what was cached and what was served is visible, not silent.
    'served',       (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                     WHERE l.line_kind IS DISTINCT FROM 'covered'),
    'lines',        COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
                              FROM public.bloom_order_cache_line l
                              JOIN hdr ON hdr.cache_id=l.cache_id
                             WHERE l.line_kind IS DISTINCT FROM 'covered'), '[]'::jsonb),
    -- ENG-097 miss payload
    'requested',    (SELECT jsonb_build_object(
                       'store_code', p_store_code, 'route', p_route,
                       'delivery_date', w.del, 'next_delivery', w.nxt,
                       'preset', COALESCE(p_preset,'standard'),
                       'fit_to_budget', p_fit_to_budget) FROM want w),
    'available',    COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM avail a), '[]'::jsonb),
    'message',      CASE WHEN (SELECT count(*) FROM hdr) > 0 THEN NULL
                    ELSE (SELECT format(
                      'No cached order for %s on %s %s for delivery %s to %s. %s',
                      COALESCE(p_preset,'standard'), p_store_code, p_route,
                      w.del::text, w.nxt::text,
                      COALESCE(
                        (SELECT 'Cached on this desk: '||string_agg(DISTINCT a.delivery_date::text||' to '||a.next_delivery::text, ', ')||'.'
                           FROM avail a),
                        'Nothing is cached on this desk yet. The nightly rebuild runs 01:30 SAST.'))
                      FROM want w) END
  );
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_cached(text,text,date,date,text,boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_order_cached(text,text,date,date,text,boolean) TO anon, authenticated;

-- ---------- freshness surface (never a silent stale read) ----------
CREATE OR REPLACE FUNCTION public.rpc_bloom_order_cache_status(p_store_code text DEFAULT NULL::text, p_route text DEFAULT NULL::text)
 RETURNS TABLE(store_code text, route_key text, delivery_date date, next_delivery date, preset text, fit_to_budget boolean, generated_at timestamp with time zone, age_minutes numeric, line_count integer, generation_ms integer, engine_current boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_cache_status(text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_order_cache_status(text,text) TO anon, authenticated;

-- ---------- nightly builder ----------
-- ~~Scoped to the DC desks: they are the heavy ones that breach the ceiling.
-- Direct desks answer inside the ceiling live, so they are deliberately NOT
-- precomputed (named, not silently omitted -- R21 SS5).~~
-- RETIRED 2026-08-19 (R28: retire with a date and a successor, never delete).
-- THE CLAIM WAS FALSE. Direct desks do NOT answer inside the ceiling -- they run
-- the same recipe and hit the same 30s role statement_timeout, and the five
-- /bloom cards that execute the recipe die on them exactly as they did on the DC
-- desks before ENG-088. The route literal above was the only thing deciding who
-- got a precomputed order, so 15 of 20 desks never had one.
--
-- SUCCESSOR: p_routes NULL = EVERY desk rpc_bloom_desks() discovers from config
-- (supplier_calendar x stores.is_active). No route, store or desk is enumerated
-- here. A desk seeded tonight is cached tonight with no deploy -- the store-#6
-- test (R25 SS4 / R32 SS4). p_routes survives as an optional NARROWING filter
-- for a manual run, never as the source of the list.
--
-- MEASURED, not assumed (2026-08-19): the DC-only run was 10 combinations /
-- 212,334ms = 3.54 min. All 20 desks x 2 fit = 40 combinations, and a direct
-- desk measures ~7.5s (80176/DIRECT_BEER, 24 lines, 7,481ms), so the generalised
-- nightly is ~7.3 min. p_presets/p_drops are parameterised for the
-- scenario-overview matrix but DEFAULT TO TODAY'S BEHAVIOUR: that matrix
-- measures ~43 min across 240 combinations and is a decision, not a free
-- widening.
--
-- OVERLOAD TRAP, recorded because it nearly fired: adding p_presets/p_drops
-- changed the signature, so CREATE OR REPLACE left the old 1-arg function
-- standing. Both were fully defaulted, making pg_cron job 26's no-argument call
-- ambiguous ("function is not unique") -- it would have killed the whole nightly
-- build. The 1-arg version is dropped; run the RULE-BOOK SS8 overload check
-- BEFORE any signature change, not after.
CREATE OR REPLACE FUNCTION public.refresh_bloom_order_cache_all(p_routes text[] DEFAULT NULL::text[], p_presets text[] DEFAULT ARRAY['standard'::text], p_drops integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  rec record;
  r jsonb;
  v_ok int := 0; v_skip int := 0; v_err int := 0;
  v_detail jsonb := '[]'::jsonb;
  v_started timestamptz := clock_timestamp();
  v_routes_seen int := 0;
BEGIN
  SET LOCAL statement_timeout = '0';   -- a background builder is not on a request thread

  FOR rec IN
    -- The desk set comes from rpc_bloom_desks (supplier_calendar x active
    -- stores), never a literal. p_routes is an optional NARROWING filter for a
    -- manual run, never the source of the list.
    SELECT d.store_code, d.route_key, f.fit,
           NULLIF(pr.preset, 'standard') AS preset_arg,
           pr.preset                     AS preset_label,
           dr.n                          AS drop_n
      FROM public.rpc_bloom_desks()                       d
      CROSS JOIN (VALUES (false),(true))                  AS f(fit)
      CROSS JOIN unnest(COALESCE(p_presets, ARRAY['standard'])) AS pr(preset)
      CROSS JOIN generate_series(1, GREATEST(p_drops, 1))  AS dr(n)
     WHERE p_routes IS NULL OR d.route_key = ANY(p_routes)
     ORDER BY d.store_code, COALESCE(d.desk_sort, 32767), d.route_key,
              dr.n, pr.preset, f.fit
  LOOP
    v_routes_seen := v_routes_seen + 1;
    BEGIN
      -- drop_n = 1 keeps today's behaviour byte-for-byte: NULL dates let
      -- refresh_bloom_order_cache resolve the next scheduled delivery from
      -- supplier_calendar via rpc_bloom_next_deliveries (ORDERING-CANON §A4).
      -- Later drops are leg 2 and are not requested while p_drops = 1.
      r := public.refresh_bloom_order_cache(
             rec.store_code, rec.route_key, NULL, NULL, rec.preset_arg, rec.fit, 'nightly');

      IF r->>'status' = 'ok' THEN v_ok := v_ok + 1; ELSE v_skip := v_skip + 1; END IF;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'store',rec.store_code,'route',rec.route_key,'preset',rec.preset_label,
        'fit',rec.fit,'drop',rec.drop_n,
        'status',r->>'status','lines',r->>'lines','ms',r->>'generation_ms'));
    EXCEPTION WHEN OTHERS THEN
      -- one bad desk never silently kills the rest, and the failure is reported (R22 §3)
      v_err := v_err + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'store',rec.store_code,'route',rec.route_key,'preset',rec.preset_label,
        'fit',rec.fit,'drop',rec.drop_n,'status','error','error',SQLERRM));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',v_ok,'skipped',v_skip,'errors',v_err,
    'combinations_attempted',v_routes_seen,
    'elapsed_ms',round(extract(epoch from (clock_timestamp()-v_started))*1000)::int,
    'ran_at',clock_timestamp(),'detail',v_detail);
END $function$;

-- The superseded 1-arg signature (see the OVERLOAD TRAP note above).
DROP FUNCTION IF EXISTS public.refresh_bloom_order_cache_all(text[]);

REVOKE EXECUTE ON FUNCTION public.refresh_bloom_order_cache_all(text[],text[],int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_bloom_order_cache_all(text[],text[],int) TO authenticated, service_role;

-- 23:30 UTC = 01:30 SAST: after refresh-l2-pipeline (20:15 UTC job 15),
-- refresh-search-index (20:30), nightly-ros-refresh (22:30 job 8) and
-- refresh-sparkline-14d (23:00 job 10), so the cache is built on the night's
-- FINISHED pantry, never mid-chain.
-- SELECT cron.schedule('bloom-order-cache-refresh', '30 23 * * *',
--                      $$SELECT public.refresh_bloom_order_cache_all();$$);
