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
-- THE EXPOSURE IS TWICE WHAT THE BUG-LOG ROW RECORDS
-- ---------------------------------------------------------------------------
-- ENG-093 records 10116 DC_AMBIENT at 1,065 lines, so 65 dropped. Measured from
-- bloom_order_cache 2026-09-01: that desk now returns **2,071 lines**, so a
-- truncated read drops **1,071**. The SB-CC-BLOOM-026 5(b2) hidden-line append
-- roughly doubled the sheet and doubled this exposure with it. The row's figure
-- is not wrong, it is stale, and it understates by 16x.
--
-- ---------------------------------------------------------------------------
-- THE SWEEP RESULT (R30 addendum 3 -- a population with its denominator)
-- ---------------------------------------------------------------------------
-- Denominator: 74 set-returning rpc_* functions executable by anon or
-- authenticated; 64 call sites across 17 files, found with all THREE patterns
-- (supabase .rpc(, a local helper building a REST path, and a raw rest/v1/rpc/
-- URL) -- a .rpc( grep alone misses all nine readers in public/toolkit.html.
--
--   OVER THE CAP AND UNPAGINATED ......... 1 site, this one. 2,071 vs 1,000.
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
-- 2. THE CAP IS BEATEN ON THE DESK THAT PROVED IT. 10116 DC_AMBIENT:
--    EXPECT line_count = served = the full figure (2,071 at the 2026-08-31
--    cache build), never 1,000. Re-count at run time -- it moves nightly.
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
