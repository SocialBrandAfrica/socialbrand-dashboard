-- ============================================================================
-- rpc_push_status -- Last Push strip source (per-store data freshness)
-- ============================================================================
-- CANONICAL create file (SB-CC-RECONCILE-001 discipline: one create_<object>.sql
-- per live object). Faithful to the LIVE definition.
--
-- RETIRE-003 / CC-BRIEF-DASH-FINAL-001 item 0 (2026-07-05):
--   Applied LIVE by PM 2026-07-05 (migration retire003_rpc_push_status_sigma_native),
--   pulled into the repo by CC same day. Live was ahead of main on this object
--   (same pattern as the 07-02 picker/freshness pair).
--
-- WHY: the prior definition filtered push_log on snapshot_date IS NOT NULL,
--   which only the retired PRSSALE nightly rows carry (frozen 28 Jun) -- the
--   Last Push strip showed "6d ago" x5 forever. Sigma-native now:
--     snapshot_date  = MAX(sigma_sales.sale_date) per store (true data freshness)
--     completed_at   = latest SUCCESS push_type='l1_table' sigma_sales push
--     fleet          = stores WHERE is_active (R25, no hardcoded store list)
--     statement_timeout '15s' local to the fn -- survives the authenticator 8s cap
--   Same contract (store_code, snapshot_date, completed_at) -- zero frontend edits.
--
-- R22 verified live 2026-07-05: 4 stores green "18h ago", TOPS Dice amber
--   "4d ago" (honest -- extractor dark since 30 Jun, server-side, on Pieter).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_push_status()
 RETURNS TABLE(store_code text, snapshot_date date, completed_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
WITH latest_push AS (
  SELECT DISTINCT ON (pl.store_code)
         pl.store_code, pl.completed_at
  FROM public.push_log pl
  WHERE pl.status = 'SUCCESS'
    AND pl.push_type = 'l1_table'
    AND pl.table_name = 'sigma_sales'
    AND pl.rows_pushed > 0
  ORDER BY pl.store_code, pl.completed_at DESC
),
l1 AS (
  SELECT s.store_code, MAX(s.sale_date) AS l1_max
  FROM public.sigma_sales s
  GROUP BY s.store_code
)
SELECT st.store_code, l1.l1_max AS snapshot_date, lp.completed_at
FROM public.stores st
LEFT JOIN latest_push lp ON lp.store_code = st.store_code
LEFT JOIN l1 ON l1.store_code = st.store_code
WHERE st.is_active;
$function$;

-- Reload the PostgREST schema cache (RULE-BOOK section 8; belt-and-braces --
-- verify live and use the Dashboard Reload schema button if the API still 404s).
SELECT pg_notify('pgrst', 'reload schema');
