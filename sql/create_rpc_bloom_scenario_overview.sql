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
-- Canon v7 item 9 -- THE 7-DAY YARDSTICK GUARDRAIL: "the retired flat-7-
-- day DC calculation stays alive as the permanent REFERENCE LINE... the
-- old formula unchanged." Reused literally: for DC_AMBIENT/DC_TOPS this
-- calls the UNCHANGED, still-live rpc_bloom_order_dc(p_days_cover=>7) and
-- sums suggested_packs*pack_cost -- the exact retired flat-7-day DC calc,
-- not a re-derivation. DIRECT_BEER never had a DC-form equivalent, so its
-- yardstick uses this same recipe RPC with a flat 7-day override
-- (p_days_cover_override=>7) as the closest available proxy -- flagged
-- honestly in yardstick_source, not silently treated as identical.
-- yardstick_flag only fires DEFECT_SIGNAL on the 'full' scenario (the
-- whole-pool-at-minimums run) -- fitted/essentials/catch_up are SUPPOSED
-- to diverge from the flat rule (canon: "the desk's whole purpose is to
-- better the flat rule by altering the MIX per scenario, not the
-- magnitude"), so their deviation is informational only, never flagged.
--
-- Breakdowns (Pieter 22:3x): by KVI band, by mode, by tier, count-first
-- line count, protected/trimmed counts (fit outcome) -- all read straight
-- off the same aggregated rows, jsonb per scenario.
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

  IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN
    SELECT COALESCE(SUM(d.suggested_packs * d.pack_cost), 0) INTO v_yardstick
    FROM rpc_bloom_order_dc(p_store_code, p_delivery_date, COALESCE(p_next_delivery, p_delivery_date + 7), NULL, NULL, 7) d;
    v_yardstick_source := 'rpc_bloom_order_dc(p_days_cover=7), the retired flat-7-day DC calc, unchanged';
  ELSE
    SELECT COALESCE(SUM(r.suggested_packs * r.pack_cost), 0) INTO v_yardstick
    FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, NULL, 7, false, 15, 24, 25, 3.0, p_route) r;
    v_yardstick_source := 'rpc_bloom_order_recipe(p_days_cover_override=7) -- DIRECT_BEER has no DC-form equivalent, this is the closest proxy, flagged not silently treated as identical';
  END IF;

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
      count(*) FILTER (WHERE s.count_first) AS count_first_lines,
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
