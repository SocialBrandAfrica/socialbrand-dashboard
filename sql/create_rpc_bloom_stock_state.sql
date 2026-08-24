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


-- =============================================================================
-- 2026-08-24 (ENG-088, SB-CC-BLOOM-026 §13 Ruling B, CC).
-- READS THE L2 POPULATION-VERDICT FACT. Not the order cache, not the recipe.
--
-- WHY THE VERDICT AND NOT THE CACHE. This card is POOL-shaped, not SHEET-shaped:
-- it uses product_code, kvi_band, soh, pack_size, pack_cost and NO quantity, so
-- it was using rpc_bloom_order_recipe as an expensive way to enumerate a
-- population. The cache is the SHEET (428 lines at 80175). The verdict is the
-- POOL (12,623). Pointing this at the cache would have summarised "stock now"
-- over the ordered slice and called it the store. R33 one-fact shape: Bloom,
-- Forge, Pulse and Capital Tied all read the same population.
--
-- WHAT IT WAS DOING WRONG, measured 2026-08-24 00:3x SAST at 80175 DC_AMBIENT:
--   card showed   R201,348.82 over   428 lines  (the sheet)
--   real position R1,333,489.43 over 12,623 lines  (the pool)
-- 15% of the store's ambient stock, presented as the whole. And the breakdown is
-- the story: KVI R269,441 at 18.2 days, CORE R772,296 at 44.3 days, TAIL
-- R291,752 at 616.6 DAYS across 9,586 lines. Plus a R124,329/week demonstrated
-- demand gap across 1,490 lines selling in the ambient departments but off the
-- desk.
--
-- PERFORMANCE. It called the recipe live and PM measured it past 60s, abandoned;
-- its in-body SET LOCAL was decorative (ENG-096) so the real bound was the anon
-- role's 30s and the card could never legally finish.
--   after the verdict repoint          9,692 ms
--   after collapsing the sigma_sales   3,287 ms
-- Four separate 28-day sigma_sales passes (sales28, dept_demand,
-- orderable_demand, gap_lines) computed the same aggregate over the same window
-- with different filters. They are all DERIVABLE from one MATERIALIZED scan, so
-- the other three bought nothing. Same numbers by construction -- every leg
-- still reads cost_value over the same window with period_kind='T', txn_kind=1.
--
-- DC IS THE PREFERRED SUPPLIER, ALWAYS (Pieter ruling 2026-08-23). The verdict
-- holds ONE row per (store, product), ordered is_dc DESC, so a product carried
-- by both a DC and a direct desk is filed under DC.
--   DC desks     EXACT -- DC always wins the tie, the DC pool is complete.
--   DIRECT desks a line shared with DC is counted on DC, not here.
-- That is the RULE, not a shortfall, and the WARNING names the count so it is
-- surfaced rather than silent (R21 §5). CC first flagged it as a defect owing a
-- schema fix; Pieter's ruling settled that it is correct behaviour.
--
-- 🔴 RAISES LOUDLY if the verdict is unpopulated, rather than reporting a
-- confident EMPTY store (R22 §3, the ENG-068/074/100 shape, four firings).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_stock_state(p_store_code text, p_route text)
 RETURNS TABLE(group_name text, lines integer, selling_lines integer, stock_at_cost numeric, daily_cost_demand numeric, stock_days numeric, weekly_demand_dept numeric, weekly_demand_orderable numeric, weekly_demand_gap numeric, weekly_demand_gap_lines integer, weekly_demand_gap_label text, computed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_now       timestamptz := clock_timestamp();
  v_dept_nrs  smallint[];
  v_pool_rows int;
  v_overlap   int;
BEGIN
  IF p_route IS NULL THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk';
  END IF;

  IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN
    SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs
    FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
  ELSIF p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk';
  END IF;

  SELECT count(*) INTO v_pool_rows
    FROM l2_population_verdict v
   WHERE v.store_code = p_store_code AND v.route_key = p_route;

  IF v_pool_rows = 0 THEN
    RAISE EXCEPTION
      'Stock state unavailable: l2_population_verdict holds no rows for % %. It is refreshed on the nightly chain after refresh_l2_range_state. Failing loudly rather than reporting an empty store.',
      p_store_code, p_route;
  END IF;

  IF p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN
    SELECT count(*) INTO v_overlap
      FROM l2_population_verdict v
     WHERE v.store_code = p_store_code AND v.route_overlap;
    IF v_overlap > 0 THEN
      RAISE WARNING 'rpc_bloom_stock_state: % at % -- % line(s) shared with a DC desk are counted on DC, not here. That is the RULE, not a shortfall: DC is the preferred supplier always (Pieter ruling 2026-08-23), so a line DC supplies is ordered on DC and belongs on the DC desk.',
        p_route, p_store_code, v_overlap;
    END IF;
  END IF;

  RETURN QUERY
  WITH pool_run AS (
    SELECT v.product_code, v.kvi_band, v.soh,
           v.chosen_pack_size AS pack_size, v.chosen_pack_cost AS pack_cost
    FROM l2_population_verdict v
    WHERE v.store_code = p_store_code AND v.route_key = p_route
  ),
  -- ONE scan. Everything below derives from it.
  sales28 AS MATERIALIZED (
    SELECT ss.product_code, SUM(ss.cost_value) AS cost28
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
    GROUP BY ss.product_code
  ),
  dept_scope AS (
    SELECT sp.product_code
    FROM l2_stock_position sp
    WHERE sp.store_code = p_store_code
      AND ((p_route IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(v_dept_nrs)))
    UNION
    SELECT pr.product_code FROM pool_run pr WHERE p_route LIKE 'DIRECT\_%' ESCAPE '\'
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
    SELECT grp, count(*) AS lines,
           count(*) FILTER (WHERE is_selling) AS selling_lines,
           SUM(stock_cost) AS stock_at_cost,
           SUM(daily_cost) AS daily_cost_demand
    FROM lined GROUP BY grp
  ),
  -- all three derived from the ONE scan
  totals AS (
    SELECT
      COALESCE(SUM(s.cost28) FILTER (WHERE ds.product_code IS NOT NULL), 0) / 4.0 AS dept_v,
      COALESCE(SUM(s.cost28) FILTER (WHERE pr.product_code IS NOT NULL), 0) / 4.0 AS pool_v,
      count(DISTINCT s.product_code) FILTER (
        WHERE ds.product_code IS NOT NULL AND pr.product_code IS NULL AND s.cost28 > 0) AS gap_n
    FROM sales28 s
    LEFT JOIN dept_scope ds ON ds.product_code = s.product_code
    LEFT JOIN pool_run   pr ON pr.product_code = s.product_code
  )
  SELECT g.grp, g.lines::int, g.selling_lines::int,
    ROUND(g.stock_at_cost, 2), ROUND(g.daily_cost_demand, 2),
    (CASE WHEN g.daily_cost_demand > 0 THEN ROUND(g.stock_at_cost / g.daily_cost_demand, 1) ELSE NULL END),
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::integer, NULL::text, v_now
  FROM grouped g
  UNION ALL
  SELECT 'TOTAL', NULL, NULL, NULL, NULL, NULL,
    ROUND((SELECT dept_v FROM totals), 2), ROUND((SELECT pool_v FROM totals), 2),
    ROUND((SELECT dept_v - pool_v FROM totals), 2),
    (SELECT gap_n FROM totals)::int, 'no_active_dc_route', v_now
  ORDER BY 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) TO anon, authenticated;
