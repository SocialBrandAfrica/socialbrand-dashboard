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

-- =============================================================================
-- 2026-08-23 PERFORMANCE FIX (live body committed 2026-08-24 by CC, closing the
-- divergence). The file had sat July-dated while the live body carried the fix.
--
-- The freshness top-up is driven PER STORE so it can use
-- idx_sigma_sales_store_date (store_code, sale_date). A bare `sale_date > mx`
-- with no store leg CANNOT use that index: it full-scanned sigma_sales, hit the
-- 15s ceiling, and left the date picker EMPTY. Same dates, same result, 178ms.
--
-- 🔴 The failure mode is the one that matters here: an empty picker does not
-- look like a timeout, it looks like there is no data. A blank standing in for a
-- failure again (R22 §3) -- the same shape as ENG-097's dead order screen and
-- the Slow Movers `.catch(() => [])`.
--
-- NOTE ON THE ID: the body cites ENG-101, which is ALSO used by an unrelated
-- BUG-LOG row filed 2026-08-24 (the Slow Movers 1,000-row truncation). The ids
-- collide; flagged to PM, not renumbered here.
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
  -- ENG-101 (2026-08-23): the top-up is driven PER STORE so it can use
  -- idx_sigma_sales_store_date (store_code, sale_date). A bare `sale_date > mx` with no
  -- store leg cannot use that index and full-scanned sigma_sales, timing out at 15s and
  -- leaving the picker empty. Same dates, same result, 178ms.
  WITH mv_dates AS (
    SELECT DISTINCT k.snapshot_date FROM public.mv_kpi_by_date k
  ),
  mv_max AS (SELECT COALESCE(MAX(snapshot_date),'2000-01-01'::date) mx FROM mv_dates),
  fresh AS (
    SELECT DISTINCT f.sale_date AS snapshot_date
    FROM public.stores st
    CROSS JOIN mv_max m
    CROSS JOIN LATERAL (
      SELECT DISTINCT s.sale_date
      FROM public.sigma_sales s
      WHERE s.store_code = st.store_code
        AND s.sale_date > m.mx
        AND s.period_kind = 'T'
        AND s.txn_kind = 1
    ) f
    WHERE st.is_active
  )
  SELECT snapshot_date FROM mv_dates
  UNION
  SELECT snapshot_date FROM fresh
  ORDER BY snapshot_date DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_push_available_dates() TO anon, authenticated;
