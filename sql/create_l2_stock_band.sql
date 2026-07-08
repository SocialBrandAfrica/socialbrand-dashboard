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
-- FORMULA (BLOOM-003 s2b #4):
--   rhythm_adjusted_demand = l2_stock_position.daily_ros
--     x this-week's index (from l2_rhythm_profile, W1-W4 by today's
--       day-of-month, COALESCEd to 1.0 -- EVERYDAY archetype lines are
--       already near 1.0 by construction so this is a correct no-op there)
--     x this-month's seasonality factor (l2_seasonality_profile
--       .current_month_factor, COALESCEd to 1.0 when NULL/never-sold).
--   min = rhythm_adjusted_demand x p_lead_days + safety.
--     safety = safety_days x rhythm_adjusted_demand, safety_days by KVI band
--     (config kvi_safety_days): Critical=4, Important=2, everything else
--     (Standard/Long-tail/Consumable-carve)=0 -- "no floor guarantee" per
--     s2b #4, matches Pieter's law that only true KVIs get a protected floor.
--   max = LEAST of:
--     (a) rhythm_adjusted_demand x p_target_cover_days (config, default 7,
--         same standing cover the DC recipe already uses -- BLOOM-002),
--     (b) shelf-life cap -- SKIPPED, always (L1 does not carry shelf life
--         yet, R23 named DEBT, never silently applied as if it were there;
--         shelf_life_cap_skipped=true on every row, no exceptions),
--     (c) GMROI cap: bottom-GMROI-quartile (l2_gmroi_profile.gmroi_quartile
--         =1) Standard/Long-tail/Consumable-carve lines cap max AT min (no
--         cover build funded on poor-GMROI stock) -- KVI-Critical/Important
--         are NEVER capped this way regardless of GMROI (the floor always
--         wins, s2b #4/#5).
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
-- ENG-001 CRITICAL FIX (PM, 2026-07-08): max_band was never floored on
-- min_band. min = demand x (safety_days + lead_days); max = demand x
-- target_cover_days. For KVI_CRITICAL (safety 4d, lead 3.5d default = 7.5d)
-- against the 7-day default cover, min > max on EVERY KVI_CRITICAL line, both
-- SPAR stores, 400/400 -- the KVI floor's own protection window is wider
-- than its own build ceiling, so a recipe filling to max_band would order
-- every protected line to a level BELOW its own reorder point. This is the
-- exact 10116 failure the backtest found (KVIs falling with the store)
-- rebuilt into the engine as a structural bug, not a data problem -- caught
-- by inspecting one worked line (product 198 @ 80175), not by the GMROI-cap
-- check (which is honest and separately correct: all 400 lines are
-- quartile 4 and never GMROI-capped, so that test passed over a band that
-- was already inverted before the cap ran). THE MISSING INVARIANT:
-- max_band >= min_band, always. Fix: max_band = GREATEST(min_band, the
-- previously-computed ceiling), max_floored_to_min=true logs every row where
-- the floor actually fired (R29 -- the reason travels with the number).
-- max_band_uncapped stays the PURE pre-floor cover-target value (unchanged,
-- it is precisely what let this bug surface -- never hide the raw number
-- behind the corrected one). ASSERTED as a post-condition at the end of
-- every refresh: the function RAISES and rolls back if any row of its own
-- output violates the invariant, so this class of bug can never ship silently
-- again.
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
  p_store               text,
  p_lead_days           numeric DEFAULT 3.5,
  p_target_cover_days   numeric DEFAULT 7
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date;
  v_dom int;
  v_rows int;
  v_violations int;
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
      daily_ros * COALESCE(week_index_raw, 1.0) * COALESCE(current_month_factor, 1.0) AS rhythm_adjusted_demand,
      CASE kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END AS safety_days,
      gmroi_quartile,
      (COALESCE(bucket, '') IN ('COUNT', 'AMBIGUOUS')) AS band_blocked,
      bucket
    FROM joined
  ),
  banded AS (
    SELECT product_code, daily_ros, kvi_band, week_index_used, month_factor_used,
      rhythm_adjusted_demand, safety_days, gmroi_quartile, band_blocked, bucket,
      (rhythm_adjusted_demand * p_lead_days) + (safety_days * rhythm_adjusted_demand) AS min_candidate,
      rhythm_adjusted_demand * p_target_cover_days AS cover_candidate,
      (COALESCE(gmroi_quartile = 1, false) AND kvi_band NOT IN ('KVI_CRITICAL', 'KVI_IMPORTANT')) AS gmroi_capped
    FROM computed
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
    cover_candidate AS max_band_uncapped,
    gmroi_quartile,
    gmroi_capped,
    true,
    -- ENG-001 fix: the invariant, enforced unconditionally. GMROI-capped
    -- lines already equal min_candidate (by design, s2b #4); everything else
    -- is floored on min_candidate so max_band can never sit below min_band.
    GREATEST(min_candidate, CASE WHEN gmroi_capped THEN min_candidate ELSE cover_candidate END) AS max_band,
    (NOT gmroi_capped AND cover_candidate < min_candidate) AS max_floored_to_min,
    band_blocked,
    CASE WHEN band_blocked THEN 'bucket=' || bucket || ': band blocked, count first' ELSE NULL END,
    'v1.0', now()
  FROM banded;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- POST-CONDITION (PM, 2026-07-08): assert the invariant on THIS store's own
  -- output before returning success. A future regression fails loudly here,
  -- transaction rolled back, never a silent inverted band reaching the RPC.
  SELECT COUNT(*) INTO v_violations
  FROM public.l2_stock_band
  WHERE store_code = p_store AND max_band < min_band;

  IF v_violations > 0 THEN
    RAISE EXCEPTION 'l2_stock_band invariant violated: % row(s) at store % have max_band < min_band', v_violations, p_store;
  END IF;

  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'day_of_month', v_dom, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric) TO authenticated;
