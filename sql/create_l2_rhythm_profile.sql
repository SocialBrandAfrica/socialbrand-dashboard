-- =============================================================================
-- create_l2_rhythm_profile.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #2 of 5 (BLOOM-003 s2/s2b #3).
-- R28: effective_from 2026-07-07. Formula GENERAL, skew cutoff DEMO_CALIBRATION
-- (config key rhythm_skew_cutoff = 1.25, midpoint of proven flat 1.0 and
-- peaky 1.5 per SB-STRAT-001 s1).
--
-- ARCHITECTURE: same proven pattern as l2_kvi_profile -- persistent TABLE,
-- refresh_l2_rhythm_profile(p_store) per-store function, idempotent (DELETE
-- store rows + re-INSERT). Calendar-bucket day COUNTS are computed once (a
-- handful of constants) and per-product SUMs joined against them -- avoids a
-- calendar x product cross join (the canon s0e/s0f timeout lesson: never
-- cross a big pool against a per-day frame when a grouped SUM does the same
-- job in one pass).
--
-- SCOPE: l2_stock_position WHERE class='NORMAL' (same as l2_kvi_profile).
--
-- WEEKLY INDEX (BLOOM-003 s2b #3, the field the Recipe RPC reads directly):
--   index_Wn = (SUM(qty) in week Wn / calendar days in Wn) / (SUM(qty) over
--   the whole trailing-6-month window / total calendar days in the window).
--   Pay-cycle weeks by day-of-month: W1 = 1-7 (pension), W2 = 8-14, W3 =
--   15-21 (W2+W3 together = "the lull", per the brief), W4 = 22-month-end
--   (payday build).
--
-- SKEW / ARCHETYPE (BLOOM-003 s2b #3, classification only -- NOT the stored
-- weekly index):
--   lull_rate = rate over W2+W3 (days 8-21).
--   payday_rate = rate over the WRAPPING payday window (day>=22 OR day<=7).
--   early_rate = rate over days 1-10.
--   skew_payday = payday_rate / lull_rate, skew_early = early_rate / lull_rate.
--   skew = GREATEST(skew_payday, skew_early) -- whichever candidate window
--   shows the stronger deviation from the lull IS the peak, operationalising
--   "peak in the payday window" vs "peak only in 1-10" as a direct rate
--   comparison (both windows share days 1-7, so a genuine pension-only line
--   reads higher on the 1-10 window than the wider payday window; a genuine
--   month-end line reads higher on the payday window). This comparison rule
--   is CC's direct reading of an unambiguous instruction, not a confrontable
--   gap -- documented here for audit (R29).
--   skew < 1.25            -> EVERYDAY
--   skew_payday >= skew_early (and skew >= 1.25) -> MONTH_END
--   skew_early > skew_payday (and skew >= 1.25)  -> EARLY_MONTH
--   qty_total = 0 (never sold in the window) -> 'NO_DATA', never silently
--   defaulted to EVERYDAY (R23 -- a named gap, not a guess).
--   Zero-lull edge case: if lull_rate = 0 but the line sold in a peak window,
--   skew is treated as maximal (sentinel 999) rather than NULL/undefined, so
--   a real peak-only line still classifies instead of falling through.
--
-- NAMED LIMIT (R23, same discipline as l2_kvi_profile's penetration gap):
-- rates are CALENDAR-DAY based, not in-stock-day corrected. l2_soh_daily's
-- real history is currently too short (~1 month) to cover a 6-month rhythm
-- window, so the "in-stock days when available" instruction is honoured as
-- "not yet available" here -- calendar_day_basis=true flags this on every
-- row, never silently assumed corrected.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_rhythm_profile (
  client_id           text NOT NULL DEFAULT 'socialbrand',
  store_code          text NOT NULL,
  product_code        bigint NOT NULL,
  qty_w1              numeric NOT NULL DEFAULT 0,
  qty_w2              numeric NOT NULL DEFAULT 0,
  qty_w3              numeric NOT NULL DEFAULT 0,
  qty_w4              numeric NOT NULL DEFAULT 0,
  qty_payday          numeric NOT NULL DEFAULT 0,
  qty_early           numeric NOT NULL DEFAULT 0,
  qty_lull            numeric NOT NULL DEFAULT 0,
  qty_total           numeric NOT NULL DEFAULT 0,
  w1_index            numeric,
  w2_index            numeric,
  w3_index            numeric,
  w4_index            numeric,
  payday_rate         numeric,
  early_rate          numeric,
  lull_rate           numeric,
  overall_rate        numeric,
  skew                numeric,
  archetype           text NOT NULL DEFAULT 'NO_DATA',
  skew_cutoff_used    numeric NOT NULL,
  window_months       int NOT NULL DEFAULT 6,
  calendar_day_basis  boolean NOT NULL DEFAULT true,
  engine_version      text NOT NULL DEFAULT 'v1.0',
  profiled_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_rhythm_profile_archetype ON public.l2_rhythm_profile (store_code, archetype);

REVOKE ALL ON public.l2_rhythm_profile FROM PUBLIC;
GRANT SELECT ON public.l2_rhythm_profile TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_rhythm_profile(
  p_store          text,
  p_skew_cutoff    numeric DEFAULT 1.25
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date;
  v_rows int;
  v_days_w1 int; v_days_w2 int; v_days_w3 int; v_days_w4 int;
  v_days_payday int; v_days_early int; v_days_lull int; v_days_total int;
BEGIN
  SELECT MAX(sale_date) INTO v_anchor
  FROM public.sigma_sales
  WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1;

  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('store_code', p_store, 'rows', 0, 'error', 'no sigma_sales rows for this store');
  END IF;

  -- Calendar-bucket day counts over the trailing 6-month window (constants,
  -- computed once -- not per product).
  WITH cal AS (
    SELECT gs::date AS cal_date, EXTRACT(day FROM gs)::int AS dom
    FROM generate_series(v_anchor - INTERVAL '6 months' + INTERVAL '1 day', v_anchor, INTERVAL '1 day') gs
  )
  SELECT
    COUNT(*) FILTER (WHERE dom BETWEEN 1 AND 7),
    COUNT(*) FILTER (WHERE dom BETWEEN 8 AND 14),
    COUNT(*) FILTER (WHERE dom BETWEEN 15 AND 21),
    COUNT(*) FILTER (WHERE dom >= 22),
    COUNT(*) FILTER (WHERE dom >= 22 OR dom <= 7),
    COUNT(*) FILTER (WHERE dom BETWEEN 1 AND 10),
    COUNT(*) FILTER (WHERE dom BETWEEN 8 AND 21),
    COUNT(*)
  INTO v_days_w1, v_days_w2, v_days_w3, v_days_w4, v_days_payday, v_days_early, v_days_lull, v_days_total
  FROM cal;

  DELETE FROM public.l2_rhythm_profile WHERE store_code = p_store;

  WITH sales_dom AS (
    SELECT product_code, qty, EXTRACT(day FROM sale_date)::int AS dom
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - INTERVAL '6 months' AND sale_date <= v_anchor
  ),
  agg AS (
    SELECT product_code,
      SUM(qty) FILTER (WHERE dom BETWEEN 1 AND 7)  AS qty_w1,
      SUM(qty) FILTER (WHERE dom BETWEEN 8 AND 14) AS qty_w2,
      SUM(qty) FILTER (WHERE dom BETWEEN 15 AND 21) AS qty_w3,
      SUM(qty) FILTER (WHERE dom >= 22)            AS qty_w4,
      SUM(qty) FILTER (WHERE dom >= 22 OR dom <= 7) AS qty_payday,
      SUM(qty) FILTER (WHERE dom BETWEEN 1 AND 10) AS qty_early,
      SUM(qty) FILTER (WHERE dom BETWEEN 8 AND 21) AS qty_lull,
      SUM(qty) AS qty_total
    FROM sales_dom
    GROUP BY product_code
  ),
  pool AS (
    SELECT sp.product_code
    FROM public.l2_stock_position sp
    WHERE sp.store_code = p_store AND sp.class = 'NORMAL'
  ),
  scored AS (
    SELECT p.product_code,
      COALESCE(a.qty_w1, 0) AS qty_w1, COALESCE(a.qty_w2, 0) AS qty_w2,
      COALESCE(a.qty_w3, 0) AS qty_w3, COALESCE(a.qty_w4, 0) AS qty_w4,
      COALESCE(a.qty_payday, 0) AS qty_payday, COALESCE(a.qty_early, 0) AS qty_early,
      COALESCE(a.qty_lull, 0) AS qty_lull, COALESCE(a.qty_total, 0) AS qty_total
    FROM pool p
    LEFT JOIN agg a ON a.product_code = p.product_code
  ),
  rated AS (
    SELECT *,
      (qty_w1 / NULLIF(v_days_w1, 0)) AS w1_rate,
      (qty_w2 / NULLIF(v_days_w2, 0)) AS w2_rate,
      (qty_w3 / NULLIF(v_days_w3, 0)) AS w3_rate,
      (qty_w4 / NULLIF(v_days_w4, 0)) AS w4_rate,
      (qty_payday / NULLIF(v_days_payday, 0)) AS payday_rate,
      (qty_early / NULLIF(v_days_early, 0)) AS early_rate,
      (qty_lull / NULLIF(v_days_lull, 0)) AS lull_rate,
      (qty_total / NULLIF(v_days_total, 0)) AS overall_rate
    FROM scored
  ),
  skewed AS (
    SELECT *,
      CASE WHEN lull_rate > 0 THEN payday_rate / lull_rate
           WHEN payday_rate > 0 THEN 999 ELSE 0 END AS skew_payday,
      CASE WHEN lull_rate > 0 THEN early_rate / lull_rate
           WHEN early_rate > 0 THEN 999 ELSE 0 END AS skew_early
    FROM rated
  )
  INSERT INTO public.l2_rhythm_profile (
    client_id, store_code, product_code,
    qty_w1, qty_w2, qty_w3, qty_w4, qty_payday, qty_early, qty_lull, qty_total,
    w1_index, w2_index, w3_index, w4_index,
    payday_rate, early_rate, lull_rate, overall_rate,
    skew, archetype, skew_cutoff_used, window_months, calendar_day_basis,
    engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code,
    qty_w1, qty_w2, qty_w3, qty_w4, qty_payday, qty_early, qty_lull, qty_total,
    CASE WHEN overall_rate > 0 THEN w1_rate / overall_rate ELSE NULL END,
    CASE WHEN overall_rate > 0 THEN w2_rate / overall_rate ELSE NULL END,
    CASE WHEN overall_rate > 0 THEN w3_rate / overall_rate ELSE NULL END,
    CASE WHEN overall_rate > 0 THEN w4_rate / overall_rate ELSE NULL END,
    payday_rate, early_rate, lull_rate, overall_rate,
    GREATEST(skew_payday, skew_early),
    CASE WHEN qty_total = 0 THEN 'NO_DATA'
         WHEN GREATEST(skew_payday, skew_early) < p_skew_cutoff THEN 'EVERYDAY'
         WHEN skew_payday >= skew_early THEN 'MONTH_END'
         ELSE 'EARLY_MONTH' END,
    p_skew_cutoff, 6, true,
    'v1.0', now()
  FROM skewed;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'rows', v_rows,
    'calendar_days', jsonb_build_object('w1', v_days_w1, 'w2', v_days_w2, 'w3', v_days_w3, 'w4', v_days_w4,
                                         'payday', v_days_payday, 'early', v_days_early, 'lull', v_days_lull, 'total', v_days_total));
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_rhythm_profile(text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_rhythm_profile(text, numeric) TO authenticated;
