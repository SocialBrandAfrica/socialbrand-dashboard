-- ============================================================================
-- ENG-093 -- the live recipe read is served through a 1,000-row cap with no
--            pagination, so a desk over 1,000 lines has been serving a SHORT
--            ORDER with nothing on screen saying so.
--
-- Ref:      BUG-LOG ENG-093 (PARTIAL -> this closes the ENG-085 path)
-- Author:   CC (Claude Code)
-- Date:     2026-09-01 SAST
-- Applies:  one NEW function. Nothing existing is altered. rpc_bloom_order_recipe
--           is NOT touched -- pin 6204ae7bf6b12f1a17e8bcb3d72028ea / 44,251.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT, and the code states the refuted claim as its own justification
-- ---------------------------------------------------------------------------
-- src/app/bloom/page.jsx:1099 (RecipeMode) calls rpc_bloom_order_recipe through
-- supabase.rpc() with no .range() and no guard. The comment directly above it
-- reads, verbatim:
--
--     "no pgrst.db_max_rows cap is set, so every row returns in a single response"
--
-- That claim was refuted at source on 2026-08-16: PostgREST answered the SETOF
-- form with HTTP 206 Partial Content, Content-Range: 0-999/1065. A 1,000-row cap
-- IS live on this project. The absence of a db_max_rows SETTING is not the
-- absence of a CAP -- the original checks looked in the right places for the
-- wrong thing, and a cap is proven by CALLING it, never by grepping for it.
--
-- REACHABILITY CONFIRMED, not assumed: RecipeMode renders at page.jsx:3239 under
-- appMode === 'recipe' and wires onGenerate={generate} at 1175. This is a live
-- path, not dead code.
--
-- ---------------------------------------------------------------------------
-- THE EXPOSURE -- CORRECTED 2026-09-01 ON PM'S CATCH. MY FIRST FIGURE USED THE
-- WRONG POPULATION AND OVERSTATED IT.
-- ---------------------------------------------------------------------------
-- RETIRED (R28, retired_on 2026-09-01, superseded_by this block): "that desk now
-- returns 2,071 lines, so a truncated read drops 1,071." That used
-- bloom_order_cache.line_count, which is the CACHE total -- recipe rows PLUS the
-- 5(b2) hidden rows the cache appends AFTER the recipe returns. The recipe never
-- returns those, so they cannot be truncated. Counting them was a population
-- error in the headline of a sweep whose whole point is stating populations.
--
-- THE RIGHT COLUMN IS ordered_line_count -- the recipe's own output. Measured
-- across the build history of 10116 DC_AMBIENT, the desk that proved the cap:
--
--   built 2026-08-20  delivery 08-22   1,848 rows   -> 848 DROPPED
--                     (pre-5(b2); line_count IS the recipe count on that build)
--   built 2026-08-25  delivery 08-27     723 rows   -> under
--   built 2026-08-27  delivery 08-29   1,563 rows   -> 563 DROPPED
--   built 2026-08-31  delivery 09-03     799 rows   -> under
--
-- SO THE DEFECT IS INTERMITTENT, NOT CONSTANT, AND THAT IS WORSE FOR A WALK
-- THAN A PERMANENT BREAK: the screen is correct on most days and silently short
-- on the heavy ones, so checking it on a light day proves nothing. The buyer
-- cannot tell the two apart, because a truncated read renders as a complete
-- order.
--
-- ENG-093's own recorded figure (1,065 lines, 65 dropped) was true on
-- 2026-08-16 and is neither wrong nor the current worst. The worst MEASURED is
-- 848 lines on the 08-20 build.
--
-- ---------------------------------------------------------------------------
-- THE SWEEP RESULT (R30 addendum 3 -- a population with its denominator)
-- ---------------------------------------------------------------------------
-- Denominator: 74 set-returning rpc_* functions executable by anon or
-- authenticated; 64 call sites across 17 files, found with all THREE patterns
-- (supabase .rpc(, a local helper building a REST path, and a raw rest/v1/rpc/
-- URL) -- a .rpc( grep alone misses all nine readers in public/toolkit.html.
--
--   OVER THE CAP AND UNPAGINATED ......... 1 site, this one. Intermittently:
--                                          1,848 rows on the 08-20 build, 1,563
--                                          on 08-29, 799 today. Recipe rows
--                                          (ordered_line_count), NOT the cache
--                                          total -- see the corrected block above.
--   STRUCTURALLY SAFE ALREADY (jsonb) .... 3 sites: rpc_bloom_order_cached,
--                                          rpc_stock_report_engine_json,
--                                          rpc_report_rows.
--   PAGINATED ............................ 1 site: rpc_bloom_order_dc (.range()).
--   EXPOSED BY SHAPE, UNDER THE CAP TODAY (measured 2026-09-01, watch list, not
--   a defect claim): rpc_stock_report_engine slowmovers 4,354 -- but NO live
--   caller in this repo reads the SETOF form, only the _json wrapper; negsoh 798;
--   rpc_forge_count_list 610; rpc_forge_lines 608; rpc_ghost_stock_report 518;
--   rpc_stock_integrity_report 363; rpc_cost_error_worklist 46.
--   public/toolkit.html's helper has NO pagination and NO guard -- all nine of
--   its readers are under the cap today and would truncate in silence if any grew.
--
--   NAMED GAP: surfaces outside this repo -- Bloom standalone on Replit, Atlas,
--   Pulse Mini, StockFlow's feeds -- have never been mapped (ESTATE-MAPS map 2).
--   This sweep speaks for socialbrand-dashboard and says nothing about them.
-- ============================================================================

DO $do$
BEGIN
  -- PRE-FLIGHT: never create over an existing overload (the Function Change
  -- Protocol; a changed signature leaving an old one behind is what nearly
  -- killed the nightly build once already).
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe_json') THEN
    RAISE EXCEPTION 'ENG-093 PRE-FLIGHT FAIL: rpc_bloom_order_recipe_json already exists -- inspect before replacing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe') THEN
    RAISE EXCEPTION 'ENG-093 PRE-FLIGHT FAIL: rpc_bloom_order_recipe not found';
  END IF;
END
$do$;

CREATE FUNCTION public.rpc_bloom_order_recipe_json(
  p_store_code                text,
  p_delivery_date             date,
  p_next_delivery             date    DEFAULT NULL,
  p_soh_date                  date    DEFAULT NULL,
  p_preset                    text    DEFAULT NULL,
  -- numeric, NOT integer: verified against pg_get_function_arguments on the live
  -- recipe before writing. DB-SCHEMA's parameter list reads integer here, and
  -- declaring integer would silently truncate a fractional override at the
  -- wrapper boundary -- a defect invisible to every test that passes a whole
  -- number. The catalog settles the type; the document does not.
  p_days_cover_override       numeric DEFAULT NULL,
  p_fit_to_budget             boolean DEFAULT false,
  p_route                     text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_lines jsonb;
  v_n     int;
BEGIN
  -- ONE jsonb row carrying the whole array. A row cap cannot truncate a single
  -- row, so this is STRUCTURAL rather than a bigger page size -- the same
  -- pattern rpc_report_rows and rpc_bloom_order_cached already use here.
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.value DESC NULLS LAST), '[]'::jsonb),
         count(*)
    INTO v_lines, v_n
  FROM public.rpc_bloom_order_recipe(
         p_store_code, p_delivery_date, p_next_delivery, p_soh_date,
         p_preset, p_days_cover_override, p_fit_to_budget,
         p_route := p_route) r;

  RETURN jsonb_build_object(
    'status',        'OK',
    'lines',         v_lines,
    'line_count',    v_n,
    'served',        jsonb_array_length(v_lines),
    'computed_at',   now(),
    'requested',     jsonb_build_object(
                       'store_code', p_store_code, 'route', p_route,
                       'delivery_date', p_delivery_date, 'next_delivery', p_next_delivery,
                       'preset', p_preset, 'fit_to_budget', p_fit_to_budget,
                       'days_cover_override', p_days_cover_override)
  );
