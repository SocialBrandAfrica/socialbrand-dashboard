-- =============================================================================
-- sec_pin_search_path_security_definer.sql
-- Pin search_path on every SECURITY DEFINER function in public that does not
-- already carry one.
-- =============================================================================
-- THE DEBT. HANDOVER-CURRENT has carried "75 of 117 SECURITY DEFINER functions
-- do not pin search_path" as an open security item since 2026-08-25. Re-measured
-- at source 2026-09-02: still 75, now of 119 -- the count did not move, the
-- denominator did.
--
-- WHY IT MATTERS. A SECURITY DEFINER function runs as its owner (postgres here).
-- If it does not pin search_path, the CALLER chooses which schema an unqualified
-- name resolves in. A caller who can create objects in a schema earlier on the
-- path can shadow a table or a function the body means to call, and the body
-- then executes the caller's object AS postgres. That is the same family as
-- ENG-144's inert read-only guard: a protection that reads as present and is not.
--
-- WHY THIS IS SAFE TO APPLY, and it is a dependent check, not an assurance.
-- Measured at source 2026-09-02 across all 75 targets:
--   references to extensions.  0
--   references to auth.        0
--   references to cron.        0
--   references to net.         0
--   references to vault.       0
-- Nothing outside `public` is reached by any of them, so pinning to 'public'
-- alone cannot break a body. The block below RE-RUNS that check at apply time
-- and ABORTS rather than trusting this paragraph -- the measurement is dated,
-- the guard is not.
--
-- CONVENTION. `search_path=public`, which is what 42 of the 44 already-pinned
-- SECURITY DEFINER functions carry. The other two carry `public, pg_catalog`
-- and are left exactly as they are.
--
-- WHY A DO BLOCK AND NOT 75 ALTER STATEMENTS. A typed list of 75 signatures is
-- a map that is wrong the moment a function is added or its signature changes
-- (ESTATE-MAPS: a map that was typed is already wrong). This discovers its own
-- population, is idempotent -- re-running it pins nothing because nothing is
-- left unpinned -- and it reports its own count.
--
-- ALTER FUNCTION ... SET search_path does NOT drop, recreate or redefine
-- anything. No body changes, no signature changes, so no overload can be
-- created and no dependent view or function is invalidated.
--
-- 🔴 NOT APPLIED. Written 2026-09-02 while the database is frozen until the
-- three 03-09 DC orders are placed and exported. Apply in one pass afterwards.
-- =============================================================================

DO $sec$
DECLARE
  r            record;
  v_pinned     int := 0;
  v_unsafe     int;
  v_before     int;
BEGIN
  -- ---------- the guard, re-run at apply time ----------
  SELECT count(*) INTO v_unsafe
  FROM pg_proc p
  JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public'
    AND p.prosecdef
    AND (p.proconfig IS NULL OR NOT EXISTS (
          SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))
    AND pg_get_functiondef(p.oid) ~* '\m(extensions|auth|cron|net|vault|graphql|storage)\.';

  IF v_unsafe > 0 THEN
    RAISE EXCEPTION
      'ABORTED: % unpinned SECURITY DEFINER function(s) reach outside public. '
      'Pinning them to public alone would break them. Widen the pin for those '
      'specific functions deliberately, then re-run.', v_unsafe;
  END IF;

  SELECT count(*) INTO v_before
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.prosecdef
    AND (p.proconfig IS NULL OR NOT EXISTS (
          SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));

  -- ---------- the pin ----------
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.prosecdef
      AND (p.proconfig IS NULL OR NOT EXISTS (
            SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))
    ORDER BY 1
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path TO %L', r.sig, 'public');
    v_pinned := v_pinned + 1;
  END LOOP;

  RAISE NOTICE 'search_path pinned on % of % unpinned SECURITY DEFINER functions',
               v_pinned, v_before;
END
$sec$;

-- =============================================================================
-- R22 -- run this AFTER and paste the result into DEPLOY-LOG. It must return 0.
-- =============================================================================
-- SELECT count(*) AS still_unpinned
-- FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.prosecdef
--   AND (p.proconfig IS NULL OR NOT EXISTS (
--         SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));
--
-- And the behavioural half, because a catalog read is not a behaviour test:
-- call one repointed read RPC as anon and confirm it still returns rows, e.g.
--   SELECT jsonb_array_length((rpc_bloom_order_cached('80175','DC_AMBIENT'))->'lines');
-- =============================================================================
