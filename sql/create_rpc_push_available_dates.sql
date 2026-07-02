-- =============================================================================
-- create_rpc_push_available_dates.sql
-- SB-CC-RETIRE-003 item 1. Deployed LIVE by PM 2026-07-02 via Supabase MCP
--   migration retire003_repoint_picker_and_freshness_rpcs. Canonical source,
--   pulled from the live definition (pg_get_functiondef) 2026-07-02 -- live was
--   ahead of main on this object.
-- =============================================================================
-- WHY (the 1 July dashboard incident):
--   The old body read push_log.snapshot_date. The PRSSALE push tasks were
--   removed 2026-06-28 (RETIRE-001), so push_log's newest snapshot_date froze
--   at 28 Jun and the date picker stopped offering newer days even though the
--   sigma-native pipeline had them. Cause class: a display RPC left on a
--   retired source after RETIRE-002's Tier-1 sweep.
--
-- WHAT IT DOES NOW (sigma-native, R25 config-only fleet):
--   Historical dates from mv_kpi_by_date (cheap, pre-aggregated), UNIONed with
--   any sigma_sales dates newer than the matview's max so a fresh push shows
--   on the picker without waiting for the nightly mv refresh. Store fleet from
--   stores WHERE is_active (R25), never a hard-coded list. Own
--   statement_timeout '15s' so it survives the authenticator role's 8s limit.
--
-- R22 verified on apply (PM, 2026-07-02): picker newest = 2026-07-01.
--
-- Rule lineage (R28): effective_from 2026-07-02, scope GENERAL. Supersedes the
--   push_log.snapshot_date body (retired 2026-07-02, superseded_by this).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_push_available_dates()
 RETURNS TABLE(snapshot_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  -- Historical dates from the pre-aggregated matview (cheap), topped up with any
  -- sigma_sales dates newer than the matview's last refresh so a fresh push shows
  -- on the picker without waiting for the 20:30 SAST mv refresh.
  WITH mv_dates AS (
    SELECT DISTINCT k.snapshot_date FROM public.mv_kpi_by_date k
  ),
  mv_max AS (SELECT COALESCE(MAX(snapshot_date),'2000-01-01'::date) mx FROM mv_dates),
  fresh AS (
    SELECT DISTINCT s.sale_date AS snapshot_date
    FROM public.sigma_sales s
    JOIN public.stores st ON st.store_code = s.store_code AND st.is_active
    CROSS JOIN mv_max m
    WHERE s.period_kind = 'T' AND s.txn_kind = 1
      AND s.sale_date > m.mx
  )
  SELECT snapshot_date FROM mv_dates
  UNION
  SELECT snapshot_date FROM fresh
  ORDER BY snapshot_date DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_push_available_dates() TO anon, authenticated, service_role;

-- RULE-BOOK section 8 function-change protocol: reload the PostgREST schema
-- cache after any apply (belt-and-braces; use the Dashboard Reload schema
-- button if the API still 404s -- CLEANUP-ENGINE-CANON section 13).
SELECT pg_notify('pgrst', 'reload schema');