END
$function$;

-- Read RPC: anon stays executable by design (SQL-CONVENTIONS / R30 addendum --
-- the mutating-function rule does not apply to reads). PUBLIC is revoked
-- explicitly anyway, because Postgres grants EXECUTE to PUBLIC on creation and
-- anon inherits it -- the trap that has fired three times on this project.
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_order_recipe_json(text,date,date,date,text,numeric,boolean,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_order_recipe_json(text,date,date,date,text,numeric,boolean,text) TO anon, authenticated;

COMMENT ON FUNCTION public.rpc_bloom_order_recipe_json(text,date,date,date,text,numeric,boolean,text) IS
'GRADE: RECOMMENDED. ENG-093. Truncation-proof reader over rpc_bloom_order_recipe: returns ONE jsonb row carrying the whole line array, because a live 1,000-row PostgREST cap silently truncated the SETOF read (206 Partial Content, Content-Range 0-999/1065, measured 2026-08-16). Computes nothing -- the recipe is the sole authority and is not touched.';

-- ============================================================================
-- ONE HONEST LIMIT, STATED RATHER THAN PAPERED OVER
-- ============================================================================
-- rpc_bloom_order_cached carries `served` vs `line_count` as a REAL tripwire,
-- because line_count comes from the cache HEADER and served from the array --
-- two independent sources that can disagree.
--
-- On THIS function they cannot. Both derive from one materialisation of one
-- call, so `served = line_count` always, by construction. That is a gate that
-- cannot fail, which this estate has ruled is not proof (R28 5, ENG-020 leg 2,
-- ENG-041). Both keys are returned for consumer symmetry with the cached
-- reader, and they are NOT an independent check on this path. The protection
-- here is structural -- one row cannot be capped -- and it does not need a
-- tripwire to be true. Do not let a future reader treat their agreement as
-- evidence of completeness.
--
-- ============================================================================
-- R22 -- expected values stated so the gate can fail. Measured 2026-09-01.
-- ============================================================================
-- 1. NO QUANTITY MOVES. The wrapper computes nothing. Same desk, both paths:
--
--    SELECT count(*) AS setof_rows,
--           round(sum(suggested_packs*pack_cost)::numeric,2) AS setof_value
--    FROM rpc_bloom_order_recipe('80175', date '2026-09-05', date '2026-09-09',
--                                p_route => 'DC_AMBIENT');
--
--    SELECT (p->>'line_count')::int AS json_rows,
--           round(sum((l->>'suggested_packs')::numeric * (l->>'pack_cost')::numeric),2) AS json_value
--    FROM (SELECT rpc_bloom_order_recipe_json('80175', date '2026-09-05',
--                   date '2026-09-09', p_route => 'DC_AMBIENT') AS p) s,
--         jsonb_array_elements(s.p->'lines') l
--    GROUP BY 1;
--
--    EXPECT: identical row count and identical value to the cent, both ways.
--
-- 2. THE CAP IS BEATEN -- BUT ONLY A BUILD OVER THE CAP CAN PROVE IT, AND
--    TODAY'S IS NOT (corrected 2026-09-01, PM's catch; the first wording of this
--    check compared against line_count and could not have failed honestly).
--    The recipe's own row count is ordered_line_count, not line_count. 10116
--    DC_AMBIENT reads 799 today and read 1,563 on the 08-29 build, so the desk
--    crosses the cap intermittently.
--    THE CHECK: run it on a build whose ordered_line_count EXCEEDS 1,000 and
--    confirm line_count = served = the full figure, never 1,000. Running it on a
--    sub-1,000 build proves the function works and proves NOTHING about the cap.
--    Find a qualifying desk first:
--      SELECT store_code, route_key, delivery_date, ordered_line_count
--      FROM bloom_order_cache WHERE ordered_line_count > 1000
--      ORDER BY generated_at DESC;
--    If none is current, the honest report is "not reproducible today", never a
--    pass. THE FRONTEND REPOINT AND PIETER'S R31 WALK BOTH WAIT FOR THIS -- a
--    walk on a light day would show a correct screen and settle nothing.
--
-- 3. GRANTS. EXPECT no PUBLIC entry in the acl, anon and authenticated true:
--    SELECT has_function_privilege('anon','public.rpc_bloom_order_recipe_json(text,date,date,date,text,numeric,boolean,text)','EXECUTE');
--
-- 4. THE RECIPE IS UNTOUCHED. EXPECT md5(pg_get_functiondef) still
--    6204ae7bf6b12f1a17e8bcb3d72028ea / 44,251 chars.
--
-- 5. FRONTEND. The repoint of src/app/bloom/page.jsx:1099 rides in the same
--    commit and needs its own R31 walk on the RecipeMode screen -- Pieter's,
--    not a proxy. Until that walk, this function is live and unread, which is
--    the safe order: the reader lands before the caller moves.
-- ============================================================================
