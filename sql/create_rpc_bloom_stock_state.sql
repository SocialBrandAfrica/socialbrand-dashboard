-- create_rpc_bloom_stock_state.sql
--
-- REPLACED FROM LIVE 2026-08-30 (ENG-115 class rule: a sql/ file that was not
-- generated from live can never be hash-gated, only replaced -- so this file is
-- regenerated wholesale via pg_get_functiondef, never hand-reconciled against
-- the previous version). Hash-gated against the database in the same pass.
--
-- Migration that shaped the current body:
--   eng112_repoint_stock_state_to_one_home_watermark (2026-08-30)
--
-- WHAT THIS RETURNS. Per-group (KVI / CORE / TAIL) line counts, stock at cost,
-- daily cost demand and stock-days, plus a TOTAL row carrying the two
-- populations and their gap.
--
-- ⚠️ TWO POPULATIONS, NEVER ONE (ORDERING-CANON §D6.1). weekly_demand_dept is the
-- ROUTE's sales scope -- the cycle DEPARTMENT set. weekly_demand_orderable is the
-- POOL. They are different numbers on purpose and the gap between them is the
-- point: measured 2026-08-30, summing the pool understates the route by 33.9%
-- (10116), 34.8% (80175) and 53.3-58.7% across the TOPS trio.
--
-- ENG-112, the reason this file moved:
--   weekly_demand_dept IS the basis-B route benchmark, and it was computed inline
--   here at a SECOND site on the retired CURRENT_DATE - 28 window. It now READS
--   the one home, rpc_bloom_route_benchmark (R33: the fix lives in L2 once for
--   everyone, never re-implemented per surface).
--
--   THE WHOLE WINDOW MOVED WITH IT, AND THAT IS THE TRAP IN A NAIVE REPOINT. This
--   function derives THREE numbers from ONE sales28 scan -- the dept total, the
--   pool total and the per-line daily cost. Moving only the dept total onto the
--   watermark would leave weekly_demand_gap subtracting a CURRENT_DATE-anchored
--   pool from a watermark-anchored dept: two different windows in one
--   subtraction. All three move together or none does.
--
--   R22 at ship, weekly_demand_dept before -> after, each now equal to the one
--   home to the cent: 10116 733,844.15 -> 767,786.01 · 80175 354,000.58 ->
--   370,518.10 · 21355 175,015.08 -> 177,301.49 · 80176 164,837.73 -> 167,575.46
--   · 80579 127,248.80 -> 129,505.70. THE MOVEMENT IS 100% ANCHOR: the one home
--   at the OLD anchor reproduced the displayed figure EXACTLY (delta R0.00 on all
--   five), so the dept-source difference between l2_stock_position.department_nr
--   and sigma_articles.department_nr is worth NOTHING.
--
--   CONSEQUENCE WORTH STATING: stock_days came DOWN on every desk (10116 CORE
--   36.3 -> 34.6, 80175 KVI 14.8 -> 14.0). The old anchor understated demand and
--   therefore OVERSTATED cover -- every desk read better covered than it was.
--
-- ⚠️ SECURITY DEFINER IS LOAD-BEARING, NOT BOILERPLATE. l2_soh_daily and
-- sigma_sales carry RLS with no anon read policy, so an invoker build returns a
-- confident permanent ZERO to the browser key (the ENG-068 / ENG-074 shape).
--
-- ⚠️ DIRECT desks keep their existing basis via the COALESCE fallback. §D6.1 rules
-- the cycle-dept basis for DC routes ONLY, so the one home returns NULL there and
-- nothing is invented for a population canon has not ruled. That fallback is
-- still CURRENT_DATE-anchored -- a NAMED residual, filed, not hidden.

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
  v_anchor    date;   -- ENG-112 / SSD6.1 clause 2: the ledger watermark, never CURRENT_DATE
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

  -- SSD6.1 clause 2: demonstrated demand can only be demonstrated up to the
  -- watermark. CURRENT_DATE drags one or more unobserved days into a fixed
  -- 28-day divisor and deflates every figure below it.
  SELECT max(ss.sale_date) INTO v_anchor
    FROM sigma_sales ss
   WHERE ss.store_code = p_store_code AND ss.sale_date >= CURRENT_DATE - 90;
  IF v_anchor IS NULL THEN
    RAISE EXCEPTION 'rpc_bloom_stock_state(%): no ledger watermark in 90 days; refusing to anchor demonstrated demand on a calendar', p_store_code;
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
      AND ss.sale_date > v_anchor - 28 AND ss.sale_date <= v_anchor
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
      -- ENG-112: READ the one home, never a second inline implementation (R33).
      -- COALESCE keeps DIRECT desks on their existing basis, which canon has not ruled.
      COALESCE(
        (SELECT b.weekly_cost_demand
           FROM rpc_bloom_route_benchmark(p_store_code, p_route, v_anchor) b),
        COALESCE(SUM(s.cost28) FILTER (WHERE ds.product_code IS NOT NULL), 0) / 4.0
      ) AS dept_v,
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

-- Grants stated explicitly (R30 addendum). Read RPC: anon stays executable by
-- design; PUBLIC revoked so the default-privilege trap cannot re-open it.
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) TO anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_stock_state(text,text) TO service_role;
