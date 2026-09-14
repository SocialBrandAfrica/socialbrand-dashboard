-- create_rpc_forge_rls_guard.sql
--   public.forge_rls_guard_site         -- the register of known sites (RAW)
--   public.rpc_forge_rls_guard          -- G1 and G2: one row per silent or loud site, per client role (CALCULATED)
--   public.rpc_forge_rls_guard_summary  -- G4: the guard in one row and one line (CALCULATED)
--
-- RECORD of migration rlsguard_g1_g4_standing_guard, applied 2026-09-14 by CC through the Supabase connector,
-- SB-CC-RLSGUARD-001 (Forge, PM-filed) and SB-CC-ORDER-001 item 3. The text below is the migration as applied.
--
-- WHY. A table with row level security on and no policy a client role can use answers that role with an empty set
-- and no error. The platform read that as "no data" for months: ENG-163 found it at one site on 2026-09-02 and the
-- class was never swept; on 2026-09-14 it stood at 31 tables and about 46.8 million rows on the publishable key.
-- A sweep without a guard buys twelve days (the brief). This is the guard.
--
-- WHAT RUNS IT.
--   * The dashboard build: package.json "prebuild" runs scripts/rls-guard-gate.mjs, which calls
--     rpc_forge_rls_guard on the public key and stops the build when a SILENT site (class A or B) is NEW or CHANGED.
--   * The Tuesday platform diary: rpc_forge_rls_guard_summary().line, one line (PM's diary reads it).
--
-- PROVEN AT BUILD, 2026-09-14 20:1x SAST.
--   * Live: 72 silent sites (anon A 31, B 0; authenticated A 32, B 9), 10 loud, 0 new, gate PASS. The register holds
--     all 82 known sites. anon reaches the RPC (82 rows, SET LOCAL ROLE anon inside a rolled-back block).
--   * G3, a guard that has never caught anything has not been tested: three throwaway tables in a rolled-back block
--     came back probe_a A silent NEW, probe_b B silent NEW, probe_c C loud NEW, and the summary gate read FAIL
--     (4 new silent, 2 new loud). The self-test block is kept at the foot of this file to re-run.
--   * End to end through the build gate: see BUG-LOG ENG-163 addendum and DEPLOY-LOG 2026-09-14.
--
-- NAMED LIMIT. A policy that exists for the role but whose USING clause is false is silent too, and no catalog read
-- can see it. Security-invoker views over such tables would inherit the silence; 0 exist in public at build.

-- SB-CC-RLSGUARD-001 G1, G2 and G4 (CC 2026-09-14; SB-CC-ORDER-001 item 3). The standing guard against silent reads.
-- A table with RLS on answers a client role in one of three ways the brief names (G2):
--   A  RLS on and no policy at all: the role reads 0 rows and no error. SILENT.
--   B  RLS on, policies exist, none grants SELECT to the role: 0 rows and no error. SILENT.
--   C  the role holds no SELECT grant: the read fails 42501. LOUD, reported, never prioritised.
-- The register below holds every site known at this migration, so the gate fails only on a site that appears after it.
-- Named limit: a policy that exists for the role but whose USING clause evaluates false is silent too, and no catalog
-- read can see it. Security-invoker views over such tables would inherit the silence; 0 exist in public today.

CREATE TABLE public.forge_rls_guard_site (
  object_name   text NOT NULL,
  reader_role   text NOT NULL CHECK (reader_role IN ('anon', 'authenticated')),
  site_class    text NOT NULL CHECK (site_class IN ('A', 'B', 'C')),
  defect_id     text,
  first_seen    date NOT NULL DEFAULT CURRENT_DATE,
  registered_by text NOT NULL,
  note          text,
  PRIMARY KEY (object_name, reader_role)
);
ALTER TABLE public.forge_rls_guard_site ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.forge_rls_guard_site FROM anon, authenticated;
COMMENT ON TABLE public.forge_rls_guard_site IS
'GRADE: RAW. The register of known silent-read and grant-absent sites (SB-CC-RLSGUARD-001 G4). One row per table and client role, with its class, the defect id that owns it and the day it was first seen. Read only by rpc_forge_rls_guard (SECURITY DEFINER); no client grant, RLS on, so the guard lists this table itself as class C by design. A site the guard finds that is not here is NEW, and a NEW silent site fails the dashboard build.';

CREATE OR REPLACE FUNCTION public.rpc_forge_rls_guard()
 RETURNS TABLE(object_name text, reader_role text, site_class text, silent boolean, grant_present boolean, policies integer,
               reader_policies integer, est_rows bigint, known boolean, defect_id text, first_seen date, verdict text, story text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH readers AS (
    SELECT ro.rolname::text AS reader, ro.oid AS roid FROM pg_catalog.pg_roles ro WHERE ro.rolname IN ('anon', 'authenticated')),
  t AS (
    SELECT c.oid, c.relname::text AS obj, coalesce(s.n_live_tup, 0)::bigint AS est
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_catalog.pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relrowsecurity),
  x AS (
    SELECT t.obj, r.reader, t.est,
           has_table_privilege(r.reader, t.oid, 'SELECT') AS gp,
           (SELECT count(*)::int FROM pg_catalog.pg_policy p WHERE p.polrelid = t.oid) AS pol,
           (SELECT count(*)::int FROM pg_catalog.pg_policy p WHERE p.polrelid = t.oid AND p.polcmd IN ('r', '*')
              AND (0 = ANY(p.polroles) OR r.roid = ANY(p.polroles))) AS rpol
    FROM t CROSS JOIN readers r),
  k AS (
    SELECT x.*, CASE WHEN NOT x.gp THEN 'C' WHEN x.pol = 0 THEN 'A' WHEN x.rpol = 0 THEN 'B' END AS cls
    FROM x)
  SELECT k.obj, k.reader, k.cls, k.cls IN ('A', 'B'), k.gp, k.pol, k.rpol, k.est,
         (g.object_name IS NOT NULL AND g.site_class = k.cls), g.defect_id, g.first_seen,
         CASE WHEN g.object_name IS NULL THEN 'NEW' WHEN g.site_class <> k.cls THEN 'CHANGED' ELSE 'KNOWN' END,
         CASE k.cls
           WHEN 'A' THEN 'Silent: RLS is on and the table has no policy, so ' || k.reader || ' reads 0 of about ' || k.est || ' rows and gets no error.'
           WHEN 'B' THEN 'Silent: ' || k.pol || ' policy(ies) and none grants SELECT to ' || k.reader || ', so it reads 0 rows and gets no error.'
           ELSE 'Loud: ' || k.reader || ' holds no SELECT grant, so a read fails 42501. Reported, not prioritised.' END
         || CASE WHEN g.object_name IS NULL THEN ' Not in the register: a defect the day it appears.'
                 WHEN g.site_class <> k.cls THEN ' Registered as class ' || g.site_class || ' on ' || g.first_seen || '.'
                 ELSE '' END
  FROM k
  LEFT JOIN public.forge_rls_guard_site g ON g.object_name = k.obj AND g.reader_role = k.reader
  WHERE k.cls IS NOT NULL
  UNION ALL
  SELECT g.object_name, g.reader_role, g.site_class, false, NULL::boolean, NULL::integer, NULL::integer, NULL::bigint, true,
         g.defect_id, g.first_seen, 'CLEARED',
         'Registered as class ' || g.site_class || ' on ' || g.first_seen || ' and no longer a site. Prune the register row or re-check the table.'
  FROM public.forge_rls_guard_site g
  WHERE NOT EXISTS (SELECT 1 FROM k WHERE k.obj = g.object_name AND k.reader = g.reader_role AND k.cls IS NOT NULL)
  ORDER BY 12 DESC, 3, 1, 2;
$function$;

COMMENT ON FUNCTION public.rpc_forge_rls_guard() IS
'GRADE: CALCULATED. SB-CC-RLSGUARD-001 G1 and G2. One row per table in public with RLS on and per client role (anon, authenticated) that cannot read it as granted: class A (no policy) and B (no policy naming the role) are SILENT, class C (no grant) is LOUD. Each row carries the grant, the policy counts, an estimated row count (pg_stat n_live_tup, an estimate), and its standing in forge_rls_guard_site: KNOWN, NEW (a defect the day it appears), CHANGED, or CLEARED (registered, no longer a site). A catalog read that opens no base table, granted to anon so the packs can run it on their own key. NAMED LIMIT: a policy for the role whose USING clause is false is silent and invisible here; security-invoker views are not evaluated (0 in public at build).';

CREATE OR REPLACE FUNCTION public.rpc_forge_rls_guard_summary()
 RETURNS TABLE(checked_at timestamp with time zone, silent_sites integer, loud_sites integer, new_or_changed_silent integer,
               new_loud integer, cleared integer, gate text, line text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH g AS (SELECT * FROM public.rpc_forge_rls_guard()),
  s AS (
    SELECT
      count(*) FILTER (WHERE g.silent AND g.verdict <> 'CLEARED')::int AS silent_n,
      count(*) FILTER (WHERE NOT g.silent AND g.verdict <> 'CLEARED')::int AS loud_n,
      count(*) FILTER (WHERE g.silent AND g.verdict IN ('NEW', 'CHANGED'))::int AS bad_n,
      count(*) FILTER (WHERE NOT g.silent AND g.verdict = 'NEW')::int AS newloud_n,
      count(*) FILTER (WHERE g.verdict = 'CLEARED')::int AS cleared_n,
      count(*) FILTER (WHERE g.reader_role = 'anon' AND g.site_class = 'A' AND g.verdict <> 'CLEARED')::int AS aa,
      count(*) FILTER (WHERE g.reader_role = 'anon' AND g.site_class = 'B' AND g.verdict <> 'CLEARED')::int AS ab,
      count(*) FILTER (WHERE g.reader_role = 'authenticated' AND g.site_class = 'A' AND g.verdict <> 'CLEARED')::int AS ua,
      count(*) FILTER (WHERE g.reader_role = 'authenticated' AND g.site_class = 'B' AND g.verdict <> 'CLEARED')::int AS ub
    FROM g)
  SELECT now(), s.silent_n, s.loud_n, s.bad_n, s.newloud_n, s.cleared_n,
         CASE WHEN s.bad_n > 0 THEN 'FAIL' ELSE 'PASS' END,
         format('RLS guard %s SAST: %s silent read sites (anon A %s, B %s; authenticated A %s, B %s) and %s loud. %s new or changed silent, %s new loud, %s cleared. Gate %s.',
                to_char(now() AT TIME ZONE 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI'), s.silent_n, s.aa, s.ab, s.ua, s.ub, s.loud_n,
                s.bad_n, s.newloud_n, s.cleared_n, CASE WHEN s.bad_n > 0 THEN 'FAIL' ELSE 'PASS' END)
  FROM s;
$function$;

COMMENT ON FUNCTION public.rpc_forge_rls_guard_summary() IS
'GRADE: CALCULATED. SB-CC-RLSGUARD-001 G4: the guard in one row and one line, for the Tuesday platform diary and the dashboard prebuild gate. gate = FAIL when any silent site (class A or B) is NEW or CHANGED against forge_rls_guard_site; loud and cleared sites are counted, never fatal.';

-- Seed the register from the live classification at this moment. Every site known today is registered, so the gate
-- fails only on a site that appears after this migration.
INSERT INTO public.forge_rls_guard_site (object_name, reader_role, site_class, defect_id, registered_by, note)
SELECT g.object_name, g.reader_role, g.site_class,
       CASE WHEN g.site_class IN ('A', 'B') THEN 'ENG-163' END,
       'CC 2026-09-14, SB-CC-RLSGUARD-001 baseline',
       CASE WHEN g.object_name = 'forge_rls_guard_site' THEN 'By design: read only by rpc_forge_rls_guard.'
            WHEN g.site_class = 'C' THEN 'Loud (42501): the grant is absent.'
            WHEN g.site_class = 'B' THEN 'Silent: policies exist and none names this role.'
            ELSE 'Silent: RLS on and no policy, the ENG-163 class (split A of the brief).' END
FROM public.rpc_forge_rls_guard() g
WHERE g.verdict = 'NEW';

REVOKE EXECUTE ON FUNCTION public.rpc_forge_rls_guard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forge_rls_guard_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_forge_rls_guard() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_forge_rls_guard_summary() TO anon, authenticated, service_role;

-- =====================================================================================================================
-- G3 SELF-TEST, re-runnable. Run as the database owner. It creates three throwaway tables, reads the guard, and RAISES
-- its result, so the whole block rolls back and nothing persists. Expected: probe_a A silent NEW, probe_b B silent NEW,
-- probe_c C loud NEW for both roles, and the summary gate FAIL. Any other answer means the guard is broken.
-- =====================================================================================================================
-- DO $g3$
-- DECLARE r record; msg text := ''; s record;
-- BEGIN
--   CREATE TABLE public._cc_rlsguard_probe_a (id int);
--   GRANT SELECT ON public._cc_rlsguard_probe_a TO anon, authenticated;
--   ALTER TABLE public._cc_rlsguard_probe_a ENABLE ROW LEVEL SECURITY;
--   CREATE TABLE public._cc_rlsguard_probe_b (id int);
--   GRANT SELECT ON public._cc_rlsguard_probe_b TO anon, authenticated;
--   ALTER TABLE public._cc_rlsguard_probe_b ENABLE ROW LEVEL SECURITY;
--   CREATE POLICY probe_b_service_only ON public._cc_rlsguard_probe_b FOR SELECT TO service_role USING (true);
--   CREATE TABLE public._cc_rlsguard_probe_c (id int);
--   REVOKE ALL ON public._cc_rlsguard_probe_c FROM anon, authenticated;
--   ALTER TABLE public._cc_rlsguard_probe_c ENABLE ROW LEVEL SECURITY;
--   FOR r IN SELECT g.object_name, g.reader_role, g.site_class, g.silent, g.verdict
--            FROM public.rpc_forge_rls_guard() g WHERE g.object_name LIKE '\_cc\_rlsguard\_probe\_%' ORDER BY 1, 2 LOOP
--     msg := msg || r.object_name || '/' || r.reader_role || '=' || r.site_class
--            || (CASE WHEN r.silent THEN ' silent ' ELSE ' loud ' END) || r.verdict || '; ';
--   END LOOP;
--   SELECT * INTO s FROM public.rpc_forge_rls_guard_summary();
--   RAISE EXCEPTION 'G3 (rolled back, no table persists): % || summary: gate %, new or changed silent %, new loud %',
--     msg, s.gate, s.new_or_changed_silent, s.new_loud;
-- END $g3$;
