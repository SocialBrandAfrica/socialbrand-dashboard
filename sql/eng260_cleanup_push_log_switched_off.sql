-- ENG-263 (applied as migration eng260_cleanup_push_log_switched_off): cleanup_push_log() deleted push_log rows older than 30 days; push_log is kept permanently. Nothing called it (0 cron jobs, 0 functions, 0 scripts) but authenticated could execute it. The delete is switched off; the retired body is kept below.
-- Retired body: DELETE FROM push_log WHERE completed_at < NOW() - INTERVAL '30 days';
CREATE OR REPLACE FUNCTION public.cleanup_push_log()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT 1;  -- ENG-263: delete switched off; retired body: DELETE FROM push_log WHERE completed_at < NOW() - INTERVAL '30 days'; push_log is kept permanently.
$function$;
REVOKE EXECUTE ON FUNCTION public.cleanup_push_log() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.cleanup_push_log() IS 'RETIRED 14-10-2026 (ENG-263). The 30-day push_log delete is switched off; the function now does nothing. Nothing called it (0 cron jobs, 0 functions, 0 scripts). Successor: none; push_log is kept permanently.';