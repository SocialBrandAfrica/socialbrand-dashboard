-- =============================================================================
-- bt_010_store_overview.sql
-- SB-CC-BLOOM-008 item 8 -- BT PAGE STATS PER STORE OVERVIEW (Pieter ask,
-- 2026-07-12). rpc_bt_scorecard's own bucket/basket rows aggregate GP
-- across EVERY store in l2_bt_scope (10116 + 80175, currently) with no
-- per-store break -- Pieter wants the split.
--
-- R21: reuses l2_bt_monthly (bt_003) and l2_bt_baseline (bt_002) exactly
-- as rpc_bt_scorecard does -- same GP formula, same baseline join, just
-- grouped by store_code instead of collapsed across it. Never a parallel
-- GP calculation.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bt_store_overview(text);

CREATE FUNCTION public.rpc_bt_store_overview(p_month text)
RETURNS TABLE(
  store_code text,
  sales_ex numeric,
  gp numeric,
  gp_pct numeric,
  units numeric,
  baseline_gp numeric,
  delta_gp_rand numeric,
  delta_gp_pct numeric
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $$
WITH current_month AS (
  SELECT m.store_code, m.sales_ex, m.gp, m.units
  FROM public.l2_bt_monthly m
  WHERE m.month_start = (p_month || '-01')::date
),
agg AS (
  SELECT
    store_code,
    SUM(sales_ex) AS sales_ex,
    SUM(gp) AS gp,
    CASE WHEN SUM(sales_ex) > 0 THEN SUM(gp) / SUM(sales_ex) * 100 ELSE 0 END AS gp_pct,
    SUM(units) AS units
  FROM current_month
  GROUP BY store_code
),
baseline_agg AS (
  SELECT store_code, SUM(gp) AS baseline_gp
  FROM public.l2_bt_baseline
  GROUP BY store_code
)
SELECT
  a.store_code, a.sales_ex, a.gp, a.gp_pct, a.units,
  COALESCE(b.baseline_gp, 0) AS baseline_gp,
  a.gp - COALESCE(b.baseline_gp, 0) AS delta_gp_rand,
  CASE WHEN COALESCE(b.baseline_gp, 0) <> 0
       THEN (a.gp - b.baseline_gp) / ABS(b.baseline_gp) * 100
       ELSE NULL END AS delta_gp_pct
FROM agg a
LEFT JOIN baseline_agg b ON b.store_code = a.store_code
ORDER BY a.store_code;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_store_overview(text) TO anon, authenticated;
