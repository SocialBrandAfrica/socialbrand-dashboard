-- create_rpc_bloom_scenario_overview.sql
--
-- REPLACED FROM LIVE 2026-08-30 (ENG-115 class rule: a sql/ file that was not
-- generated from live can never be hash-gated, only replaced). Hash-gated against
-- the database in the same pass.
--
-- ⚠️ THIS FILE SUPERSEDES A KNOWN-DANGEROUS PREDECESSOR. The previous version was
-- stamped DO NOT APPLY under ENG-115: it named the RETIRED FIVE-ARG signature in
-- its DROP/REVOKE/GRANT against a live SEVEN-ARG function, so applying it dropped
-- nothing and CREATED AN AMBIGUOUS OVERLOAD -- the same class as the
-- refresh_bloom_order_cache_all near-miss that would have killed the nightly
-- build. This version carries no DROP and its grants name the real signature.
--
-- Migration that shaped the current body:
--   eng112_repoint_scenario_overview_to_one_home (2026-08-30)
--
-- WHAT IT DOES. One row per scenario (full / fitted / order_essentials /
-- catch_up), each calling rpc_bloom_order_recipe once and aggregating -- R22 by
-- construction, never a parallel formula.
--
-- ENG-112 + §D6.1 PART 1, both closed in one line. The `demonstrated` CTE carried
-- BOTH defects at once:
--   (1) CIRCULARITY (ENG-104): the benchmark was computed over `full_products`,
--       i.e. THE ORDER'S OWN ROWS, so it contracted with the thing it measured
--       and the fitted DEFECT_SIGNAL could never catch an order that was too
--       small. Measured worth 2.9x at 80175.
--   (2) DRIFT (ENG-112): CURRENT_DATE - 28, so a cached order judged tomorrow was
--       judged against a different window than it was built with.
-- Reading rpc_bloom_route_benchmark (the one home) fixes both, because it is
-- dept-scoped (independent of the order) AND watermark-anchored.
--
-- R22 at ship, all five DC desks: demonstrated_weekly_demand equals the one home
-- to the cent, AND THE CIRCULARITY IS PROVEN DEAD -- requesting one scenario
-- instead of four returns an IDENTICAL benchmark (narrow minus wide = 0.00 x5),
-- where the old full_products basis would have shrunk it.
--
-- ⚠️ NAMED RESIDUAL, DELIBERATE AND ASSERTED. Exactly ONE CURRENT_DATE - 28
-- survives: the DIRECT-desk fallback. §D6.1 rules the cycle-dept basis for DC
-- routes only, so a direct desk keeps its existing (still circular, still
-- CURRENT_DATE) basis rather than inheriting a basis nobody churned. The
-- migration asserted it is exactly one -- zero would mean the fallback broke, two
-- would mean a site was missed. PM has ruled this NOT acceptable standing: it is
-- filed §0i PROSE and the DEFECT_SIGNAL stays HELD on direct desks the same as DC.
--
-- ⚠️ THE CARD IS HELD. §D6.1 has three conditions; parts 1 and 2 are now enacted,
-- and part 3 -- order_budget_ledger.cash_constrained -- is false on every row
-- (ENG-111). Re-enabling on parts 1 and 2 alone would trade a gate that never
-- fires for one that always fires, which ENG-041 already proved is the same
-- defect wearing opposite clothes.
--
-- ⚠️ SECURITY DEFINER WITH NO `SET search_path` -- one of the 75 of 117 unpinned
-- SECURITY DEFINER functions measured under ENG-145 item 2. NOT fixed here: the
-- security second-half is PAUSED under Pieter's 2026-08-27 ordering-only re-cut.
-- Named so the next seat does not read its absence as intentional.
--
-- ⚠️ The in-body `SET LOCAL statement_timeout = '45s'` is DECORATIVE (DB-SCHEMA
-- Architecture Rules, proven by probe): the bound is armed by the caller or the
-- role. As `anon` this function actually gets the role's 30s.

