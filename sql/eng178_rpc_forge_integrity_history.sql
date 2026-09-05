-- ============================================================================
-- ENG-178 -- a published reader for the integrity history, so no surface reads
--            the base table and no base-table policy is ever needed.
--
-- Ref:      BUG-LOG ENG-178 (CC block; next free read from the table at the
--           moment of the write, above every id mentioned there)
-- Author:   CC (Claude Code)
-- Date:     2026-09-05 SAST
-- Applies:  ONE new function. NO schema change. NO new config key. Additive.
--
-- ---------------------------------------------------------------------------
-- WHY A READER AND NOT A SELECT POLICY ON THE TABLE
-- ---------------------------------------------------------------------------
-- R30 section 1: every surface reads the engine's published interfaces only,
-- and base tables stay locked. A page that reads L1 directly is a DEFECT even
-- while it works. `sql/bloom029_item5_grant_compliance_summary_anon.sql` line
-- 50 already recorded the shipped decision in one line: "No grant on
-- forge_integrity_history, forge_count_run or forge_count_run_line." This
-- function is how that decision stays true while the consumer still gets its
-- history.
--
-- THE CONSUMERS, read from the generated reader map (ESTATE-MAPS map 2,
-- regenerated 2026-09-05 before this was written, never from memory):
--   * public/toolkit.html                      -> rpc_forge_integrity_trend
--   * src/app/api/forge/weekly-report/route.js -> rpc_forge_integrity_trend
--   * src/app/api/forge/run/route.js           -> rpc_forge_compliance_summary
-- ALL THREE RUN AS `anon`. toolkit.html carries the publishable key inline and
-- both API routes construct their client with NEXT_PUBLIC_SUPABASE_ANON_KEY.
-- There is no signed-in surface here, so the grant below is anon, exactly as
-- its sibling rpc_forge_compliance_summary already is.
--
-- NO PII HERE, AND THAT IS CHECKED RATHER THAN ASSUMED. The table is
-- (store_code, as_of_date, instrument, value_num, pool_num, captured_at), read
-- from the live catalog. The `issued_by` person-column that justified locking
-- anon out of forge_count_run (see create_forge_count_run.sql section 3) does
-- not exist on this table, so that precedent does not reach this object.
--
-- RETURNS jsonb, NOT SETOF, AND THAT IS THE WHOLE POINT (ENG-093).
-- A live 1,000-row PostgREST cap silently truncates a SETOF read: 206 Partial
-- Content, Content-Range 0-999/n, no error. The history spans 64 distinct dates
-- across 5 stores and 8 instruments, so a SETOF reader would truncate today,
-- not eventually. One jsonb row carrying the whole array cannot be truncated by
-- a row cap. Same structural fix as rpc_bloom_order_recipe_json.
--
-- rpc_forge_integrity_trend is NOT touched. Changing a live signature leaves
-- the old overload behind and is how a no-arg call becomes ambiguous. This is
-- additive, so toolkit.html and the weekly report keep working unchanged.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_forge_integrity_history(
  p_stores text[] DEFAULT NULL,
  p_from   date   DEFAULT NULL,
  p_to     date   DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'status', 'OK',
    'rows', COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.as_of_date, h.store_code, h.instrument), '[]'::jsonb),
    'row_count', count(*),
    'date_from', min(h.as_of_date),
    'date_to', max(h.as_of_date),
    'computed_at', now()
  )
  FROM public.forge_integrity_history h
  WHERE (p_stores IS NULL OR h.store_code = ANY(p_stores))
    AND (p_from IS NULL OR h.as_of_date >= p_from)
    AND (p_to IS NULL OR h.as_of_date <= p_to);
$function$;

-- Read RPC: anon stays executable by design (SQL-CONVENTIONS, R30 addendum --
-- the mutating-function anon revoke does not apply to reads). PUBLIC is revoked
-- explicitly anyway, because Postgres grants EXECUTE to PUBLIC on creation and
-- anon inherits it, the trap that has fired three times on this project.
REVOKE EXECUTE ON FUNCTION public.rpc_forge_integrity_history(text[],date,date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_forge_integrity_history(text[],date,date) TO anon, authenticated;

COMMENT ON FUNCTION public.rpc_forge_integrity_history(text[],date,date) IS
'GRADE: CALCULATED. ENG-178. Published reader over forge_integrity_history so no surface touches the base table (R30 section 1). Returns ONE jsonb row carrying the whole array because a SETOF read would hit the live 1,000-row PostgREST cap silently (ENG-093). Frozen nightly snapshot of the integrity instruments; computes nothing.';
