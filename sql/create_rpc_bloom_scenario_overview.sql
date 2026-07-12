-- =============================================================================
-- create_rpc_bloom_scenario_overview.sql
-- UX-003 (multiply amended, 2026-07-11 night) + CLEANUP-ENGINE-CANON SS14
-- v7 item 9 -- the landing board. ONE published call returns every
-- scenario's totals AND its visible breakdown for a desk, so the orders
-- landing page shows the full picture BEFORE anyone hits Generate.
--
-- R22 (Pieter, 22:0x/22:3x amendments): "every overview value AND
-- breakdown must equal what generating that scenario returns... the
-- overview is the same engine run aggregated, not an estimate." Built
-- literally that way -- this function calls rpc_bloom_order_recipe() once
-- per scenario (full/fitted/order_essentials/catch_up) and aggregates the
-- SAME rows the desk screen's own Generate button would show, never a
-- parallel/duplicate formula (R21).
--
-- ⭐ BUG-LOG ENG-018 (2026-07-11 night, Pieter ruled) -- THE YARDSTICK
-- RE-ANCHORED. The old flat-7-day DC-form reference (rpc_bloom_order_dc)
-- embedded a stale anchor->delivery lead on top of its own 7-day cover
-- AND geared promo lines up to 5x -- it was ITSELF the defect, not the
-- desk (desk standard R767,763 ties demonstrated 28d/4 weekly cost
-- demand to 0.07%, live-verified). Old DC-form reference RETIRED WITH
-- LINEAGE as this function's yardstick source (rpc_bloom_order_dc itself
-- stays live, still used by the DC tab -- only this function stops
-- reading it).
--
-- NEW yardstick formula, PM's exact wording: "pure tier-window demand x7
-- - clamp(soh,0), ungeared promo-flat, with demonstrated weekly demand
-- (28d/4) beside it." Built by reusing rpc_bloom_order_recipe itself
-- (R21, never a parallel formula) called with p_next_delivery=
-- p_delivery_date (forces v_lead=0, so the override branch's own
-- target_level - proj resolves to EXACTLY demand*7 - GREATEST(soh,0),
-- no anchor-lead inflation) and p_days_cover_override=7, summed on
-- normal_packs*pack_cost (never geared_packs, never promo_unit_cost --
-- "ungeared, promo-flat" per the ruling, same flat basis for every
-- line regardless of promo_active).
--
-- "demonstrated weekly demand (28d/4)" is a SEPARATE, independent
-- cross-check -- real trailing-28-day sales cost (sigma_sales.cost_value,
-- not the engine's own demand estimate at all) over the SAME resolved
-- route pool (product_code list from the 'full' scenario run), divided
-- by 4. Never used to compute yardstick_deviation_pct/yardstick_flag --
-- informational only, so PM/Pieter can eyeball the engine's tier-window
-- yardstick against a pure sales-history number with no engine logic in
-- either direction.
--
-- yardstick_flag only fires DEFECT_SIGNAL on the 'full' scenario (the
-- whole-pool-at-minimums run) -- fitted/essentials/catch_up are SUPPOSED
-- to diverge from the flat rule (canon: "the desk's whole purpose is to
-- better the flat rule by altering the MIX per scenario, not the
-- magnitude"), so their deviation is informational only, never flagged.
--
-- Breakdowns (Pieter 22:3x): by KVI band, by mode, by tier, count-first
-- line count, protected/trimmed counts (fit outcome) -- all read straight
-- off the same aggregated rows, jsonb per scenario.
--
-- BUG-LOG UX-004 (Pieter ruled 2026-07-12, "no conflict, ENG-014 stands --
-- fix UX-004 instead"): count_first_lines was counting count_first ACROSS
-- THE WHOLE POOL (every band_blocked row the recipe returns, ordered or
-- not) while `lines` only counts the ORDERED set (suggested_packs>0) --
-- the two numbers were never comparable and count_first could exceed
-- `lines` outright (4,826 vs 1,780 lines, live, before this fix).
-- `count_first_lines` now means the SAME thing `lines` does -- count_first
-- rows that ARE in the ordered set. The whole-pool figure rides separately
-- as `count_first_pool`, explicitly labelled, never blended with the
-- ordered count again.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_scenario_overview(text,date,date,text,numeric);

CREATE FUNCTION public.rpc_bloom_scenario_overview(
  p_store_code text,
  p_delivery_date date,
  p_next_delivery date DEFAULT NULL::date,
  p_route text DEFAULT NULL::text,
  p_yardstick_tolerance_pct numeric DEFAULT 20  -- DEMO_CALIBRATION, canon v7 item 9
)
RETURNS TABLE(
  scenario text,
  lines integer, promo_lines integer, count_first_lines integer,
  value_normal numeric, value_geared numeric,
  protected_lines integer, trimmed_lines integer,
  budget_amount numeric, budget_week_start date,
  yardstick_value numeric, yardstick_source text,
  yardstick_deviation_pct numeric, yardstick_flag text,
  by_kvi_band jsonb, by_mode jsonb, by_tier jsonb, by_kvi_band_lines jsonb,
  demonstrated_weekly_demand numeric,
  count_first_pool integer,
  computed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_yardstick numeric;
  v_yardstick_source text;
  v_now timestamptz := clock_timestamp();
BEGIN
  SET LOCAL statement_timeout = '45s';

  IF p_route IS NULL OR p_route NOT IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER') THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS or DIRECT_BEER';
  END IF;

  -- ENG-018 re-anchor: lead forced to 0 (p_next_delivery=p_delivery_date)
  -- so the override branch resolves to exactly demand*7 - clamp(soh,0),
  -- summed on normal_packs (never geared) -- same formula for every route,
  -- DIRECT_BEER no longer needs an apologetic proxy footnote.
  SELECT COALESCE(SUM(r.normal_packs * r.pack_cost), 0) INTO v_yardstick
  FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_delivery_date, NULL, NULL, 7, false, 15, 24, 25, 3.0, p_route) r;
  v_yardstick_source := 'tier-window demand x7 - clamp(soh,0), ungeared/promo-flat (BUG-LOG ENG-018 re-anchor, canon v7 item 9) -- rpc_bloom_order_recipe(lead=0, p_days_cover_override=7), summed on normal_packs*pack_cost';

  RETURN QUERY
  WITH full_run AS (
    SELECT * FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, NULL, NULL, false, 15,24,25,3.0, p_route)
  ),
  fitted_run AS (
    SELECT * FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, NULL, NULL, true, 15,24,25,3.0, p_route)
  ),
  ess_run AS (
    SELECT * FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, 'order_essentials', NULL, false, 15,24,25,3.0, p_route)
  ),
  cu_run AS (
    SELECT * FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, 'catch_up', NULL, false, 15,24,25,3.0, p_route)
  ),
  scenarios AS (
    SELECT 'full'::text AS scenario_key, r.* FROM full_run r
    UNION ALL SELECT 'fitted', r.* FROM fitted_run r
    UNION ALL SELECT 'order_essentials', r.* FROM ess_run r
    UNION ALL SELECT 'catch_up', r.* FROM cu_run r
  ),
  agg AS (
    SELECT
      s.scenario_key,
      count(*) FILTER (WHERE s.suggested_packs > 0) AS lines,
      count(*) FILTER (WHERE s.promo_active) AS promo_lines,
      -- UX-004: ordered-set count_first (matches `lines`' own population).
      count(*) FILTER (WHERE s.count_first AND s.suggested_packs > 0) AS count_first_lines,
      count(*) FILTER (WHERE s.count_first) AS count_first_pool,
      SUM(s.normal_packs * s.pack_cost) AS value_normal,
      SUM((CASE WHEN s.promo_active THEN s.geared_packs ELSE s.normal_packs END) * s.pack_cost) AS value_geared,
      count(*) FILTER (WHERE s.budget_fit_reason = 'protected_kvi') AS protected_lines,
      count(*) FILTER (WHERE s.budget_fit_reason IN ('trimmed_partial','trimmed_to_zero')) AS trimmed_lines,
      MAX(s.budget_week_start) AS budget_week_start
    FROM scenarios s
    GROUP BY s.scenario_key
  ),
  kvi_agg AS (
    SELECT s.scenario_key, COALESCE(s.kvi_band,'NONE') AS k, SUM(s.suggested_packs * s.pack_cost) AS v
    FROM scenarios s GROUP BY s.scenario_key, COALESCE(s.kvi_band,'NONE')
  ),
  kvi_json AS (SELECT scenario_key, jsonb_object_agg(k, ROUND(v,2)) AS by_kvi_band FROM kvi_agg GROUP BY scenario_key),
  -- Line-COUNT breakdown by KVI band (pie-chart source: percentage of
  -- ORDERED LINES, never rand value) -- only lines with suggested_packs>0
  -- count as "ordered", same population the pie chart labels "ordered".
  kvi_lines_agg AS (
    SELECT s.scenario_key, COALESCE(s.kvi_band,'NONE') AS k, count(*) AS c
    FROM scenarios s WHERE s.suggested_packs > 0
    GROUP BY s.scenario_key, COALESCE(s.kvi_band,'NONE')
  ),
  kvi_lines_json AS (SELECT scenario_key, jsonb_object_agg(k, c) AS by_kvi_band_lines FROM kvi_lines_agg GROUP BY scenario_key),
  mode_agg AS (
    SELECT s.scenario_key, COALESCE(s.mode,'NONE') AS m, SUM(s.suggested_packs * s.pack_cost) AS v
    FROM scenarios s GROUP BY s.scenario_key, COALESCE(s.mode,'NONE')
  ),
  mode_json AS (SELECT scenario_key, jsonb_object_agg(m, ROUND(v,2)) AS by_mode FROM mode_agg GROUP BY scenario_key),
  tier_agg AS (
    SELECT s.scenario_key, COALESCE(s.tier,'NONE') AS t, SUM(s.suggested_packs * s.pack_cost) AS v
    FROM scenarios s GROUP BY s.scenario_key, COALESCE(s.tier,'NONE')
  ),
  tier_json AS (SELECT scenario_key, jsonb_object_agg(t, ROUND(v,2)) AS by_tier FROM tier_agg GROUP BY scenario_key),
  -- ENG-018: demonstrated weekly demand, PURE sales history (sigma_sales.
  -- cost_value, never the engine's own demand estimate), trailing 28d/4,
  -- scoped to the SAME resolved route pool ('full' scenario's own
  -- product_code list) -- an independent cross-check beside the yardstick,
  -- never fed into yardstick_deviation_pct/yardstick_flag.
  full_products AS (SELECT DISTINCT product_code FROM full_run),
  demonstrated AS (
    SELECT COALESCE(SUM(ss.cost_value), 0) / 4.0 AS v
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
      AND ss.product_code IN (SELECT product_code FROM full_products)
  ),
  -- weekly budget: one lookup, same for every scenario at this desk/week.
  budget AS (
    SELECT COALESCE(obl.budget_amount,0) AS budget_amt
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code
      AND obl.route_key = (CASE WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER' ELSE 'DC' END)
      AND obl.grain = 'weekly'
      AND obl.year_month = (SELECT MAX(a.budget_week_start) FROM agg a)
  )
  SELECT
    a.scenario_key, a.lines::int, a.promo_lines::int, a.count_first_lines::int,
    ROUND(a.value_normal,2), ROUND(a.value_geared,2),
    a.protected_lines::int, a.trimmed_lines::int,
    COALESCE((SELECT budget_amt FROM budget), 0), a.budget_week_start,
    ROUND(v_yardstick,2), v_yardstick_source,
    (CASE WHEN v_yardstick > 0 THEN ROUND(((a.value_normal - v_yardstick) / v_yardstick) * 100, 1) ELSE NULL END),
    (CASE
       WHEN a.scenario_key <> 'full' THEN NULL
       WHEN v_yardstick > 0 AND ABS(((a.value_normal - v_yardstick) / v_yardstick) * 100) > p_yardstick_tolerance_pct
         THEN 'DEFECT_SIGNAL'
       ELSE NULL
     END),
    kj.by_kvi_band, mj.by_mode, tj.by_tier, klj.by_kvi_band_lines,
    ROUND((SELECT v FROM demonstrated), 2),
    a.count_first_pool::int,
    v_now
  FROM agg a
  LEFT JOIN kvi_json kj ON kj.scenario_key = a.scenario_key
  LEFT JOIN mode_json mj ON mj.scenario_key = a.scenario_key
  LEFT JOIN tier_json tj ON tj.scenario_key = a.scenario_key
  LEFT JOIN kvi_lines_json klj ON klj.scenario_key = a.scenario_key
  ORDER BY CASE a.scenario_key WHEN 'full' THEN 1 WHEN 'fitted' THEN 2 WHEN 'order_essentials' THEN 3 WHEN 'catch_up' THEN 4 END;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
