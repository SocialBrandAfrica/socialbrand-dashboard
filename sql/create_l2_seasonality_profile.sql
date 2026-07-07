-- =============================================================================
-- create_l2_seasonality_profile.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #3 of 5 (BLOOM-003 s2/s2b,
-- confirmed formula: "Seasonality = 13-month monthly index against the
-- trailing mean, factor capped 0.5 to 2.0 -- the backtest ran exactly this
-- cap"). R28: effective_from 2026-07-07. Formula GENERAL, cap DEMO_CALIBRATION
-- (config keys seasonality_floor=0.5 / seasonality_ceiling=2.0).
--
-- ARCHITECTURE: same proven pattern (persistent TABLE, refresh_<name>(p_store),
-- idempotent). Stores the FULL 12-month factor array (not just "this month"),
-- per STRAT-001 s2 ("Annual seasonality... 13-month monthly profile") and s4a
-- ("Seasonality pre-warns the order ahead of a line's annual ramp") -- a
-- lookahead needs every month's factor, not only today's.
--
-- FORMULA: for calendar month number m (1=Jan..12=Dec), factor(m) =
-- (SUM(qty) in month m across its occurrence(s) in the trailing 13-month
-- window / calendar days m contributes to that window) / (product's overall
-- 13-month average daily rate), capped [0.5, 2.0]. Most month numbers occur
-- exactly once in a 13-month trailing window; the anchor's own edge months
-- can occur twice (partial + full) and are summed together, not isolated to
-- "last year's occurrence alone" -- a minor, documented divergence from the
-- backtest's literal "LY June vs 13-month average" phrasing (which was
-- computed for a June-specific anchor); the confirmed general rule ("index
-- against the trailing mean, capped 0.5-2.0") is what this object implements,
-- auditable and identical in shape (R29).
-- current_month_factor is a convenience column = monthly_factor[this month],
-- matching exactly what the backtest used for its single-month simulation.
-- NULL factor (whole array) = product had zero sales anywhere in the 13-month
-- window -- never silently defaulted to 1.0 here (R23); the recipe RPC
-- decides its own fallback.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_seasonality_profile (
  client_id             text NOT NULL DEFAULT 'socialbrand',
  store_code            text NOT NULL,
  product_code          bigint NOT NULL,
  monthly_factor        numeric[],
  current_month_factor  numeric,
  overall_rate_13m      numeric,
  floor_used            numeric NOT NULL DEFAULT 0.5,
  ceiling_used          numeric NOT NULL DEFAULT 2.0,
  window_months         int NOT NULL DEFAULT 13,
  engine_version        text NOT NULL DEFAULT 'v1.0',
  profiled_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

REVOKE ALL ON public.l2_seasonality_profile FROM PUBLIC;
GRANT SELECT ON public.l2_seasonality_profile TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_seasonality_profile(
  p_store    text,
  p_floor    numeric DEFAULT 0.5,
  p_ceiling  numeric DEFAULT 2.0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date;
  v_rows int;
  v_total_days int;
BEGIN
  SELECT MAX(sale_date) INTO v_anchor
  FROM public.sigma_sales
  WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1;

  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('store_code', p_store, 'rows', 0, 'error', 'no sigma_sales rows for this store');
  END IF;

  DELETE FROM public.l2_seasonality_profile WHERE store_code = p_store;

  WITH cal AS (
    SELECT gs::date AS cal_date, EXTRACT(MONTH FROM gs)::int AS month_num
    FROM generate_series(v_anchor - INTERVAL '13 months' + INTERVAL '1 day', v_anchor, INTERVAL '1 day') gs
  ),
  cal_days AS (SELECT month_num, COUNT(*) AS days FROM cal GROUP BY month_num),
  total_days_t AS (SELECT COUNT(*) AS days FROM cal),
  sales_month AS (
    SELECT product_code, EXTRACT(MONTH FROM sale_date)::int AS month_num, SUM(qty) AS qty
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - INTERVAL '13 months' AND sale_date <= v_anchor
    GROUP BY product_code, month_num
  ),
  total_qty AS (SELECT product_code, SUM(qty) AS total_qty FROM sales_month GROUP BY product_code),
  pool AS (
    SELECT sp.product_code FROM public.l2_stock_position sp
    WHERE sp.store_code = p_store AND sp.class = 'NORMAL'
  ),
  grid AS (
    SELECT p.product_code, gm.month_num,
      COALESCE(sm.qty, 0) AS month_qty,
      cd.days AS month_days,
      COALESCE(tq.total_qty, 0) AS total_qty_p
    FROM pool p
    CROSS JOIN generate_series(1, 12) AS gm(month_num)
    JOIN cal_days cd ON cd.month_num = gm.month_num
    LEFT JOIN sales_month sm ON sm.product_code = p.product_code AND sm.month_num = gm.month_num
    LEFT JOIN total_qty tq ON tq.product_code = p.product_code
  ),
  factors AS (
    SELECT product_code,
      array_agg(
        CASE WHEN total_qty_p > 0
          THEN LEAST(p_ceiling, GREATEST(p_floor,
                 (month_qty / month_days) / (total_qty_p / (SELECT days FROM total_days_t)::numeric)))
          ELSE NULL END
        ORDER BY month_num
      ) AS monthly_factor,
      MAX(total_qty_p) AS total_qty_p
    FROM grid
    GROUP BY product_code
  )
  INSERT INTO public.l2_seasonality_profile (
    client_id, store_code, product_code, monthly_factor, current_month_factor,
    overall_rate_13m, floor_used, ceiling_used, window_months, engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code, monthly_factor,
    monthly_factor[EXTRACT(MONTH FROM v_anchor)::int],
    CASE WHEN total_qty_p > 0 THEN total_qty_p / (SELECT days FROM total_days_t)::numeric ELSE NULL END,
    p_floor, p_ceiling, 13, 'v1.0', now()
  FROM factors;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT days INTO v_total_days FROM (SELECT COUNT(*) AS days FROM generate_series(v_anchor - INTERVAL '13 months' + INTERVAL '1 day', v_anchor, INTERVAL '1 day')) x;
  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'rows', v_rows, 'window_days', v_total_days);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_seasonality_profile(text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_seasonality_profile(text, numeric, numeric) TO authenticated;
