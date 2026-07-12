-- =============================================================================
-- create_rpc_bloom_stock_state.sql
-- SB-CC-BLOOM-008 item 7 -- THE STOCK-STATE INSTRUMENT (Pieter ruling
-- 2026-07-12, wants it ON SCREEN Monday). Read-only, zero formula risk --
-- FORMULA FREEZE holds (Pieter/PM ruling, same night): this object reads
-- current SOH and raw sales history, it never touches
-- rpc_bloom_order_recipe's quantity logic, gearing legs or presets.
--
-- "Where does the store end in the 3 categories" (Pieter): per group
-- KVI (KVI_CRITICAL+KVI_IMPORTANT) / Core (STANDARD+CONSUMABLE_CARVE) /
-- Tail (LONG_TAIL) -- lines, stock at cost, daily cost demand (28d sales
-- cost / 28, PURE history, sigma_sales.cost_value, never the engine's own
-- demand estimate -- same discipline as ENG-018's demonstrated-demand
-- cross-check), stock-days = stock_at_cost / daily_cost_demand.
--
-- Population = the recipe's OWN resolved orderable pool (active Z-link
-- required) -- verified against PM's reference figures at 10116/
-- DC_AMBIENT: 178+4,981+7,456 = 12,615, matching the recipe's own pool
-- size (12,617, small drift = live SOH/sales movement between PM's calc
-- and this build). Built by reusing rpc_bloom_order_recipe itself (R21,
-- never a parallel pool-resolution formula) -- calls it once with a
-- neutral p_days_cover_override so soh/kvi_band/pack_cost are read off
-- its own resolved rows, never re-derived.
--
-- A 4th synthetic row (group_name='TOTAL') carries the SEPARATE dept-wide
-- demand comparison PM ruled on the same night: the whole dept-cycle set
-- (every sigma_articles-backed line in the route's own dept/merch scope,
-- Z-link or not) vs the orderable pool's own weekly demand, gap labelled
-- `no_active_dc_route` -- the ENG-008 floor debt expressed in demand rand
-- (a store can never fund the sales sitting on a dead/missing Z-link).
-- This DOES need its own dept-scope query (department_nr/merch_group_nr,
-- no Z-link join) -- a plain scope lookup, not a derived formula, so R21
-- doesn't apply the same way it does to the recipe's own demand/band math.
--
-- Days-after per scenario is NOT computed here -- it recomputes live,
-- client-side, from this call's per-group daily_cost_demand plus the
-- desk's own in-memory qty state as the buyer edits (canon: "recomputing
-- live as quantities edit"), never a server round-trip per keystroke.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_stock_state(text,text);

CREATE FUNCTION public.rpc_bloom_stock_state(
  p_store_code text,
  p_route text
)
RETURNS TABLE(
  group_name text,
  lines integer,
  selling_lines integer,
  stock_at_cost numeric,
  daily_cost_demand numeric,
  stock_days numeric,
  weekly_demand_dept numeric,
  weekly_demand_orderable numeric,
  weekly_demand_gap numeric,
  weekly_demand_gap_lines integer,
  weekly_demand_gap_label text,
  computed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_delivery date := CURRENT_DATE + 1;
  v_dept_nrs smallint[];
  v_merch_nrs smallint[];
BEGIN
  SET LOCAL statement_timeout = '30s';

  IF p_route IS NULL OR p_route NOT IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER') THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS or DIRECT_BEER';
  END IF;

  IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN
    SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs
    FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
  ELSE
    SELECT rc.merch_group_nrs INTO v_merch_nrs
    FROM bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = 'DIRECT_BEER';
  END IF;

  RETURN QUERY
  WITH pool_run AS (
    SELECT r.product_code, r.kvi_band, r.soh, r.pack_size, r.pack_cost
    FROM rpc_bloom_order_recipe(p_store_code, v_delivery, v_delivery, NULL, NULL, 7, false, 15, 24, 25, 3.0, p_route) r
  ),
  sales28 AS (
    SELECT ss.product_code, SUM(ss.cost_value) AS cost28
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
    GROUP BY ss.product_code
  ),
  lined AS (
    SELECT
      pr.product_code,
      (CASE
         WHEN pr.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') THEN 'KVI'
         WHEN pr.kvi_band = 'LONG_TAIL' THEN 'TAIL'
         ELSE 'CORE'
       END) AS grp,
      GREATEST(pr.soh, 0) * (pr.pack_cost / NULLIF(pr.pack_size, 0)) AS stock_cost,
      COALESCE(s28.cost28, 0) / 28.0 AS daily_cost,
      (COALESCE(s28.cost28, 0) > 0) AS is_selling
    FROM pool_run pr
    LEFT JOIN sales28 s28 ON s28.product_code = pr.product_code
  ),
  grouped AS (
    SELECT
      grp,
      count(*) AS lines,
      count(*) FILTER (WHERE is_selling) AS selling_lines,
      SUM(stock_cost) AS stock_at_cost,
      SUM(daily_cost) AS daily_cost_demand
    FROM lined
    GROUP BY grp
  ),
  -- dept-wide scope (no Z-link requirement) -- separate from the recipe's
  -- own orderable pool, deliberately, to expose the no_active_dc_route gap.
  dept_scope AS (
    SELECT sp.product_code
    FROM l2_stock_position sp
    WHERE sp.store_code = p_store_code
      AND (
        (p_route IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(v_dept_nrs))
        OR (p_route = 'DIRECT_BEER' AND sp.merch_group_nr = ANY(v_merch_nrs))
      )
  ),
  dept_demand AS (
    SELECT COALESCE(SUM(ss.cost_value), 0) / 4.0 AS v
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
      AND ss.product_code IN (SELECT product_code FROM dept_scope)
  ),
  orderable_demand AS (
    SELECT COALESCE(SUM(ss.cost_value), 0) / 4.0 AS v
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
      AND ss.product_code IN (SELECT product_code FROM pool_run)
  ),
  gap_lines AS (
    SELECT count(DISTINCT ss.product_code) AS c
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
      AND ss.cost_value > 0
      AND ss.product_code IN (SELECT product_code FROM dept_scope)
      AND ss.product_code NOT IN (SELECT product_code FROM pool_run)
  )
  SELECT g.grp, g.lines::int, g.selling_lines::int,
    ROUND(g.stock_at_cost, 2), ROUND(g.daily_cost_demand, 2),
    (CASE WHEN g.daily_cost_demand > 0 THEN ROUND(g.stock_at_cost / g.daily_cost_demand, 1) ELSE NULL END),
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::integer, NULL::text, v_now
  FROM grouped g
  UNION ALL
  SELECT 'TOTAL', NULL, NULL, NULL, NULL, NULL,
    ROUND((SELECT v FROM dept_demand), 2), ROUND((SELECT v FROM orderable_demand), 2),
    ROUND((SELECT v FROM dept_demand) - (SELECT v FROM orderable_demand), 2),
    (SELECT c FROM gap_lines)::int, 'no_active_dc_route', v_now
  ORDER BY 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_stock_state(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
