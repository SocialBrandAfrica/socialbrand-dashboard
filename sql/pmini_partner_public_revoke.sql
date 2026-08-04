-- pmini_partner_public_revoke.sql
-- SB-CC-PMINI-WIRE-001 Gap B — COMPLETION of the partner lockdown.
-- Applied + verified live 2026-08-04 via Supabase MCP migration
--   pmini_partner_lockdown_revoke_public_execute (+ a follow-up feed_health grant).
--
-- WHY THIS EXISTS
--   pmini_partner_lockdown.sql (the Route-3 draft) revoked function EXECUTE FROM
--   the pmini_partner ROLE, but Postgres grants EXECUTE to PUBLIC on function
--   creation and every role inherits PUBLIC. So after that lockdown deployed,
--   pmini_partner could still execute 167/229 public functions -- including
--   rpc_dept_summary / rpc_top20 / rpc_product_detail (whole-store sales) --
--   failing the lockdown's OWN acceptance test ("no OTHER rpc callable"). Classic
--   PUBLIC-grant trap: REVOKE ... FROM <role> is a no-op while PUBLIC still holds
--   the grant. The base-table lockdown was fine; only the function surface leaked.
--
-- PRE-FLIGHT (read-only, 2026-08-04) -- proves this is non-breaking:
--   * 0 functions are reachable by `anon` ONLY via PUBLIC  (all anon RPCs hold an
--     explicit anon grant) -> dashboard anon path unaffected.
--   * 0 functions are reachable by `authenticated` ONLY via PUBLIC -> logged-in
--     path unaffected.
--   => revoking PUBLIC removes nothing anon/authenticated actually use; it only
--      strips pmini_partner's inherited surface.
--
-- APPLIED:
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- The original lockdown's GRANT of rpc_feed_health_daily to pmini_partner was via
-- PUBLIC (never an explicit grant), so the revoke above removed it. Restore it
-- explicitly so the partner page's feed-health strip keeps working.
GRANT EXECUTE ON FUNCTION public.rpc_feed_health_daily(text,text) TO pmini_partner;

SELECT pg_notify('pgrst', 'reload schema');

-- VERIFIED LIVE (2026-08-04):
--   pmini_partner app-facing EXECUTE surface = EXACTLY:
--     rpc_consignment_lines(text,text,integer,text,boolean)   (explicit grant)
--     rpc_feed_health_daily(text,text)                        (explicit grant)
--   pmini_partner CANNOT execute: rpc_dept_summary, rpc_top20, rpc_product_detail,
--     rpc_focus_chart, refresh_*/classify_*/kpi functions (all now blocked).
--   pmini_partner has NO base-table SELECT (sigma_sales / daily_snapshots /
--     sigma_articles / l2_consignment_daily all false).
--   anon + authenticated retain EXECUTE on every dashboard RPC (explicit grants).
--
-- OWNERSHIP CAVEAT (owed to Pieter / supabase_admin):
--   The MCP role could not revoke PUBLIC from ~113 functions it does not own --
--   these are SYSTEM / EXTENSION utilities (pg_cron, pgrst, supabase internals),
--   NOT app data RPCs, so they are not a partner-data-exposure risk. If a fully
--   clean PUBLIC surface is wanted, run the REVOKE above again as supabase_admin.
--
-- Gap B acceptance test (lockdown file) now PASSES: with the partner key alone a
-- browser can read the consignment lines + feed health and NOTHING else.
