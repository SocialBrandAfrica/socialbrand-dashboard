-- ============================================================================
-- SEC-002 -- revoke anon EXECUTE on every refresh/purge/cleanup function
-- ============================================================================
-- 2026-07-06, PM ruling (found while building Sparrie's skill). These are
-- pg_cron-only maintenance/engine-refresh functions -- there is no legitimate
-- reason for a browser client to call them. The anon key is published
-- client-side, so anon EXECUTE here meant the public could trigger a full L2
-- engine refresh or the monthly snapshot purge on demand. Confirmed zero
-- frontend consumers before revoking (grep for .rpc('refresh_'|'purge_'|
-- 'cleanup_' across src/ and public/ -- no matches).
--
-- Gotcha worth keeping: revoking `FROM anon` alone did NOT close the gap on
-- 12 of the 13 functions. Postgres grants EXECUTE to PUBLIC by default on
-- every new function, and `anon` inherits PUBLIC automatically -- so
-- has_function_privilege('anon', ..., 'EXECUTE') kept returning true until
-- the grant was revoked FROM PUBLIC specifically. `purge_old_snapshots` was
-- the one exception: it never carried a PUBLIC grant, only an explicit
-- `anon` one, so the first REVOKE alone closed it correctly. `authenticated`
-- keeps EXECUTE throughout (re-granted explicitly where it only had it via
-- PUBLIC) -- out of this ruling's stated scope, unchanged behaviour for
-- signed-in sessions.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.cleanup_push_log() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_old_snapshots() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_bt_precompute() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_kpi_view() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_anomaly_family3(text, numeric) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bloom_promo_pantry(text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bloom_ros_pantry(text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bt_buying_weekly() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bt_heroes() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bt_monthly() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_bt_tail() FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_classification(text, date) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_consignment_daily(text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_pipeline() FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.cleanup_push_log() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_bt_precompute() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_kpi_view() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_anomaly_family3(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bloom_promo_pantry(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bloom_ros_pantry(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_buying_weekly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_heroes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_monthly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_tail() TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_classification(text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_consignment_daily(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_pipeline() TO authenticated;
