-- =============================================================================
-- rpc_bloom_direct_beer_flags -- SB-CC-BLOOM-003 Ship 1.
-- "Raise issues, never bake them in" (brief §2). Lines in the beer/cider route
-- that clearly sell (real till history) but the engine's own l2_item_classification
-- has routed OUT of NORMAL (so rpc_bloom_order_direct_beer's pool correctly
-- excludes them) -- most commonly record_stock_qty=0 (Sigma non-deplete flag),
-- the exact "BLACK LABEL CASE" pattern named in SB-ORD-DESK-001 (R2.03M LY H2,
-- 11,120 units/year, but Sigma is not tracking its stock at all). These need a
-- FLOOR fix in Sigma (flip Record Stock Qty back on) before they can re-enter
-- the order pool -- never an engine override, per R21.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_direct_beer_flags(p_store_code text)
RETURNS TABLE(
  product_code bigint, description text, merch_group_name text, class text, reason text,
  q364 numeric, soh numeric, record_stock_qty smallint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET statement_timeout = '15s'
AS $function$
  WITH cfg AS (
    SELECT rc.merch_group_nrs FROM bloom_route_config rc
    WHERE rc.store_code = p_store_code AND rc.route_key = 'DIRECT_BEER'
  ),
  sales364 AS (
    SELECT s.product_code, SUM(s.qty) AS q364
    FROM sigma_sales s
    WHERE s.store_code = p_store_code AND s.period_kind='T' AND s.txn_kind=1
      AND s.sale_date > CURRENT_DATE - 364
    GROUP BY s.product_code
  )
  SELECT a.product_code, a.description, mg.name, ic.class, ic.reason,
    COALESCE(s.q364,0), COALESCE(so.soh,0), a.record_stock_qty
  FROM sigma_articles a
  CROSS JOIN cfg
  LEFT JOIN sigma_subdepts mg ON mg.store_code=a.store_code AND mg.merch_group_nr=a.merch_group_nr
  LEFT JOIN l2_item_classification ic ON ic.store_code=a.store_code AND ic.product_code=a.product_code
  LEFT JOIN sales364 s ON s.product_code = a.product_code
  LEFT JOIN l2_soh_daily so ON so.store_code=a.store_code AND so.product_code=a.product_code
    AND so.snapshot_date = (SELECT MAX(snapshot_date) FROM l2_soh_daily WHERE store_code=a.store_code)
  WHERE a.store_code = p_store_code AND a.merch_group_nr = ANY(cfg.merch_group_nrs)
    AND COALESCE(ic.class,'') <> 'NORMAL' AND COALESCE(s.q364,0) > 0
  ORDER BY COALESCE(s.q364,0) DESC;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_direct_beer_flags(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_direct_beer_flags(text) TO anon, authenticated;
