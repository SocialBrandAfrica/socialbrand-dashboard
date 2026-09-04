-- rpc_bloom_hidden_demand_json -- the truncation-proof reader for the
-- hidden-sellers card. SB-CC-BLOOM-029 item 2 v1.2 (PM ruling 2026-09-02),
-- closing ENG-093's frontend half on the surface that actually carries the risk.
--
-- Applied live 2026-09-02 as migration `bloom029_item2_hidden_demand_json_reader`.
-- The body below is byte-identical to what was applied.
--
-- WHY THIS AND NOT RecipeMode. The brief's item 2 v1.0 pointed at RecipeMode.
-- Measured at source, that screen cannot carry the fix: the nav exposes only
-- 'desks' and 'desk', nothing sets appMode to 'recipe', and RecipeMode's own
-- generate() omits the REQUIRED p_route so it raises "p_route is required" if it
-- ever ran. Confirmed on the live dashboard, which renders two tabs. The live
-- order path is rpc_bloom_order_cached, already jsonb and already tripwired.
-- PM re-scoped item 2 to the reader that IS live and IS closest to the cap.
--
-- THE RISK, measured 2026-09-02: 12 of the 13 RPCs the Bloom page calls are SETOF
-- and could truncate at PostgREST's live 1,000-row cap. None does today, and
-- rpc_bloom_hidden_demand is the closest -- 557 of 1,000 at 10116 DC_AMBIENT, 342
-- at 80175 -- and it grows with the pool. A silently-short hidden list is the same
-- false all-clear as an empty one, which is the exact defect that card exists to end.
--
-- THE CAP IS PROVEN BEHAVIOURALLY, never by grepping for a setting: PostgREST
-- answered a SETOF read with "206 Partial Content, Content-Range: 0-999/1065".
-- Testing for a `db_max_rows` SETTING is what made this file's predecessors
-- record that no cap exists.
--
-- ADDITIVE. The SETOF rpc_bloom_hidden_demand is untouched, so no caller breaks
-- (R30 §2). SECURITY INVOKER deliberately, exactly like rpc_bloom_order_recipe_json:
-- the inner reader is SECURITY DEFINER and that is where the privilege is
-- load-bearing (l2_soh_daily carries RLS with zero policies, so an invoker build
-- there returns a confident "nothing hidden" as anon -- the ENG-068 shape).
--
-- R22 (PM's test, run in ONE statement so all four figures see the same data):
--   10116 DC_AMBIENT  served 557 = line_count 557 = array length 557 = SETOF 557
--   80175 DC_AMBIENT  served 342 = line_count 342 = array length 342 = SETOF 342

CREATE OR REPLACE FUNCTION public.rpc_bloom_hidden_demand_json(
  p_store_code text,
  p_route      text
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_lines jsonb;
  v_n     int;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.rate_corrected DESC NULLS LAST, r.product_code), '[]'::jsonb),
         count(*)
    INTO v_lines, v_n
  FROM public.rpc_bloom_hidden_demand(p_store_code, p_route) r;

  RETURN jsonb_build_object(
    'status',      'OK',
    'lines',       v_lines,
    'line_count',  v_n,
    'served',      jsonb_array_length(v_lines),
    'computed_at', now(),
    'requested',   jsonb_build_object('store_code', p_store_code, 'route', p_route)
  );
END
$function$;

-- Grants stated explicitly on a new function (R30 addendum). This is a READ
-- routine, and read RPCs stay anon-executable by design -- the addendum's
-- REVOKE-from-anon pattern is scoped to MUTATING functions only.
GRANT EXECUTE ON FUNCTION public.rpc_bloom_hidden_demand_json(text, text) TO anon, authenticated;

COMMENT ON FUNCTION public.rpc_bloom_hidden_demand_json(text, text) IS
'GRADE: CALCULATED. ENG-093/ENG-095 truncation-proof reader over rpc_bloom_hidden_demand. Returns ONE jsonb row so the live 1,000-row PostgREST cap cannot silently short the hidden-sellers card; served vs line_count is the R22 tripwire and a consumer refuses a short read. Additive: the SETOF original is untouched.';
