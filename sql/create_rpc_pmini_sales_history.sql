-- ============================================================================
-- rpc_pmini_sales_history -- daily qty per EAN over a date range
-- ============================================================================
-- R30 repair (2026-07-06). Companion to rpc_pmini_snapshot. Replaces the
-- dev-corner/lines/route.js reads of daily_snapshots for the 42-day weekly
-- buckets and the last-year seasonal-factor window -- both frozen at
-- 2026-06-28 in the old source. sigma_sales is the exact, always-current
-- Sigma ledger (period_kind='T' AND txn_kind=1 = customer sales only, R21).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_pmini_sales_history(p_store_code text, p_eans text[], p_from date, p_to date)
 RETURNS TABLE(ean text, sale_date date, qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  SELECT b.ean, ss.sale_date, SUM(ss.qty) AS qty
  FROM public.v_ean_bridge b
  JOIN public.sigma_sales ss ON ss.store_code = b.store_code AND ss.product_code = b.product_code
  WHERE b.store_code = p_store_code AND b.ean = ANY(p_eans)
    AND ss.period_kind = 'T' AND ss.txn_kind = 1
    AND ss.sale_date BETWEEN p_from AND p_to
  GROUP BY b.ean, ss.sale_date
  ORDER BY b.ean, ss.sale_date;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_pmini_sales_history(text,text[],date,date) TO anon, authenticated;
