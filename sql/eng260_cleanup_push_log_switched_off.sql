-- ENG-260 (platform lane 14-10-2026, PM s15 pt4). cleanup_push_log() deleted push_log rows older than 30 days,
-- against the 21-09 keep-permanently ruling. Nothing called it (0 cron jobs, 0 functions, 0 scripts), but it was
-- executable by authenticated. The delete is switched off; the retired body stays here (R28).
-- Retired body: DELETE FROM push_log WHERE completed_at < NOW() - INTERVAL '30 days';
CREATE OR REPLACE FUNCTION public.cleanup_push_log()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT 1;  -- ENG-260 (14-10-2026): delete switched off. Retired body (R28): DELETE FROM push_log WHERE completed_at < NOW() - INTERVAL '30 days'; it broke the 21-09 keep-permanently ruling for push_log.
$function$;
REVOKE EXECUTE ON FUNCTION public.cleanup_push_log() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.cleanup_push_log() IS 'RETIRED 14-10-2026 (ENG-260, R28). The 30-day push_log delete broke the 21-09 keep-permanently ruling; the function now does nothing. Nothing called it (0 cron jobs, 0 functions, 0 scripts). Successor: none; push_log is kept permanently.';