CREATE OR REPLACE FUNCTION public.rpc_bloom_scenario_overview(p_store_code text, p_delivery_date date, p_next_delivery date DEFAULT NULL::date, p_route text DEFAULT NULL::text, p_yardstick_tolerance_pct numeric DEFAULT 20, p_scenarios text[] DEFAULT NULL::text[], p_include_yardstick boolean DEFAULT true)
 RETURNS TABLE(scenario text, lines integer, promo_lines integer, count_first_lines integer, value_normal numeric, value_geared numeric, protected_lines integer, trimmed_lines integer, budget_amount numeric, budget_week_start date, yardstick_value numeric, yardstick_source text, yardstick_deviation_pct numeric, yardstick_flag text, yardstick_reason text, by_kvi_band jsonb, by_mode jsonb, by_tier jsonb, by_kvi_band_lines jsonb, demonstrated_weekly_demand numeric, count_first_pool integer, min_order_value numeric, min_shortfall numeric, min_reason text, computed_at timestamp with time zone, value_promo_lines numeric, value_nonpromo_lines numeric, promo_share_pct numeric, promo_lines_pool integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_yardstick numeric;
  v_yardstick_source text;
  v_now timestamptz := clock_timestamp();
  v_bad text;
BEGIN
  SET LOCAL statement_timeout = '45s';

  IF p_route IS NULL OR (p_route NOT IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER') AND p_route NOT LIKE 'DIRECT\_%' ESCAPE '\') THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk';
  END IF;

  -- No silent skips (canon 8.6 guard 4): an unknown scenario name is an error,
  -- never an empty result the caller reads as "this scenario has nothing".
  IF p_scenarios IS NOT NULL THEN
    IF array_length(p_scenarios,1) IS NULL THEN
      RAISE EXCEPTION 'p_scenarios is empty: pass NULL for all scenarios, never an empty array';
    END IF;
    SELECT string_agg(s,', ') INTO v_bad FROM unnest(p_scenarios) s
     WHERE s NOT IN ('full','fitted','order_essentials','catch_up');
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'unknown scenario(s): %. Valid: full, fitted, order_essentials, catch_up', v_bad;
    END IF;
  END IF;

  IF p_include_yardstick THEN
    SELECT COALESCE(SUM(r.normal_packs * r.pack_cost), 0) INTO v_yardstick
    FROM rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_delivery_date, NULL, NULL, 7, false, 15, 24, 25, 3.0, p_route) r;
    v_yardstick_source := 'tier-window demand x7 - clamp(soh,0), ungeared/promo-flat (BUG-LOG ENG-018 re-anchor, canon v7 item 9) -- rpc_bloom_order_recipe(lead=0, p_days_cover_override=7), summed on normal_packs*pack_cost';
  ELSE
    v_yardstick := NULL;
    v_yardstick_source := NULL;
  END IF;

  RETURN QUERY
  WITH full_run AS (
    SELECT r.* FROM (SELECT 1 WHERE p_scenarios IS NULL OR 'full' = ANY(p_scenarios)) g
    CROSS JOIN LATERAL rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, NULL, NULL, false, 15,24,25,3.0, p_route) r
  ),
  fitted_run AS (
    SELECT r.* FROM (SELECT 1 WHERE p_scenarios IS NULL OR 'fitted' = ANY(p_scenarios)) g
    CROSS JOIN LATERAL rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, NULL, NULL, true, 15,24,25,3.0, p_route) r
  ),
  ess_run AS (
    SELECT r.* FROM (SELECT 1 WHERE p_scenarios IS NULL OR 'order_essentials' = ANY(p_scenarios)) g
    CROSS JOIN LATERAL rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, 'order_essentials', NULL, false, 15,24,25,3.0, p_route) r
  ),
  cu_run AS (
    SELECT r.* FROM (SELECT 1 WHERE p_scenarios IS NULL OR 'catch_up' = ANY(p_scenarios)) g
    CROSS JOIN LATERAL rpc_bloom_order_recipe(p_store_code, p_delivery_date, p_next_delivery, NULL, 'catch_up', NULL, false, 15,24,25,3.0, p_route) r
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
      count(*) FILTER (WHERE s.promo_active AND s.suggested_packs > 0) AS promo_lines,
      count(*) FILTER (WHERE s.promo_active) AS promo_lines_pool,
      count(*) FILTER (WHERE s.count_first AND s.suggested_packs > 0) AS count_first_lines,
      count(*) FILTER (WHERE s.count_first) AS count_first_pool,
      SUM(s.suggested_packs * s.pack_cost) AS value_normal,
      SUM((CASE WHEN s.promo_active THEN s.geared_packs ELSE s.normal_packs END) * s.pack_cost) AS value_geared,
      count(*) FILTER (WHERE s.budget_fit_reason = 'protected_kvi') AS protected_lines,
      count(*) FILTER (WHERE s.budget_fit_reason IN ('trimmed_partial','trimmed_to_zero')) AS trimmed_lines,
      MAX(s.budget_week_start) AS budget_week_start,
      COALESCE(SUM(s.suggested_packs * s.pack_cost) FILTER (WHERE s.promo_active), 0)     AS value_promo_lines,
      COALESCE(SUM(s.suggested_packs * s.pack_cost) FILTER (WHERE NOT s.promo_active), 0) AS value_nonpromo_lines
    FROM scenarios s
    GROUP BY s.scenario_key
  ),
  kvi_agg AS (
    SELECT s.scenario_key, COALESCE(s.kvi_band,'NONE') AS k, SUM(s.suggested_packs * s.pack_cost) AS v
    FROM scenarios s GROUP BY s.scenario_key, COALESCE(s.kvi_band,'NONE')
  ),
  kvi_json AS (SELECT scenario_key, jsonb_object_agg(k, ROUND(v,2)) AS by_kvi_band FROM kvi_agg GROUP BY scenario_key),
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
  -- ENG-070: was `SELECT DISTINCT product_code FROM full_run`, which returned an
  -- empty set (and a zero demonstrated_weekly_demand, silently changing the
  -- fitted DEFECT_SIGNAL) whenever 'full' was not among the requested scenarios.
  -- Sourced from `scenarios` instead. Safe because all four runs were PROVEN to
  -- share one identical 12,502-product pool, 0 rows differing either way.
  full_products AS (SELECT DISTINCT product_code FROM scenarios),
  demonstrated AS (
    SELECT COALESCE(
             -- ENG-106 leg (b): THE ONE HOME. Dept-scoped so it cannot contract
             -- with the order, watermark-anchored so it cannot drift under it.
             (SELECT b.weekly_cost_demand
                FROM rpc_bloom_route_benchmark(p_store_code, p_route, NULL) b),
             -- Fallback fires ONLY on a direct desk, where canon rules no basis.
             -- Still circular, still CURRENT_DATE. Named residual, not hidden.
             COALESCE(SUM(ss.cost_value), 0) / 4.0
           ) AS v
    FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > CURRENT_DATE - 28 AND ss.sale_date <= CURRENT_DATE
      AND ss.product_code IN (SELECT product_code FROM full_products)
  ),
  budget AS (
    SELECT COALESCE(obl.budget_amount,0) AS budget_amt, COALESCE(obl.cash_constrained,false) AS cash_constrained
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code
      AND obl.route_key = (CASE
        WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'
        WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'
        ELSE 'DC'
      END)
      AND obl.grain = 'weekly'
      AND obl.year_month = (SELECT MAX(a.budget_week_start) FROM agg a)
  ),
  mincfg AS (
    SELECT rc.direct_min_order_value AS min_val
    FROM bloom_route_config rc
    WHERE rc.store_code = p_store_code AND rc.route_key = p_route AND rc.status = 'RULED'
    LIMIT 1
  )
  SELECT
    a.scenario_key, a.lines::int, a.promo_lines::int, a.count_first_lines::int,
    ROUND(a.value_normal,2), ROUND(a.value_geared,2),
    a.protected_lines::int, a.trimmed_lines::int,
    COALESCE((SELECT budget_amt FROM budget), 0), a.budget_week_start,
    ROUND(v_yardstick,2), v_yardstick_source,
    (CASE WHEN v_yardstick > 0 THEN ROUND(((a.value_normal - v_yardstick) / v_yardstick) * 100, 1) ELSE NULL END),
    (CASE
       WHEN a.scenario_key = 'fitted'
         AND (SELECT v FROM demonstrated) > 0
         AND ABS(((a.value_normal - (SELECT v FROM demonstrated)) / (SELECT v FROM demonstrated)) * 100) > p_yardstick_tolerance_pct
         AND NOT COALESCE((SELECT cash_constrained FROM budget), false)
         THEN 'DEFECT_SIGNAL'
       ELSE NULL
     END),
    (CASE
       WHEN a.scenario_key = 'full' THEN 'full_is_luxury_by_definition'
       WHEN a.scenario_key = 'fitted' AND COALESCE((SELECT cash_constrained FROM budget), false) THEN 'cash_constrained'
       ELSE NULL
     END),
    kj.by_kvi_band, mj.by_mode, tj.by_tier, klj.by_kvi_band_lines,
    ROUND((SELECT v FROM demonstrated), 2),
    a.count_first_pool::int,
    (SELECT min_val FROM mincfg),
    (CASE WHEN (SELECT min_val FROM mincfg) IS NULL THEN NULL
          ELSE GREATEST(0, (SELECT min_val FROM mincfg) - a.value_normal) END),
    (CASE
       WHEN (SELECT min_val FROM mincfg) IS NULL THEN NULL
       WHEN a.value_normal >= (SELECT min_val FROM mincfg)
         THEN 'clears the R' || trim(to_char((SELECT min_val FROM mincfg),'FM999999990')) || ' supplier minimum'
       ELSE 'R' || trim(to_char(GREATEST(0,(SELECT min_val FROM mincfg) - a.value_normal),'FM999999990'))
            || ' below the R' || trim(to_char((SELECT min_val FROM mincfg),'FM999999990'))
            || ' supplier minimum -- accumulate to the next cycle or send as is (buyer decides)'
     END),
    v_now,
    ROUND(a.value_promo_lines, 2),
    ROUND(a.value_nonpromo_lines, 2),
    ROUND(100.0 * a.value_promo_lines / NULLIF(a.value_promo_lines + a.value_nonpromo_lines, 0), 1),
    a.promo_lines_pool::int
  FROM agg a
  LEFT JOIN kvi_json kj ON kj.scenario_key = a.scenario_key
  LEFT JOIN mode_json mj ON mj.scenario_key = a.scenario_key
  LEFT JOIN tier_json tj ON tj.scenario_key = a.scenario_key
  LEFT JOIN kvi_lines_json klj ON klj.scenario_key = a.scenario_key
  ORDER BY CASE a.scenario_key WHEN 'full' THEN 1 WHEN 'fitted' THEN 2 WHEN 'order_essentials' THEN 3 WHEN 'catch_up' THEN 4 END;
END;
$function$;

-- Grants stated explicitly (R30 addendum), naming the REAL seven-arg signature.
-- No DROP: the predecessor's DROP named the retired five-arg form and would have
-- left an ambiguous overload (ENG-115).
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric,text[],boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric,text[],boolean) TO anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric,text[],boolean) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_scenario_overview(text,date,date,text,numeric,text[],boolean) TO service_role;
