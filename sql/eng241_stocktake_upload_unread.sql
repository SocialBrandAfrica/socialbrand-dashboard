-- =============================================================================
-- ENG-241 / SB-CC-STOCKTAKE-001 -- THE UPLOAD EVENT NOW COUNTS THE ROWS THE ROUTE COULD NOT READ.
-- PM ruling 14-10-2026 (point 8): the gap is fixed with a NEW capture RPC signature, not a second call.
--
--   The upload route never sends a row it cannot read (a Front box holding "abc", a negative, a thousands comma, a duplicate
--   LineId). Those rows came back to the person in `rejected` but were never in the UPLOAD event, so the event said
--   "lines_set 40, rejected 0" for a sheet with 9 unreadable rows. The route now passes the count as p_unread and the
--   event records it beside the database's own refusals, plus how many lines were sent.
--
--   rpc_stocktake_capture(p_cycle uuid, p_lines jsonb, p_source text DEFAULT 'TYPED', p_unread integer DEFAULT 0)
--   - p_unread is validated (zero or more) and only ever written into the UPLOAD event detail: 'unread' and 'sent'.
--   - A caller that sends the old three arguments still resolves (the default), so the TYPED route is unchanged.
--   - The old three-argument signature is DROPPED in this migration. Two overloads would make a three-argument call ambiguous.
--   - ORDER: this migration first, then the route deploy. The old route works against the new function (default), the new
--     route does not work against the old one (an unknown parameter).
--   Asserted replace on the live definition, pinned on the live prosrc md5.
-- REVERSE: re-create the three-argument function from sql/eng241_stocktake_count_app_core.sql and drop the four-argument one.
-- =============================================================================

DO $mig$
DECLARE
  def text;
  v_live text;
  n int;
  a text;
BEGIN
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.oid = 'public.rpc_stocktake_capture(uuid, jsonb, text)'::regprocedure;
  IF v_live IS DISTINCT FROM 'da986ad21a3d03ffec70a7c404239edc' THEN
    RAISE EXCEPTION 'pin failed: live rpc_stocktake_capture md5 % is not the pinned da986ad2', v_live;
  END IF;
  def := pg_get_functiondef('public.rpc_stocktake_capture(uuid, jsonb, text)'::regprocedure);

  a := $a$p_source text DEFAULT 'TYPED'::text)$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'signature anchor found % times', n; END IF;
  def := replace(def, a, $b$p_source text DEFAULT 'TYPED'::text, p_unread integer DEFAULT 0)$b$);

  a := $a$IF p_source NOT IN ('TYPED','UPLOAD') THEN RAISE EXCEPTION 'unknown source %', p_source; END IF;$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'source-check anchor found % times', n; END IF;
  def := replace(def, a, a || $b$
  IF p_unread IS NULL OR p_unread < 0 THEN RAISE EXCEPTION 'unread must be zero or more'; END IF;$b$);

  a := $a$jsonb_build_object('lines_set', v_set, 'unchanged', v_same, 'rejected', jsonb_array_length(v_rej))$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'event anchor found % times', n; END IF;
  def := replace(def, a, $b$jsonb_build_object('lines_set', v_set, 'unchanged', v_same, 'rejected', jsonb_array_length(v_rej),
                            'unread', p_unread, 'sent', jsonb_array_length(p_lines))$b$);

  EXECUTE def;
END
$mig$;

DROP FUNCTION public.rpc_stocktake_capture(uuid, jsonb, text);

REVOKE EXECUTE ON FUNCTION public.rpc_stocktake_capture(uuid, jsonb, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_stocktake_capture(uuid, jsonb, text, integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_stocktake_capture(uuid, jsonb, text, integer) IS 'GRADE: RAW. Capture counts against a cycle (typed or upload). Count = front + back, both blank = uncounted. Writes the variance and an EDIT event per changed line. An UPLOAD event records lines_set, unchanged, rejected (the database''s refusals), unread (rows the route could not read and never sent, p_unread) and sent.';

NOTIFY pgrst, 'reload schema';
