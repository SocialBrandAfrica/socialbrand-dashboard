-- =============================================================================
-- create_rpc_layer_freshness.sql
-- SB-CC-RETIRE-003 item 1. Deployed LIVE by PM 2026-07-02 via Supabase MCP
--   migration retire003_repoint_picker_and_freshness_rpcs. Canonical source,
--   pulled from the live definition (pg_get_functiondef) 2026-07-02 -- live was
--   ahead of main on this object.
-- =============================================================================
-- WHY (the 1 July dashboard incident):
--   The old body took l1_max from daily_snapshots, which froze at 28 Jun when
--   the PRSSALE push retired (RETIRE-001). The dashboard "last pushed" strip
--   therefore showed a stale L1 even while the sigma-native pipeline was green.
--
-- WHAT IT DOES NOW (sigma-native, R25 config-only fleet):
--   l1_max = MAX(sale_date) landed in sigma_sales (period_kind='T', txn_kind=1)
--   per store; l2_refreshed from l2_kpi_daily.positioned_at; feed verdict from
--   the latest push_log feed_check row. Store fleet from stores WHERE is_active
--   (R25). Own statement_timeout '15s' so it survives the authenticator role's
--   8s limit.
--
-- R22 verified on apply (PM, 2026-07-02): strip L1 -> 1 Jul x4, Dice flagged
--   30 Jun (true extractor gap on srsdelareyt2svr, not a display fault).
--
-- Rule lineage (R28): effective_from 2026-07-02, scope GENERAL. Supersedes the
--   daily_snapshots l1_max body (retired 2026-07-02, superseded_by this).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_layer_freshness()
 RETURNS TABLE(store_code text, l1_max date, l2_sales_max date, l2_refreshed date, feed_status text, feed_detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  WITH st AS (SELECT s.store_code AS sc FROM public.stores s WHERE s.is_active),
  l1 AS (  -- L1 mirror data currency: latest sale_date landed in sigma_sales (was daily_snapshots, frozen 06-28)
    SELECT s.store_code AS sc, MAX(s.sale_date) AS mx
    FROM public.sigma_sales s
    WHERE s.period_kind = 'T' AND s.txn_kind = 1
    GROUP BY 1
  ),
  kpi AS (SELECT k.store_code AS sc, k.positioned_at FROM public.l2_kpi_daily k),
  fc AS (
    SELECT DISTINCT ON (p.store_code) p.store_code AS sc, p.status, p.error_message
    FROM public.push_log p
    WHERE p.push_type = 'feed_check'
    ORDER BY p.store_code, p.started_at DESC
  )
  SELECT st.sc, l1.mx, l1.mx, kpi.positioned_at,
         COALESCE(fc.status, 'UNKNOWN'), fc.error_message
  FROM st
  LEFT JOIN l1  ON l1.sc  = st.sc
  LEFT JOIN kpi ON kpi.sc = st.sc
  LEFT JOIN fc  ON fc.sc  = st.sc
  ORDER BY st.sc;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_layer_freshness() TO anon, authenticated, service_role;

-- RULE-BOOK section 8 function-change protocol: reload the PostgREST schema
-- cache after any apply (belt-and-braces; use the Dashboard Reload schema
-- button if the API still 404s -- CLEANUP-ENGINE-CANON section 13).
SELECT pg_notify('pgrst', 'reload schema');
