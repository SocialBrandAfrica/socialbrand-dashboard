-- =====================================================================
-- sec001_atlas_anon_write_lockdown.sql
-- SEC-001 (the Atlas slice): remove anon/authenticated WRITE access from
-- the atlas_* tables. Read access is deliberately untouched -- see SCOPE.
--
-- Author: CC (Claude Code)   Date: 2026-08-08 (system clock, fresh read)
-- Ref: SEC-001, carried in sql/pmini_partner_lockdown.sql's footer and in
--      HANDOVER-CURRENT as "nobody has started it".
--
-- ---------------------------------------------------------------------
-- THE CLAIM THIS CLOSES, AND THE CORRECTION THAT RIDES WITH IT
-- ---------------------------------------------------------------------
-- SEC-001 is recorded as: "anon/authenticated still hold INSERT/UPDATE/DELETE
-- on base tables, so an outside key could delete the ledger."
--
-- MEASURED 2026-08-08, and the second half is FALSE:
--   * 8 of 113 public tables carry anon INSERT/UPDATE/DELETE
--   * ALL EIGHT are atlas_* -- the knowledgebase
--   * ZERO sigma_*, ZERO l2_*, ZERO order_*, ZERO daily_snapshots
-- The retail ledger was never exposed. What was exposed is the Atlas
-- knowledgebase, which is real but is a different asset, a different owner
-- (the Librarian's project, FILE-GOVERNANCE section 0e) and a different
-- severity. Retire the "delete the ledger" framing; do not re-quote it.
--
-- Note the shape of the original error, because it is this project's most
-- expensive recurring one: the claim was read off a GRANT TABLE. A grant is
-- not a behaviour. The same session that logged this also logged ENG-068,
-- where a grant table said auth_select=true and the rows were invisible
-- because RLS had no policy. Grants over-state and under-state in both
-- directions. Only SET ROLE settles it.
--
-- ---------------------------------------------------------------------
-- PRE-FLIGHT (R30 section 2 -- enumerate every consumer, verify each survives)
-- ---------------------------------------------------------------------
-- This is the discipline the ORIGINAL SEC-001 RLS lockdown skipped, which is
-- how it silently emptied the Pulse Mini Kitchen tab. Consumers enumerated:
--   1. Atlas browser page (Daisy/Atlas/deploy/Atlas.html) -- calls
--      functions/v1/atlas x4, and has ZERO rest/v1/atlas_* references.
--      It never touches these tables directly.
--   2. Atlas engine (Daisy/Atlas/engine/atlas-engine-latest.js) -- a Supabase
--      EDGE FUNCTION whose every insert/update/delete goes through one header
--      builder reading SUPABASE_SERVICE_ROLE_KEY. service_role BYPASSES RLS
--      and needs none of these grants. UNAFFECTED BY CONSTRUCTION.
--   3. SocialBrand-Knowledgebase project -- 4 matches, all .md documentation.
--      No code.
--   4. socialbrand-dashboard repo -- zero atlas_ references in src/public/sql.
-- No consumer writes as anon. Nothing here can break a live path.
--
-- EXPOSURE PROVEN BEHAVIOURALLY BEFORE THE FIX, not read off a catalog:
--   BEGIN; SET LOCAL ROLE anon;
--   INSERT INTO atlas_settings ...; DELETE FROM atlas_settings ...;  -- both succeeded
--   ROLLBACK;
--
-- ---------------------------------------------------------------------
-- SCOPE -- writes only, and the read question is NAMED not silently widened
-- ---------------------------------------------------------------------
-- anon SELECT is LEFT IN PLACE. Two reasons, and the second is the real one:
--   (a) SEC-001 as written is about INSERT/UPDATE/DELETE;
--   (b) Atlas belongs to the Librarian's project (section 0e). Narrowing who
--       may READ the knowledgebase is a custody decision for PM/the Librarian,
--       not a call CC makes inside a write-lockdown migration.
-- ** FLAGGED, because it is a real finding and should not die in a comment:
--    anon can currently SELECT the entire Atlas knowledgebase, and no consumer
--    needs that -- the browser goes through the edge function. Closing it is
--    likely correct and is one more line here. It needs an owner's word. **
-- =====================================================================

DO $$
DECLARE
  t   record;
  n   int;
BEGIN
  SELECT count(*) INTO n
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'atlas\_%';

  -- No silent scope drift: this migration was written against exactly 8
  -- tables. If Atlas has grown or shrunk, stop and re-measure rather than
  -- quietly locking down a set nobody checked.
  IF n <> 8 THEN
    RAISE EXCEPTION 'SEC-001 atlas lockdown expected 8 atlas_* tables, found %. Re-measure before running.', n;
  END IF;

  FOR t IN
    SELECT c.relname
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'atlas\_%'
    ORDER BY c.relname
  LOOP
    -- LAYER 1 -- the GRANT. Remove write privileges outright.
    EXECUTE format(
      'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.%I FROM anon, authenticated', t.relname);

    -- LAYER 2 -- the POLICY. `atlas_anon_all` is cmd=ALL with qual/with_check
    -- both true: wide open. Replaced with a SELECT-only policy so read
    -- behaviour is byte-identical and the write path is shut at the policy
    -- layer too. Either layer alone would hold today; both, because every
    -- security incident on this project so far has been a single-layer fix
    -- that did not (SEC-002, BLOOM-004, ENG-031, ENG-068, the pmini PUBLIC
    -- hole -- five firings of one class).
    EXECUTE format('DROP POLICY IF EXISTS atlas_anon_all ON public.%I', t.relname);
    EXECUTE format(
      'CREATE POLICY atlas_anon_select ON public.%I FOR SELECT TO anon USING (true)', t.relname);

    RAISE NOTICE 'SEC-001 locked down: %', t.relname;
  END LOOP;
END $$;
