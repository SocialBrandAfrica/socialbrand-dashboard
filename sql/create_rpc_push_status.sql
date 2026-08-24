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

-- =============================================================================
-- 2026-08-23 PERFORMANCE FIX (live body committed 2026-08-24 by CC, closing the
-- divergence). The file had sat July-dated while the live body carried the fix.
--
-- The L1 high-water mark is taken PER STORE as a correlated MAX so it can use
-- idx_sigma_sales_store_date (store_code, sale_date). The previous form
-- aggregated the ENTIRE sigma_sales table with a GROUP BY just to return five
-- rows, and was measured at 12.22s against this function's own 15s ceiling --
-- i.e. it was already inside its last 20% of headroom.
--
-- Same numbers, index-shaped access. The lesson generalises: an aggregate that
-- returns one row per store should be bounded per store, not computed over the
-- whole table and then grouped down.
--
-- NOTE ON THE ID: the body cites ENG-101/102. Those numbers are ALSO used by two
-- unrelated BUG-LOG rows filed 2026-08-24 (ENG-101 the Slow Movers 1,000-row
-- truncation, ENG-102 the life-gate split). The ids collide -- these code
-- comments were written without a BUG-LOG row, so the register was empty when
-- the later rows were filed. Flagged to PM; the register owns the numbering and
-- CC has not renumbered anything unilaterally.
-- =============================================================================

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
)
-- ENG-101/102 (2026-08-23): the L1 high-water mark is taken per store as a correlated MAX so it
-- uses idx_sigma_sales_store_date. The previous GROUP BY aggregated the entire table to return
-- five rows and was measured at 12.22s against this function's 15s ceiling.
SELECT st.store_code,
       (SELECT MAX(s.sale_date) FROM public.sigma_sales s WHERE s.store_code = st.store_code) AS snapshot_date,
       lp.completed_at
FROM public.stores st
LEFT JOIN latest_push lp ON lp.store_code = st.store_code
WHERE st.is_active;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_push_status() TO anon, authenticated;
