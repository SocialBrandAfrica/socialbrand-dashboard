-- =============================================================================
-- refresh_order_budget_ledger() -- SB-CC-BLOOM-003 Ship 1.
-- Nightly refresh of sales_actual + landed_amount per store/route/month, from
-- the same live tables the rest of the engine reads (R22, no separate truth).
-- budget_amount is the seeded plan (SB-AP-REPAY-001), never overwritten here.
-- committed_amount is intentionally NOT computed here -- Ship 1 has no order-
-- submission persistence yet (Bloom v0's rpc_bloom_submit is aspirational, not
-- built); the Desk view's "committed" figure is a live client-side sum of the
-- on-screen proposal, not a stored fact. Documented gap, not a silent one.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_order_budget_ledger()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_updated int;
  v_result jsonb := '{}'::jsonb;
BEGIN
  -- sales_actual: route-scoped sales (product's current merch_group membership
  -- matches the route's config), month-to-date, per store.
  WITH route_sales AS (
    SELECT rc.store_code, rc.route_key, date_trunc('month', s.sale_date)::date AS year_month,
           SUM(s.sales_incl_vat) AS total_sales
    FROM public.bloom_route_config rc
    JOIN public.sigma_articles a ON a.store_code = rc.store_code AND a.merch_group_nr = ANY(rc.merch_group_nrs)
    JOIN public.sigma_sales s ON s.store_code = a.store_code AND s.product_code = a.product_code
      AND s.period_kind = 'T' AND s.txn_kind = 1
    GROUP BY rc.store_code, rc.route_key, date_trunc('month', s.sale_date)::date
  )
  UPDATE public.order_budget_ledger l
  SET sales_actual = rs.total_sales, updated_at = now()
  FROM route_sales rs
  WHERE l.store_code = rs.store_code AND l.route_key = rs.route_key AND l.year_month = rs.year_month;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_result := v_result || jsonb_build_object('sales_actual_rows_updated', v_updated);

  -- landed_amount: GRV receipts (R/W, at cost) against a qualifying non-DC
  -- supplier link for a route product, month-to-date. Origin read from the
  -- movement's own supplier_nr + the article's current merch_group -- never a
  -- supplier name.
  WITH route_landed AS (
    SELECT rc.store_code, rc.route_key, date_trunc('month', m.movement_date)::date AS year_month,
           SUM(m.cost_value) AS total_landed
    FROM public.bloom_route_config rc
    JOIN public.sigma_articles a ON a.store_code = rc.store_code AND a.merch_group_nr = ANY(rc.merch_group_nrs)
    JOIN public.sigma_movements m ON m.store_code = a.store_code AND m.product_code = a.product_code
      AND m.movement_type IN ('R','W') AND m.supplier_nr IS NOT NULL
    JOIN public.sigma_supplier_master sm ON sm.store_code = m.store_code AND sm.supplier_nr = m.supplier_nr
      AND NOT (sm.supplier_type = ANY(rc.excluded_supplier_types))
    GROUP BY rc.store_code, rc.route_key, date_trunc('month', m.movement_date)::date
  )
  UPDATE public.order_budget_ledger l
  SET landed_amount = COALESCE(rl.total_landed, 0), updated_at = now()
  FROM route_landed rl
  WHERE l.store_code = rl.store_code AND l.route_key = rl.route_key AND l.year_month = rl.year_month;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_result := v_result || jsonb_build_object('landed_amount_rows_updated', v_updated);

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_order_budget_ledger() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_order_budget_ledger() TO authenticated;
