-- pmini_partner_lockdown.sql
-- SB-CC-PMINI-WIRE-001 Gap B (Route 3) — lock the Pulse Mini partner read path to
-- consignment only, via a dedicated restricted key bound to a new role.
--
-- ============================================================================
-- STATUS: DRAFT — DO NOT RUN. Access-control change.
--   * PM signs the role + grant plan before it runs (brief guardrail).
--   * PIETER executes it (Supabase admin) and mints the partner JWT — the JWT
--     secret never leaves Supabase; CC never sees it. CC drafted/audited only.
--   * Deploy ORDER: the staged engine bundle first
--       1. sql/create_v_consignment_catalog.sql
--       2. sql/create_l2_consignment_daily.sql   (re-sourced refresh)
--       3. sql/rpc_consignment_lines.sql         (+item_type, +p_include_catalog)
--     THEN this file (it grants EXECUTE on the new 5-arg rpc signature).
-- Date drafted: 2026-06-16. Updated 2026-06-17 (5-arg rpc signature; RPC-only page).
--
-- ============================================================================
-- FINDINGS (read-only audit, 2026-06-16, live)
-- ----------------------------------------------------------------------------
--   * 50 public base tables; 42 have RLS disabled.
--   * The `anon` (publishable) key has SELECT + INSERT + UPDATE + DELETE on ALL 50.
--     => An outside party holding the publishable key could DELETE/TRUNCATE the
--        entire sales ledger (sigma_sales), daily_snapshots, l2_consignment_daily, etc.
--   * The SAME anon key powers the main live dashboard. So a blunt "revoke anon" or
--     "blanket RLS" BREAKS the dashboard. Confirmed risk, not theory. Route 3 below
--     touches the `anon` role ZERO times => zero blast radius on dashboard/engine.
--   * The anon-write hole is closed SEPARATELY by SEC-001 (see footer) — not bundled.
--
-- ============================================================================
-- ROUTE 3 — dedicated restricted partner role (RPC-only after WIRE-001)
-- ----------------------------------------------------------------------------
-- After the WIRE-001 code refactor, BOTH Pulse Mini API routes are RPC-only:
--   * /api/dev-corner/sigma-lines  -> rpc_consignment_lines + rpc_feed_health_daily
--   * /api/dev-corner/consignment  -> rpc_consignment_lines (p_include_catalog=true)
-- No route reads sigma_articles / sigma_ean_master / daily_snapshots anymore. So the
-- partner role needs EXECUTE on exactly the two consignment RPCs and NOTHING else.

-- STEP 1 — create the restricted role (Pieter / Supabase admin).
--   Supabase has no "second anon key" UI, so the partner key is a JWT signed with
--   the project JWT secret carrying {"role":"pmini_partner"}. Pieter mints it; the
--   secret never leaves Supabase.

CREATE ROLE pmini_partner NOLOGIN;
GRANT pmini_partner TO authenticator;                 -- so PostgREST can assume it

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM pmini_partner;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM pmini_partner;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM pmini_partner;
REVOKE ALL ON SCHEMA public FROM pmini_partner;
GRANT  USAGE ON SCHEMA public TO pmini_partner;       -- resolve names only

-- Belt-and-braces: also block future objects from auto-granting to this role.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES    FROM pmini_partner;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM pmini_partner;

-- STEP 2 — grant ONLY the two consignment RPCs (both SECURITY DEFINER, so they read
--   their own tables as owner; the partner role gets no base-table SELECT).
--   NOTE the 5-arg rpc_consignment_lines signature (WIRE-001 added p_include_catalog).

GRANT EXECUTE ON FUNCTION public.rpc_consignment_lines(text,text,integer,text,boolean) TO pmini_partner;
GRANT EXECUTE ON FUNCTION public.rpc_feed_health_daily(text,text)                       TO pmini_partner;

SELECT pg_notify('pgrst', 'reload schema');

-- ============================================================================
-- ACCEPTANCE — PM live check before sign-off (run AS the partner role / partner key)
-- ----------------------------------------------------------------------------
-- With the partner key alone:
--   PASS  the two RPCs return rows:
--     SELECT count(*) FROM rpc_consignment_lines('2026-06','10116',610,'socialbrand',true);
--     SELECT count(*) FROM rpc_feed_health_daily('10116','2026-06');
--   PASS  a REST call to ANY base table returns 401 / empty (no SELECT granted):
--     GET /rest/v1/sigma_sales?select=*&limit=1          -> permission denied / []
--     GET /rest/v1/daily_snapshots?select=*&limit=1       -> permission denied / []
--     GET /rest/v1/sigma_articles?select=*&limit=1        -> permission denied / []
--   PASS  no OTHER rpc is callable (e.g. rpc_dept_summary) -> permission denied.
--
-- In-DB equivalent (psql, superuser) to prove the grant surface:
--   SET ROLE pmini_partner;
--   SELECT has_function_privilege('rpc_consignment_lines(text,text,integer,text,boolean)','EXECUTE'); -- t
--   SELECT has_table_privilege('sigma_sales','SELECT');     -- f
--   SELECT has_table_privilege('daily_snapshots','SELECT'); -- f
--   RESET ROLE;
--
-- ============================================================================
-- ROLLBACK (if the partner arrangement is ever retired)
-- ----------------------------------------------------------------------------
--   REVOKE EXECUTE ON FUNCTION public.rpc_consignment_lines(text,text,integer,text,boolean) FROM pmini_partner;
--   REVOKE EXECUTE ON FUNCTION public.rpc_feed_health_daily(text,text)                       FROM pmini_partner;
--   DROP ROLE pmini_partner;   -- after the partner JWT is rotated out
--
-- ============================================================================
-- SEPARATE, DO NOT BUNDLE — app-wide anon write hole = SEC-001 (own security pass)
-- ----------------------------------------------------------------------------
-- Independent of Pulse Mini: anon should be READ-ONLY everywhere. All writes use the
-- service_role key (server-side push). CC audited it safe (no client anon writes;
-- every .rpc() is a read). Pieter runs the SEC-001 REVOKE after PM + Pieter sign-off:
--
--     -- REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
--     --   ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
--     -- ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     --   REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES FROM anon, authenticated;
--
-- Tracked separately from WIRE-001 Gap B; closes the "external party can delete the
-- ledger" hole but is broader than the Pulse Mini go-live.
-- ============================================================================
