-- ============================================================================
-- SEC-002 follow-up -- four writers missed by the prefix-based sweep
-- ============================================================================
-- 2026-07-06. The original sec_002_revoke_anon_execute_refresh_purge.sql
-- swept only proname ILIKE 'refresh_%'/'purge_%'/'cleanup_%'. A broader sweep
-- (every non-rpc_ function whose body contains INSERT/UPDATE/DELETE/TRUNCATE,
-- then every function of any name matching the same test) found four more
-- anon-executable writers PM's own Known Gaps list had already named two of:
--   - check_l1_feed_freshness()               -- writes a freshness verdict
--   - fill_l2_bloom_promo_pantry_sibling_fallback() -- engine pantry fill
--   - upsert_search_index(text)               -- search index rebuild
--   - rpc_bt_log_out_events()                 -- daily BT out-of-stock logger,
--       called only by refresh_l2_pipeline; the rpc_ prefix looks
--       frontend-facing but it takes no params and is a pure pg_cron job.
-- All four confirmed zero frontend .rpc() consumers before revoking. Post-fix
-- sweep (same query, prokind='f' AND body matches a write verb AND anon can
-- execute) returns ZERO rows across the entire public schema.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.check_l1_feed_freshness() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fill_l2_bloom_promo_pantry_sibling_fallback() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.upsert_search_index(text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_bt_log_out_events() FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.check_l1_feed_freshness() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fill_l2_bloom_promo_pantry_sibling_fallback() TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_search_index(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_bt_log_out_events() TO authenticated;
