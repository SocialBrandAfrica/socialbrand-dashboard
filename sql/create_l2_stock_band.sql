-- =============================================================================
-- create_l2_stock_band.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #5 of 5 (BLOOM-003 s2/s2b #4).
-- Depends on l2_kvi_profile, l2_rhythm_profile, l2_seasonality_profile,
-- l2_gmroi_profile (all built + R22-verified this ship). R28:
-- effective_from 2026-07-07. Formula GENERAL, constants DEMO_CALIBRATION.
--
-- ARCHITECTURE: same proven pattern (persistent TABLE, refresh_<name>(p_store),
-- idempotent).
--
-- WHAT THIS IS (date-agnostic pantry fact, NOT a specific-delivery order):
-- like l2_stock_position.days_cover already answers "at today's rate, how
-- many days of stock is this" without needing a chosen delivery date, this
-- object answers "under this store's STANDING delivery cadence, what is this
-- line's healthy [min,max] band today." The Recipe RPC (Ship 2 next object)
-- applies its OWN specific delivery-date + mode-timing logic on top of this
-- pantry fact -- R27: the pantry stocks the fact, the recipe picks the date.
--
-- LEAD-TO-NEXT-DELIVERY (BLOOM-003 s2 lists this as a stock-band input, but
-- no per-store cadence table exists yet -- bloom_dc_config carries dept
-- scope, not a lead-time column). INTERIM LEVER, same precedent as
-- SB-CC-BLOOM-002's p_days_cover default=7 (canon s14 addendum v4, itself
-- ruled interim pending the real DC-cadence work): p_lead_days DEFAULT 3.5
-- (half of "twice-weekly", canon s14 addendum v4's own description of the DC
-- cycle). Config key, not hardcoded logic -- superseded when cadence-aware
-- lead time lands, same as the days-cover selector.
--
-- FORMULA (BLOOM-003 s2b #4, CORRECTED per PM's second review, 2026-07-08 --
-- see ENG-001 v2 note below; this replaces the first-pass GREATEST clamp):
--   rhythm_adjusted_demand = l2_stock_position.daily_ros
--     x this-week's index (from l2_rhythm_profile, W1-W4 by today's
--       day-of-month, COALESCEd to 1.0 -- EVERYDAY archetype lines are
--       already near 1.0 by construction so this is a correct no-op there)
--     x this-month's seasonality factor (l2_seasonality_profile
--       .current_month_factor, COALESCEd to 1.0 when NULL/never-sold).
--   min_band (the REORDER POINT) = rhythm_adjusted_demand x p_lead_days + safety.
--     safety = safety_days x rhythm_adjusted_demand, safety_days by KVI band
--     (config kvi_safety_days): Critical=4, Important=2, everything else
--     (Standard/Long-tail/Consumable-carve)=0 -- "no floor guarantee" per
--     s2b #4, matches Pieter's law that only true KVIs get a protected floor.
--   max_band (the ORDER-UP-TO level) = min_band + rhythm_adjusted_demand x
--     review_days_used. ADDITIVE, not a competing absolute ceiling -- safety
--     days sit BENEATH the build, they are never a tax deducted from it.
--     review_days_used = p_target_cover_days (default 7, same standing cover
--     BLOOM-002 already uses), HALVED (config p_gmroi_cap_review_factor,
--     default 0.5) for bottom-GMROI-quartile Standard/Long-tail/Consumable
--     lines -- narrower build, funded less on poor-GMROI stock, but NEVER
--     zero (PM, 2026-07-08: "gmroi_capped reduces review_period and never
--     collapses the band"). KVI-Critical/Important are NEVER reduced this
--     way regardless of GMROI (the floor always wins, s2b #4/#5). This
--     0.5 factor is CC's own reasonable interim choice, not something PM
--     specified as an exact number -- flagged for confirmation, not asserted
--     as settled (R27 s7).
--   shelf-life cap -- SKIPPED, always (L1 does not carry shelf life yet, R23
--     named DEBT, never silently applied as if it were there;
--     shelf_life_cap_skipped=true on every row, no exceptions).
--   Worked numbers (PM's own reconciliation, both SPAR stores, p_lead_days=
--   3.5, p_target_cover_days=7): KVI_CRITICAL min=7.5d-equiv, max=14.5d-equiv
--   (width 7d). KVI_IMPORTANT min=5.5d, max=12.5d (width 7d). STANDARD/
--   LONG_TAIL min=3.5d, max=10.5d (width 7d, or 3.5d if GMROI-capped).
--   Every non-GMROI-capped band now has the SAME 7-day width regardless of
--   KVI tier -- the safety ladder changes the FLOOR, never the BUILD.
--
-- BAND_BLOCKED (backtest-added BINDING condition #1, Phase 3 verdict): the
-- band computes but is flagged untrustworthy when the SOH it nets off is
-- itself unverified. Uses the same signal as the cascade's own routing:
-- l2_classification.bucket IN ('COUNT','AMBIGUOUS') -- exactly the buckets
-- canon already defines as "claims stock, needs a physical count before it's
-- trusted" (s8.5 lines 2b/3/6/9). band_blocked rows still carry a computed
-- band (never silently dropped, R21 s5) but the Recipe RPC/screen must
-- surface "band blocked, count first" and route to the stocktake queue
-- rather than order against the paper SOH.
--
-- ENG-001 CRITICAL, v1 FIX REJECTED, v2 FIX BELOW (PM, 2026-07-08):
-- v1 found: max_band was never floored on min_band -- min = demand x
-- (safety_days + lead_days); max = demand x target_cover_days. For
-- KVI_CRITICAL (7.5d min vs 7d cover) min > max on 400/400 lines, both SPAR
-- stores.
-- v1 FIX (REJECTED same day, PM re-verified live): `GREATEST(min_band,
-- cover_candidate)` stops the inversion but LIFTS max ONTO min rather than
-- above it -- every KVI_CRITICAL line got a ZERO-WIDTH band (order-up-to ==
-- reorder point), the only band in either store that thin. The recipe would
-- have ordered each KVI-Critical line exactly back to its trigger, every
-- drop, never building real cover -- the KVI floor still would not have
-- functioned, just without the visible inversion. Worse: the post-condition
-- (max_band >= min_band) could not fail, because GREATEST guarantees it by
-- construction -- "an assertion that cannot fail is not a proof" (PM, R22).
-- Root cause restated: target_cover_days was being used as a competing
-- ABSOLUTE ceiling instead of a BUFFER added on top of the reorder point, so
-- safety days acted as a tax deducted from cover, not a floor beneath it --
-- the more critical the line, the thinner its band, exactly backwards.
-- v2 FIX (this file): max_band = min_band + demand x review_days_used,
-- ADDITIVE construction -- the invariant max_band >= min_band (in fact
-- STRICTLY greater whenever demand > 0) holds by the arithmetic itself, not
-- by a clamp. max_band_uncapped now reports what max WOULD be without any
-- GMROI reduction (min_band + demand x p_target_cover_days), so the GMROI
-- effect stays visible and auditable (R29) rather than hidden inside one
-- number.
-- ACCEPTANCE, PER PM'S OWN INSTRUCTION: a WIDTH test, not an inversion test
-- -- no row with rhythm_adjusted_demand > 0 may have max_band = min_band.
-- ASSERTED as a post-condition at the end of every refresh (both the basic
-- max>=min invariant AND the width test): the function RAISES and rolls
-- back if either is violated by its own output, so this class of bug can
-- never ship silently again -- and this time the width test is a real check,
-- not a clamp restated as a proof.
--
-- ENG-003 FIX (PM, 2026-07-08): this object's pool was an INDEPENDENT query
-- against l2_stock_position (WHERE class='NORMAL'), not the SAME rows
-- l2_kvi_profile actually profiled -- 70 rows at 80175 existed in this
-- object's pool but not in l2_kvi_profile (refresh-timing drift, ENG-002),
-- and defaulted to kvi_band='STANDARD' via COALESCE -- a hidden L2 choice
-- (R27 s2: "a calculation that needed a choice... is a branch wearing a
-- fact's clothes"), not a derived fact. Fix: pool is now sourced FROM
-- l2_kvi_profile directly (INNER JOIN to l2_stock_position for daily_ros) --
-- a product with no KVI profile yet gets NO stock band yet, rather than a
-- silently-defaulted one. This drift disappears entirely once ENG-002
-- (nightly wiring, all six objects refreshed in one pass) lands.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_stock_band (
  client_id                text NOT NULL DEFAULT 'socialbrand',
  store_code                text NOT NULL,
  product_code              bigint NOT NULL,
  daily_ros                 numeric,
  week_index_used           numeric NOT NULL DEFAULT 1.0,
  month_factor_used         numeric NOT NULL DEFAULT 1.0,
  rhythm_adjusted_demand    numeric,
  kvi_band                  text,
  safety_days_used          numeric NOT NULL DEFAULT 0,
  lead_days_used            numeric NOT NULL,
  min_band                  numeric,
  target_cover_days_used    numeric NOT NULL,
  max_band_uncapped         numeric,
  gmroi_quartile            int,
  gmroi_capped              boolean NOT NULL DEFAULT false,
  shelf_life_cap_skipped    boolean NOT NULL DEFAULT true,
  max_band                  numeric,
  max_floored_to_min        boolean NOT NULL DEFAULT false,
  band_blocked              boolean NOT NULL DEFAULT false,
  band_blocked_reason       text,
  engine_version            text NOT NULL DEFAULT 'v1.0',
  profiled_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_stock_band_blocked ON public.l2_stock_band (store_code, band_blocked);

REVOKE ALL ON public.l2_stock_band FROM PUBLIC;
GRANT SELECT ON public.l2_stock_band TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_stock_band(
  p_store                     text,
  p_lead_days                 numeric DEFAULT 3.5,
  p_target_cover_days         numeric DEFAULT 7,
  p_gmroi_cap_review_factor   numeric DEFAULT 0.5
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date;
  v_dom int;
  v_rows int;
  v_violations int;
  v_zero_width int;
BEGIN
  SELECT MAX(sale_date) INTO v_anchor
  FROM public.sigma_sales
  WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1;

  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('store_code', p_store, 'rows', 0, 'error', 'no sigma_sales rows for this store');
  END IF;

  v_dom := EXTRACT(DAY FROM v_anchor)::int;

  DELETE FROM public.l2_stock_band WHERE store_code = p_store;

  WITH latest_bucket AS (
    SELECT DISTINCT ON (product_code) product_code, bucket
    FROM public.l2_classification
    WHERE store_code = p_store
    ORDER BY product_code, snapshot_date DESC
  ),
  pool AS (
    -- ENG-003 fix: pool IS l2_kvi_profile's own rows (INNER JOIN), never an
    -- independent re-query of l2_stock_position that can drift out of step
    -- with what KVI actually profiled. No product reaches this table without
    -- a real, derived kvi_band.
    SELECT k.product_code, k.kvi_band, sp.daily_ros
    FROM public.l2_kvi_profile k
    JOIN public.l2_stock_position sp ON sp.store_code = k.store_code AND sp.product_code = k.product_code
    WHERE k.store_code = p_store
  ),
  joined AS (
    SELECT p.product_code, COALESCE(p.daily_ros, 0) AS daily_ros, p.kvi_band,
           CASE WHEN v_dom BETWEEN 1 AND 7 THEN rp.w1_index
                WHEN v_dom BETWEEN 8 AND 14 THEN rp.w2_index
                WHEN v_dom BETWEEN 15 AND 21 THEN rp.w3_index
                ELSE rp.w4_index END AS week_index_raw,
           sea.current_month_factor,
           g.gmroi_quartile,
           lb.bucket
    FROM pool p
    LEFT JOIN public.l2_rhythm_profile rp ON rp.store_code = p_store AND rp.product_code = p.product_code
    LEFT JOIN public.l2_seasonality_profile sea ON sea.store_code = p_store AND sea.product_code = p.product_code
    LEFT JOIN public.l2_gmroi_profile g ON g.store_code = p_store AND g.product_code = p.product_code
    LEFT JOIN latest_bucket lb ON lb.product_code = p.product_code
  ),
  computed AS (
    SELECT product_code, daily_ros, kvi_band,
      COALESCE(week_index_raw, 1.0) AS week_index_used,
      COALESCE(current_month_factor, 1.0) AS month_factor_used,
      -- GREATEST(...,0): l2_stock_position.daily_ros can itself be negative
      -- (a line whose 91d till returns net-exceed its sales) -- caught live,
      -- 2026-07-08, 6 rows at 10116. Negative demand has no sane meaning for
      -- an order-quantity formula; a net-returning line is zero demand for
      -- ordering purposes, not negative demand propagating through min/max.
      GREATEST(daily_ros * COALESCE(week_index_raw, 1.0) * COALESCE(current_month_factor, 1.0), 0) AS rhythm_adjusted_demand,
      CASE kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END AS safety_days,
      gmroi_quartile,
      (COALESCE(bucket, '') IN ('COUNT', 'AMBIGUOUS')) AS band_blocked,
      bucket
    FROM joined
  ),
  banded AS (
    SELECT product_code, daily_ros, kvi_band, week_index_used, month_factor_used,
      rhythm_adjusted_demand, safety_days, gmroi_quartile, band_blocked, bucket,
      -- min_band is the REORDER POINT. Unchanged from v1 -- this part was
      -- always right.
      (rhythm_adjusted_demand * p_lead_days) + (safety_days * rhythm_adjusted_demand) AS min_candidate,
      (COALESCE(gmroi_quartile = 1, false) AND kvi_band NOT IN ('KVI_CRITICAL', 'KVI_IMPORTANT')) AS gmroi_capped
    FROM computed
  ),
  reviewed AS (
    SELECT *,
      -- review_days_used: the BUILD, added ON TOP of min_candidate, never a
      -- competing ceiling. GMROI-capped lines get a narrower (halved, not
      -- zeroed) build -- PM, 2026-07-08: "never collapses the band."
      CASE WHEN gmroi_capped THEN p_target_cover_days * p_gmroi_cap_review_factor
           ELSE p_target_cover_days END AS review_days_used
    FROM banded
  )
  INSERT INTO public.l2_stock_band (
    client_id, store_code, product_code, daily_ros, week_index_used, month_factor_used,
    rhythm_adjusted_demand, kvi_band, safety_days_used, lead_days_used, min_band,
    target_cover_days_used, max_band_uncapped, gmroi_quartile, gmroi_capped,
    shelf_life_cap_skipped, max_band, max_floored_to_min, band_blocked, band_blocked_reason,
    engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code, daily_ros, week_index_used, month_factor_used,
    rhythm_adjusted_demand, kvi_band, safety_days,
    p_lead_days,
    min_candidate AS min_band,
    p_target_cover_days,
    -- max_band_uncapped: what max WOULD be with the FULL (non-GMROI-reduced)
    -- build -- the GMROI effect stays visible as a delta, never hidden.
    min_candidate + (rhythm_adjusted_demand * p_target_cover_days) AS max_band_uncapped,
    gmroi_quartile,
    gmroi_capped,
    true,
    -- ENG-001 v2 fix: ADDITIVE. max_band >= min_band holds by construction
    -- (in fact strictly greater whenever demand > 0), never a clamp.
    min_candidate + (rhythm_adjusted_demand * review_days_used) AS max_band,
    (rhythm_adjusted_demand * review_days_used) = 0 AS max_floored_to_min,
    band_blocked,
    CASE WHEN band_blocked THEN 'bucket=' || bucket || ': band blocked, count first' ELSE NULL END,
    'v1.0', now()
  FROM reviewed;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- POST-CONDITIONS (PM, 2026-07-08): two checks, not one. The plain
  -- inversion check stays as a backstop; the WIDTH test is the real
  -- acceptance criterion this time -- "no line with rhythm_adjusted_demand
  -- > 0 may have max_band = min_band." Both RAISE and roll back the
  -- transaction on violation.
  SELECT COUNT(*) INTO v_violations
  FROM public.l2_stock_band
  WHERE store_code = p_store AND max_band < min_band;

  IF v_violations > 0 THEN
    RAISE EXCEPTION 'l2_stock_band invariant violated: % row(s) at store % have max_band < min_band', v_violations, p_store;
  END IF;

  SELECT COUNT(*) INTO v_zero_width
  FROM public.l2_stock_band
  WHERE store_code = p_store AND rhythm_adjusted_demand > 0 AND max_band = min_band;

  IF v_zero_width > 0 THEN
    RAISE EXCEPTION 'l2_stock_band width test failed: % row(s) at store % have a zero-width band with real demand', v_zero_width, p_store;
  END IF;

  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'day_of_month', v_dom, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric, numeric) TO authenticated;
