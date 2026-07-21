-- =============================================================================
-- create_l2_sales_budget.sql
-- SB-CC-BLOOM-011 item 1 -- the NEEDS budget's foundation: a rolling 6-month
-- sales projection per store per budget week. CLEANUP-ENGINE-CANON SS14
-- ADDENDUM v11 item 2 (Pieter ruling 2026-07-14, "for all our calculations
-- we use the needs budget").
--
-- FORMULA (GENERAL, constants DEMO_CALIBRATION) -- pantry reuse, never a
-- parallel formula (R27): for each product in the route's pool,
--   product_week_projection = ly_actual_cost(product, LY-shifted week)
--                              x rhythm_index(product, this week's W-bucket)
--                              x seasonality_factor(product, this week's month)
-- summed across the route's pool = rhythm_seasonality_projected_cost, THEN
--   projected_sales_cost = rhythm_seasonality_projected_cost x trend_factor
-- trend_factor is ONE ratio per (store, route) -- trailing 8-week actual
-- cost vs the LY-equivalent trailing 8 weeks, for the SAME pool, capped to
-- [0.6, 1.6] (DEMO_CALIBRATION) so a noisy trailing window can't run away.
-- Doing the rhythm/seasonality multiply at PRODUCT grain and summing (never
-- computing one blended store-level index first) means the aggregate is
-- naturally volume-weighted by each product's own LY history -- no separate
-- weighting step to get wrong, and every row still reconciles to L1 (R22):
-- SUM(ly_base_cost) via this exact query = SUM(sigma_sales.cost_value) over
-- the same LY window and pool, by construction.
--
-- Route population mirrors rpc_bloom_order_recipe's own `lnk` CTE EXACTLY
-- (same supplier_type/status/merch_group/direct_supplier_nrs conditions,
-- R21 -- one classifier, reused, never reinvented) but as STATIC SQL (a
-- parameterised CASE inside one query) rather than the recipe's dynamic-SQL
-- approach -- this function returns a plain TABLE, no RETURNS TABLE column
-- shadowing risk to work around, so the simpler static form is safe here.
--
-- NAMED LIMITATION, not silently absorbed: this formula is LY-anchored, so
-- a product with ZERO LY-equivalent-window sales (new listing, or a line
-- that wasn't ranged a year ago) contributes ZERO projected demand even if
-- it is selling well today -- `products_with_ly_history` / `products_in_pool`
-- on every row names the gap size. A trailing-sales fallback for LY-blind
-- products is a real, separate enhancement, not built here (not named in
-- the brief's own formula spec) -- flagged for PM, not guessed.
--
-- ONE SHARED FORMULA, TWO CALLERS (R21): `rpc_project_route_sales_budget`
-- is the pure projection, parameterised by anchor date -- called with
-- CURRENT_DATE by `refresh_l2_sales_budget` (the live nightly fact) and
-- with a PAST anchor by `rpc_backtest_l2_sales_budget` (item 1's own
-- backtest gate) so the exact same math is being graded that will govern
-- a real order once it passes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_sales_budget (
  client_id text NOT NULL DEFAULT 'socialbrand',
  store_code text NOT NULL,
  route_key text NOT NULL,
  budget_week_start date NOT NULL,          -- Saturday anchor, matches order_budget_ledger.year_month (grain='weekly')
  month_start date NOT NULL,                -- calendar month the week's own START date falls in (majority-day simplification, named below)
  ly_base_cost numeric NOT NULL,            -- raw LY (364-shift) route-pool actual cost, pre-rhythm/seasonality/trend -- R22 anchor
  trend_factor numeric NOT NULL,            -- store/route trailing-8wk-vs-LY-trailing-8wk ratio, capped [0.6,1.6]
  rhythm_seasonality_projected_cost numeric NOT NULL,  -- Sum(product LY x rhythm x seasonality), BEFORE trend
  projected_sales_cost numeric NOT NULL,    -- = rhythm_seasonality_projected_cost x trend_factor -- THE OUTPUT
  products_in_pool integer NOT NULL,
  products_with_ly_history integer NOT NULL,  -- names the LY-blind-product gap (see header)
  anchor_date date NOT NULL,
  engine_version text NOT NULL DEFAULT 'v1.0',
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, route_key, budget_week_start)
);

COMMENT ON TABLE public.l2_sales_budget IS
  'SB-CC-BLOOM-011 item 1. Rolling 6-month sales projection per store per budget week -- the foundation of the NEEDS budget (canon v11). PROVISIONAL until backtested (rpc_backtest_l2_sales_budget) and PM signs -- the 82%-of-forecast cashflow basis keeps governing order calculations until then.';

REVOKE ALL ON TABLE public.l2_sales_budget FROM PUBLIC;
GRANT SELECT ON public.l2_sales_budget TO anon, authenticated;

-- =============================================================================
-- rpc_project_route_sales_budget -- the ONE formula, reusable by anchor date.
-- Returns 26 weeks (6 months) forward from the Saturday on/after p_anchor_date.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_project_route_sales_budget(
  p_store_code text,
  p_route_key text,
  p_anchor_date date DEFAULT CURRENT_DATE,
  p_weeks_forward int DEFAULT 26
)
RETURNS TABLE(
  budget_week_start date,
  month_start date,
  ly_base_cost numeric,
  trend_factor numeric,
  rhythm_seasonality_projected_cost numeric,
  projected_sales_cost numeric,
  products_in_pool integer,
  products_with_ly_history integer
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor_week_start date;
  v_trend numeric;
BEGIN
  SET LOCAL statement_timeout = '60s';

  -- Saturday on/after (or equal to) the anchor -- same formula as
  -- rpc_bloom_order_recipe's own v_week_start (R21, budget-week convention
  -- v7 item 7).
  v_anchor_week_start := p_anchor_date - ((EXTRACT(ISODOW FROM p_anchor_date)::int + 1) % 7);
  IF v_anchor_week_start < p_anchor_date THEN
    v_anchor_week_start := v_anchor_week_start + 7;
  END IF;

  -- Route pool -- mirrors rpc_bloom_order_recipe's `lnk` CTE population
  -- exactly (R21, one classifier reused, never reinvented).
  -- NOT "ON COMMIT DROP" -- that only fires at actual transaction commit,
  -- not at function return, so a caller invoking this function twice in
  -- one statement/transaction (refresh_l2_sales_budget's own per-route
  -- loop, or two UNION ALL'd calls) collided on the second CREATE TEMP
  -- TABLE (caught live during this build's own R22 pass). Explicit
  -- DROP-then-CREATE at the top and an explicit DROP at the end instead.
  DROP TABLE IF EXISTS _sb_pool;
  CREATE TEMP TABLE _sb_pool AS
  WITH dc_cfg AS (
    SELECT dc.dc_cycle_dept_nrs
    FROM bloom_dc_config dc
    WHERE dc.store_code = p_store_code AND dc.status = 'RULED'
      AND p_route_key IN ('DC_AMBIENT', 'DC_TOPS')
  ),
  route_cfg AS (
    SELECT rc.merch_group_nrs, rc.excluded_supplier_types, rc.direct_supplier_nrs
    FROM bloom_route_config rc
    WHERE rc.store_code = p_store_code AND rc.route_key = p_route_key AND rc.status = 'RULED'
  )
  SELECT DISTINCT sl.product_code
  FROM sigma_supplier_link sl
  LEFT JOIN sigma_supplier_master sm ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
  LEFT JOIN l2_stock_position sp ON sp.store_code = sl.store_code AND sp.product_code = sl.product_code
  WHERE sl.store_code = p_store_code
    AND COALESCE(sl.status, '') <> 'S'
    AND (sl.valid_to IS NULL OR sl.valid_to >= p_anchor_date)
    AND (
      (p_route_key IN ('DC_AMBIENT', 'DC_TOPS') AND sm.supplier_type = 'Z'
        AND sp.department_nr = ANY(COALESCE((SELECT dc_cycle_dept_nrs FROM dc_cfg), ARRAY[]::smallint[])))
      -- ENG-033 (2026-07-21): DIRECT_BEER is account-scoped like every other DIRECT_* desk
      OR (p_route_key LIKE 'DIRECT\_%' ESCAPE '\'
        AND sl.supplier_nr = ANY(COALESCE((SELECT direct_supplier_nrs FROM route_cfg), ARRAY[]::bigint[])))
    );

  -- Trend factor -- ONE ratio per (store, route): trailing 8 weeks ending
  -- the anchor's own week start, vs the LY-equivalent trailing 8 weeks,
  -- SAME pool. Capped [0.6, 1.6] (DEMO_CALIBRATION) -- a noisy trailing
  -- window must not extrapolate into a runaway projection. Defaults to
  -- 1.0 (no adjustment) when LY-trailing has no history to divide by.
  SELECT LEAST(GREATEST(
    COALESCE(recent.v, 0) / NULLIF(lytrail.v, 0),
    0.6), 1.6)
  INTO v_trend
  FROM (
    SELECT SUM(ss.cost_value) AS v FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > v_anchor_week_start - 56 AND ss.sale_date <= v_anchor_week_start
      AND ss.product_code IN (SELECT product_code FROM _sb_pool)
  ) recent,
  (
    SELECT SUM(ss.cost_value) AS v FROM sigma_sales ss
    WHERE ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date > v_anchor_week_start - 56 - 364 AND ss.sale_date <= v_anchor_week_start - 364
      AND ss.product_code IN (SELECT product_code FROM _sb_pool)
  ) lytrail;
  v_trend := COALESCE(v_trend, 1.0);

  RETURN QUERY
  WITH weeks AS (
    SELECT gs::date AS week_start, gs::date - 364 AS ly_week_start
    FROM generate_series(v_anchor_week_start, v_anchor_week_start + (p_weeks_forward - 1) * 7, INTERVAL '7 days') gs
  ),
  ly_sales AS (
    SELECT w.week_start, ss.product_code, SUM(ss.cost_value) AS ly_cost
    FROM weeks w
    JOIN sigma_sales ss
      ON ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date >= w.ly_week_start AND ss.sale_date < w.ly_week_start + 7
    GROUP BY w.week_start, ss.product_code
  ),
  per_product_week AS (
    SELECT
      w.week_start,
      p.product_code,
      COALESCE(ls.ly_cost, 0) AS ly_cost,
      -- W-bucket by day-of-month of the WEEK START, same boundaries as
      -- refresh_l2_rhythm_profile (1-7/8-14/15-21/22+, R21 reuse).
      COALESCE(
        CASE
          WHEN EXTRACT(day FROM w.week_start)::int BETWEEN 1 AND 7 THEN rp.w1_index
          WHEN EXTRACT(day FROM w.week_start)::int BETWEEN 8 AND 14 THEN rp.w2_index
          WHEN EXTRACT(day FROM w.week_start)::int BETWEEN 15 AND 21 THEN rp.w3_index
          ELSE rp.w4_index
        END, 1.0) AS rhythm_index,
      -- Seasonality factor for the week START's own calendar month
      -- (majority-day simplification, named in the header -- a week
      -- spanning a month boundary reads the START month's factor only).
      COALESCE(sp.monthly_factor[EXTRACT(month FROM w.week_start)::int], 1.0) AS seasonality_factor
    FROM weeks w
    CROSS JOIN _sb_pool p
    LEFT JOIN ly_sales ls ON ls.week_start = w.week_start AND ls.product_code = p.product_code
    LEFT JOIN l2_rhythm_profile rp ON rp.store_code = p_store_code AND rp.product_code = p.product_code
    LEFT JOIN l2_seasonality_profile sp ON sp.store_code = p_store_code AND sp.product_code = p.product_code
  ),
  weekly_agg AS (
    SELECT
      week_start,
      SUM(ly_cost) AS ly_base_cost,
      SUM(ly_cost * rhythm_index * seasonality_factor) AS rhythm_seasonality_projected_cost,
      COUNT(*) AS products_in_pool,
      COUNT(*) FILTER (WHERE ly_cost > 0) AS products_with_ly_history
    FROM per_product_week
    GROUP BY week_start
  )
  SELECT
    wa.week_start,
    date_trunc('month', wa.week_start)::date,
    ROUND(wa.ly_base_cost, 2),
    ROUND(v_trend, 4),
    ROUND(wa.rhythm_seasonality_projected_cost, 2),
    ROUND(wa.rhythm_seasonality_projected_cost * v_trend, 2),
    wa.products_in_pool::int,
    wa.products_with_ly_history::int
  FROM weekly_agg wa
  ORDER BY wa.week_start;

  DROP TABLE IF EXISTS _sb_pool;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_project_route_sales_budget(text,text,date,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_project_route_sales_budget(text,text,date,int) TO authenticated;

-- =============================================================================
-- refresh_l2_sales_budget -- the LIVE nightly fact. Discovers every RULED
-- route at the store (DC from bloom_dc_config, direct/beer from
-- bloom_route_config) and projects each one 26 weeks forward from
-- CURRENT_DATE, DELETE + re-INSERT per store (idempotent, R21 pattern).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.refresh_l2_sales_budget(p_store_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_route text;
  v_dc_route text;
  v_rows int := 0;
  v_route_rows int;
BEGIN
  SET LOCAL statement_timeout = '120s';

  DELETE FROM public.l2_sales_budget WHERE store_code = p_store_code;

  SELECT (CASE dc.format_group WHEN 'SPAR' THEN 'DC_AMBIENT' WHEN 'TOPS' THEN 'DC_TOPS' END)
  INTO v_dc_route
  FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED';

  IF v_dc_route IS NOT NULL THEN
    INSERT INTO public.l2_sales_budget (
      client_id, store_code, route_key, budget_week_start, month_start,
      ly_base_cost, trend_factor, rhythm_seasonality_projected_cost, projected_sales_cost,
      products_in_pool, products_with_ly_history, anchor_date
    )
    SELECT 'socialbrand', p_store_code, v_dc_route, r.budget_week_start, r.month_start,
      r.ly_base_cost, r.trend_factor, r.rhythm_seasonality_projected_cost, r.projected_sales_cost,
      r.products_in_pool, r.products_with_ly_history, CURRENT_DATE
    FROM rpc_project_route_sales_budget(p_store_code, v_dc_route, CURRENT_DATE, 26) r;
    GET DIAGNOSTICS v_route_rows = ROW_COUNT;
    v_rows := v_rows + v_route_rows;
  END IF;

  FOR v_route IN
    SELECT rc.route_key FROM bloom_route_config rc
    WHERE rc.store_code = p_store_code AND rc.status = 'RULED'
  LOOP
    INSERT INTO public.l2_sales_budget (
      client_id, store_code, route_key, budget_week_start, month_start,
      ly_base_cost, trend_factor, rhythm_seasonality_projected_cost, projected_sales_cost,
      products_in_pool, products_with_ly_history, anchor_date
    )
    SELECT 'socialbrand', p_store_code, v_route, r.budget_week_start, r.month_start,
      r.ly_base_cost, r.trend_factor, r.rhythm_seasonality_projected_cost, r.projected_sales_cost,
      r.products_in_pool, r.products_with_ly_history, CURRENT_DATE
    FROM rpc_project_route_sales_budget(p_store_code, v_route, CURRENT_DATE, 26) r;
    GET DIAGNOSTICS v_route_rows = ROW_COUNT;
    v_rows := v_rows + v_route_rows;
  END LOOP;

  RETURN jsonb_build_object('store_code', p_store_code, 'rows', v_rows, 'refreshed_at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_sales_budget(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_sales_budget(text) TO authenticated;

-- =============================================================================
-- rpc_backtest_l2_sales_budget -- item 1's own gate (R27 SS6). Runs the SAME
-- projection (rpc_project_route_sales_budget) anchored at a PAST date, then
-- compares each projected week to what ACTUALLY happened. Never persisted --
-- a diagnostic, run on demand, published in the brief close-out.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_backtest_l2_sales_budget(
  p_store_code text,
  p_route_key text,
  p_backtest_anchor_date date,
  p_weeks_forward int DEFAULT 26
)
RETURNS TABLE(
  budget_week_start date,
  projected_sales_cost numeric,
  actual_sales_cost numeric,
  error_pct numeric,
  products_in_pool integer,
  products_with_ly_history integer
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  SET LOCAL statement_timeout = '60s';

  RETURN QUERY
  WITH proj AS (
    SELECT * FROM rpc_project_route_sales_budget(p_store_code, p_route_key, p_backtest_anchor_date, p_weeks_forward)
  ),
  pool AS (
    -- Re-derive the SAME pool the projection used (R21) so the actuals
    -- comparison is apples-to-apples, not a different product set.
    WITH dc_cfg AS (
      SELECT dc.dc_cycle_dept_nrs FROM bloom_dc_config dc
      WHERE dc.store_code = p_store_code AND dc.status = 'RULED' AND p_route_key IN ('DC_AMBIENT','DC_TOPS')
    ),
    route_cfg AS (
      SELECT rc.merch_group_nrs, rc.excluded_supplier_types, rc.direct_supplier_nrs
      FROM bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = p_route_key AND rc.status = 'RULED'
    )
    SELECT DISTINCT sl.product_code
    FROM sigma_supplier_link sl
    LEFT JOIN sigma_supplier_master sm ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
    LEFT JOIN l2_stock_position sp ON sp.store_code = sl.store_code AND sp.product_code = sl.product_code
    WHERE sl.store_code = p_store_code AND COALESCE(sl.status,'') <> 'S'
      AND (sl.valid_to IS NULL OR sl.valid_to >= p_backtest_anchor_date)
      AND (
        (p_route_key IN ('DC_AMBIENT','DC_TOPS') AND sm.supplier_type = 'Z'
          AND sp.department_nr = ANY(COALESCE((SELECT dc_cycle_dept_nrs FROM dc_cfg), ARRAY[]::smallint[])))
        -- ENG-033 (2026-07-21): DIRECT_BEER is account-scoped like every other DIRECT_* desk
        OR (p_route_key LIKE 'DIRECT\_%' ESCAPE '\'
          AND sl.supplier_nr = ANY(COALESCE((SELECT direct_supplier_nrs FROM route_cfg), ARRAY[]::bigint[])))
      )
  ),
  actual AS (
    SELECT p.budget_week_start, SUM(ss.cost_value) AS actual_cost
    FROM proj p
    JOIN sigma_sales ss ON ss.store_code = p_store_code AND ss.period_kind = 'T' AND ss.txn_kind = 1
      AND ss.sale_date >= p.budget_week_start AND ss.sale_date < p.budget_week_start + 7
      AND ss.product_code IN (SELECT product_code FROM pool)
    GROUP BY p.budget_week_start
  )
  SELECT
    p.budget_week_start, p.projected_sales_cost, COALESCE(a.actual_cost, 0),
    (CASE WHEN COALESCE(a.actual_cost,0) > 0
       THEN ROUND(((p.projected_sales_cost - a.actual_cost) / a.actual_cost) * 100, 1)
       ELSE NULL END),
    p.products_in_pool, p.products_with_ly_history
  FROM proj p LEFT JOIN actual a ON a.budget_week_start = p.budget_week_start
  ORDER BY p.budget_week_start;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_backtest_l2_sales_budget(text,text,date,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_backtest_l2_sales_budget(text,text,date,int) TO authenticated;

SELECT pg_notify('pgrst', 'reload schema');
