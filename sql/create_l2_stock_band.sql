-- =============================================================================
-- create_l2_stock_band.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #5 of 5 (BLOOM-003 s2/s2b #4).
-- Depends on l2_kvi_profile, l2_rhythm_profile, l2_seasonality_profile,
-- l2_gmroi_profile, l2_bloom_ros_pantry. R28: effective_from 2026-07-07,
-- ENG-004 fix effective_from 2026-07-10. Formula GENERAL, constants
-- DEMO_CALIBRATION.
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
-- ============================== ENG-004 (2026-07-10) ==============================
-- REPOINTED, folding in the ENG-005 family-draw fix at the same time (the
-- milk KVI-floor case that started ENG-005 was never actually fixed here --
-- ENG-005 repointed the DC ORDER's demand; this object, the KVI floor that
-- STOCK BAND itself computes, still read raw l2_stock_position.daily_ros
-- until now). Two problems, one fix, per Pieter's standing rulings:
--
-- PROBLEM 1 (the original ENG-004 finding): rhythm_adjusted_demand read RAW
-- l2_stock_position.daily_ros (91d, sigma_sales-based) -- no stockout
-- correction at all, violating the 2026-07-03 ruling (canon s14 addendum v2:
-- "CORRECTED ROS DRIVES QUANTITIES, WITH GUARDS"). A phantom-gone-quiet line's
-- raw ROS decays and the band shrinks to match the decay -- DF-7 written into
-- the demand input of every band.
--
-- PROBLEM 2 (ENG-005's actual gap here): even the CORRECTED scan-side ROS
-- undercounts a parent-child family (canon s14 v5 / BLOOM-003 s7) -- the same
-- gap ENG-005 closed in rpc_bloom_order_dc, never closed here. Live proof
-- carried since ENG-005's own finding: milk (10116/1674) with a 503/day real
-- family draw against a band built on ~38/day scan-based demand, a KVI floor
-- of 0.7 days on the store's own biggest KVI-Critical line.
--
-- FIX: demand is now resolved from `l2_bloom_ros_pantry`'s 56d window (the
-- BOR/"standing cadence" window, the closest analogue this cadence-general
-- object has to a single representative rate -- this object has no ranging
-- tier of its own to pick 14d/28d/56d by, R27 s7 stated assumption, not one
-- of the load-bearing confrontations) in TWO stages:
--   Stage A -- GUARD each side independently (both scan and family-draw carry
--     their own stockout-correction and their own eligibility, since they are
--     two independently-computed p_sell_estimate series):
--     1. Eligibility: KVI_CRITICAL/KVI_IMPORTANT bands are eligible for the
--        correction BY DEFAULT (signal-rich, protected-floor lines -- the
--        canon s14 T100/T1000 precedent, adapted from ranging tier to KVI
--        band since this object has no ranging tier of its own, R27 s7).
--        STANDARD/LONG_TAIL/CONSUMABLE_CARVE are eligible ONLY via guard 1:
--        >=8 distinct selling days in the trailing 182d (read directly off
--        the pantry's own p_sell_estimate x 182 -- that field IS "share of
--        days with a sale over a 182d lookback", so x182 recovers the day
--        count with no new computation).
--     2. Cap: the corrected value used is capped at 2.0x the matching raw
--        value, on each side independently.
--     3. Ineligible lines use their raw (uncorrected) value on that side --
--        never a wrong number standing in for a real one.
--   Stage B -- GREATEST(scan_side_result, draw_side_result), same governing
--     law as ENG-005 and BUG-LOG ENG-005B: a real till scan already proves
--     units moved, so a ledger-side gap never lowers demand below the scan
--     floor; a real family draw raises it when the scan side loses the
--     family. `demand_source` names which side won, per row (R29).
-- The multiplier step (week index x month factor) applies AFTER Stage B,
-- unchanged from v1 -- rhythm and seasonality adjust the RESOLVED demand,
-- they do not participate in picking which side (scan/draw) is more real.
--
-- ============================ SOH-FLOW POST-CONDITION (2026-07-10) ============================
-- Folded in per Pieter/PM ruling: a line whose own ledger will not close
-- against its observed SOH change routes to count, exactly as the stocktake
-- side of the cascade already does for the same reason (canon s8.5, s11) --
-- SOH is the claim, the ledger is the evidence, and a claim the ledger can't
-- explain is unverified, not proven.
--   Check: soh_start (l2_soh_daily's EARLIEST available snapshot at this
--   store) + net movements (K sale + R receipt + S adjustment, ALL channels
--   except I) over that span, compared to soh_end (l2_soh_daily's LATEST
--   snapshot). A stocktake (I) anywhere in the span legitimately re-anchors
--   SOH by design -- that is not a mismatch, it is a fresh count, so it
--   short-circuits the check to "closes".
--   NAMED L1 GAP (R23, stated not hidden): l2_soh_daily's history is ~29 days
--   deep at every store as of 2026-07-10 (verified: 10116/21355/80175/80176
--   28-29 days, 80579 only 15), NOT the 91 days a demand-window-matched check
--   would ideally use. `soh_flow_window_days` reports the ACTUAL span checked
--   per store so the confidence of a "closes" verdict is visible, never
--   implied to be longer than it is. Below 14 days of available history the
--   check does not run at all (`soh_flow_closes` stays NULL, "not checked" --
--   never a false pass). Tolerance: GREATEST(2 units, 5% of demand x window
--   days) -- matches RULE-BOOK R22 s13.2's standing ~1% cross-feed drift
--   allowance, widened for the shorter window's proportionally larger noise.
--   A mismatch folds into the EXISTING band_blocked mechanism (previously
--   only l2_classification.bucket IN ('COUNT','AMBIGUOUS')) with its own
--   named reason -- one signal, two roads in, the screen already knows how
--   to render "band blocked, count first" for either.
--
-- FORMULA (BLOOM-003 s2b #4, min/max construction UNCHANGED from ENG-001 v2 --
-- only the demand INPUT changed, ENG-004 above):
--   min_band (the REORDER POINT) = rhythm_adjusted_demand x p_lead_days + safety.
--     safety = safety_days x rhythm_adjusted_demand, safety_days by KVI band
--     (config kvi_safety_days): Critical=4, Important=2, everything else
--     (Standard/Long-tail/Consumable-carve)=0 -- "no floor guarantee" per
--     s2b #4, matches Pieter's law that only true KVIs get a protected floor.
--   max_band (the ORDER-UP-TO level) = min_band + rhythm_adjusted_demand x
--     review_days_used. ADDITIVE, not a competing absolute ceiling -- safety
--     days sit BENEATH the build, they are never a tax deducted from it.
--     review_days_used = p_target_cover_days (default 7), HALVED (config
--     p_gmroi_cap_review_factor, default 0.5) for bottom-GMROI-quartile
--     Standard/Long-tail/Consumable lines -- narrower build, never zero.
--     KVI-Critical/Important are NEVER reduced this way regardless of GMROI.
--   shelf-life cap -- SKIPPED, always (L1 does not carry shelf life yet, R23
--     named DEBT, never silently applied as if it were there;
--     shelf_life_cap_skipped=true on every row, no exceptions).
--
-- ENG-001 CRITICAL, v1 FIX REJECTED, v2 FIX (PM, 2026-07-08, UNCHANGED here):
-- max_band = min_band + demand x review_days_used, ADDITIVE construction --
-- the invariant max_band >= min_band (in fact STRICTLY greater whenever
-- demand > 0) holds by the arithmetic itself, not by a clamp.
-- ACCEPTANCE, PER PM'S OWN INSTRUCTION: a WIDTH test, not an inversion test
-- -- no row with rhythm_adjusted_demand > 0 may have max_band = min_band.
-- ASSERTED as a post-condition at the end of every refresh: the function
-- RAISES and rolls back if either invariant is violated by its own output.
--
-- ENG-003 FIX (PM, 2026-07-08, UNCHANGED here): pool is sourced FROM
-- l2_kvi_profile directly (INNER JOIN to l2_stock_position) -- no
-- independent re-query that can drift out of step with what KVI profiled.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_stock_band CASCADE;

CREATE TABLE public.l2_stock_band (
  client_id                 text NOT NULL DEFAULT 'socialbrand',
  store_code                text NOT NULL,
  product_code              bigint NOT NULL,
  daily_ros                 numeric,
  ros_scan_raw              numeric,
  ros_scan_used             numeric,
  scan_eligible             boolean NOT NULL DEFAULT false,
  scan_eligibility_reason   text,
  ros_draw_raw              numeric,
  ros_draw_used             numeric,
  draw_eligible             boolean NOT NULL DEFAULT false,
  draw_eligibility_reason  text,
  demand_source             text NOT NULL DEFAULT 'scan',
  base_demand               numeric,
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
  soh_flow_closes           boolean,
  soh_flow_window_days      int,
  soh_flow_reason           text,
  -- W1.2 (SB-CC-BLOOM-017): which pantry guard set the rate this band drank.
  ros_scan_guard            text,
  ros_draw_guard            text,
  -- W1.5: the ledger-flow residual, SURFACED WITH NO VERDICT. It used to be a second
  -- road into band_blocked and fired on 94% of CORE at 10116, all bucket HEALTHY.
  -- A flag that fires on everything says nothing (BUG-LOG ENG-041 discipline).
  soh_flow_open             boolean,
  -- W1.6 / ENG-045: the forward leg. The lift applies ONCE, here.
  promo_in_buyin_window     boolean NOT NULL DEFAULT false,
  promo_nr                  bigint,
  promo_window_start        date,
  promo_window_end          date,
  promo_uplift_used         numeric NOT NULL DEFAULT 1.0,
  promo_uplift_source       text,
  promo_uplift_basis        text,   -- own_promo | own_promo_provisional_capped_uplift | no_promo_window
  demand_pre_promo          numeric,
  band_blocked              boolean NOT NULL DEFAULT false,
  band_blocked_reason       text,
  -- W1.5: band_blocked is now its DOCUMENTED definition ONLY --
  -- l2_classification.bucket IN ('COUNT','AMBIGUOUS'). 19.3% -> 1.7% at 10116.
  engine_version            text NOT NULL DEFAULT 'v3.1',
  profiled_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX idx_l2_stock_band_blocked ON public.l2_stock_band (store_code, band_blocked);

REVOKE ALL ON public.l2_stock_band FROM PUBLIC;
GRANT SELECT ON public.l2_stock_band TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_stock_band(p_store text, p_lead_days numeric DEFAULT 3.5, p_target_cover_days numeric DEFAULT 7, p_gmroi_cap_review_factor numeric DEFAULT 0.5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date; v_dom int; v_rows int; v_violations int; v_zero_width int;
  v_buyin_lead int; v_uplift_cap numeric;
BEGIN
  SELECT MAX(sale_date) INTO v_anchor FROM public.sigma_sales
  WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1;
  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('store_code', p_store, 'rows', 0, 'error', 'no sigma_sales rows for this store');
  END IF;
  v_dom := EXTRACT(DAY FROM v_anchor)::int;

  SELECT COALESCE(MAX(promo_buyin_lead_days), 7) INTO v_buyin_lead
  FROM public.supplier_calendar WHERE store_code = p_store;
  SELECT COALESCE(MAX(value_num), 5.0) INTO v_uplift_cap
  FROM public.forge_config WHERE config_key='promo_uplift_cap' AND retired_on IS NULL;

  DELETE FROM public.l2_stock_band WHERE store_code = p_store;

  WITH latest_bucket AS (
    SELECT DISTINCT ON (product_code) product_code, bucket FROM public.l2_classification
    WHERE store_code = p_store ORDER BY product_code, snapshot_date DESC
  ),
  pool AS (
    SELECT k.product_code, k.kvi_band, sp.daily_ros
    FROM public.l2_kvi_profile k
    JOIN public.l2_stock_position sp ON sp.store_code = k.store_code AND sp.product_code = k.product_code
    WHERE k.store_code = p_store
  ),
  promo_win AS (
    SELECT DISTINCT ON (pa.product_code) pa.product_code, p.promo_nr,
           (p.start_date - v_buyin_lead) AS promo_window_start, p.end_date AS promo_window_end
    FROM public.sigma_promotions p
    JOIN public.sigma_promotion_articles pa ON pa.store_code=p.store_code AND pa.promo_nr=p.promo_nr
    WHERE p.store_code = p_store AND COALESCE(p.status,'') <> 'I'
      AND v_anchor >= (p.start_date - v_buyin_lead) AND v_anchor <= p.end_date
    ORDER BY pa.product_code, p.start_date DESC, p.promo_nr DESC
  ),
  soh_window AS (SELECT MIN(snapshot_date) win_start, MAX(snapshot_date) win_end
                 FROM public.l2_soh_daily WHERE store_code = p_store),
  soh_start_snap AS (SELECT sd.product_code, sd.soh soh_start FROM public.l2_soh_daily sd, soh_window w
                     WHERE sd.store_code=p_store AND sd.snapshot_date=w.win_start),
  soh_end_snap AS (SELECT sd.product_code, sd.soh soh_end FROM public.l2_soh_daily sd, soh_window w
                   WHERE sd.store_code=p_store AND sd.snapshot_date=w.win_end),
  movement_flow AS (
    SELECT sm.product_code, SUM(sm.qty) net_qty, bool_or(sm.movement_type='I') had_stocktake
    FROM public.sigma_movements sm, soh_window w
    WHERE sm.store_code=p_store AND sm.movement_type IN ('K','R','S')
      AND sm.movement_date > w.win_start AND sm.movement_date <= w.win_end
    GROUP BY sm.product_code
  ),
  joined AS (
    SELECT p.product_code, COALESCE(p.daily_ros,0) daily_ros, p.kvi_band,
      CASE WHEN v_dom BETWEEN 1 AND 7 THEN rp.w1_index WHEN v_dom BETWEEN 8 AND 14 THEN rp.w2_index
           WHEN v_dom BETWEEN 15 AND 21 THEN rp.w3_index ELSE rp.w4_index END AS week_index_raw,
      sea.current_month_factor, g.gmroi_quartile, lb.bucket,
      rop.ros_56d scan_raw, rop.ros_56d_published scan_published, rop.ros_56d_guard scan_guard,
      rop.p_sell_estimate p_sell_scan,
      rop.ros_draw_56d draw_raw, rop.ros_draw_56d_published draw_published,
      rop.ros_draw_56d_guard draw_guard, rop.p_sell_estimate_draw p_sell_draw,
      rop.unit_incommensurable,
      ss.soh_start, se.soh_end, mf.net_qty, mf.had_stocktake, w.win_start, w.win_end,
      pw.promo_nr, pw.promo_window_start, pw.promo_window_end,
      pp.promo_uplift, pp.promo_uplift_source
    FROM pool p
    LEFT JOIN public.l2_rhythm_profile rp ON rp.store_code=p_store AND rp.product_code=p.product_code
    LEFT JOIN public.l2_seasonality_profile sea ON sea.store_code=p_store AND sea.product_code=p.product_code
    LEFT JOIN public.l2_gmroi_profile g ON g.store_code=p_store AND g.product_code=p.product_code
    LEFT JOIN latest_bucket lb ON lb.product_code=p.product_code
    LEFT JOIN public.l2_bloom_ros_pantry rop ON rop.store_code=p_store AND rop.product_code=p.product_code
    LEFT JOIN soh_start_snap ss ON ss.product_code=p.product_code
    LEFT JOIN soh_end_snap se ON se.product_code=p.product_code
    LEFT JOIN movement_flow mf ON mf.product_code=p.product_code
    LEFT JOIN promo_win pw ON pw.product_code=p.product_code
    LEFT JOIN public.l2_bloom_promo_pantry pp ON pp.store_code=p_store AND pp.product_code=p.product_code
    CROSS JOIN soh_window w
  ),
  guarded AS (
    SELECT j.*, COALESCE(j.scan_raw,0) scan_raw_g, COALESCE(j.draw_raw,0) draw_raw_g,
      ROUND(COALESCE(j.p_sell_scan,0)*182) scan_selling_days,
      ROUND(COALESCE(j.p_sell_draw,0)*182) draw_selling_days,
      (j.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(j.p_sell_scan,0)*182 >= 8) scan_eligible,
      (NOT COALESCE(j.unit_incommensurable,true)
        AND (j.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(j.p_sell_draw,0)*182 >= 8)) draw_eligible
    FROM joined j
  ),
  capped AS (
    SELECT g.*,
      CASE WHEN g.scan_eligible AND g.scan_published IS NOT NULL THEN GREATEST(g.scan_published,0)
           ELSE g.scan_raw_g END AS scan_used,
      CASE WHEN g.draw_eligible AND g.draw_published IS NOT NULL THEN GREATEST(g.draw_published,0)
           WHEN NOT COALESCE(g.unit_incommensurable,true) THEN g.draw_raw_g ELSE NULL END AS draw_used
    FROM guarded g
  ),
  resolved AS (
    SELECT c.*,
      GREATEST(c.scan_used, COALESCE(c.draw_used,0)) base_demand,
      (COALESCE(c.draw_used,0) > c.scan_used) demand_from_draw,
      CASE WHEN c.scan_eligible THEN 'kvi_floor_or_guard1_eligible ('||c.scan_selling_days||'d/182d, guard='||COALESCE(c.scan_guard,'no_pantry_row')||')'
           ELSE 'ineligible_raw_used ('||c.scan_selling_days||'d/182d, need 8)' END scan_eligibility_reason,
      CASE WHEN COALESCE(c.unit_incommensurable,true) THEN 'unit_incommensurable_no_draw'
           WHEN c.draw_eligible THEN 'kvi_floor_or_guard1_eligible ('||c.draw_selling_days||'d/182d, guard='||COALESCE(c.draw_guard,'no_pantry_row')||')'
           ELSE 'ineligible_raw_used ('||c.draw_selling_days||'d/182d, need 8)' END draw_eligibility_reason,
      (c.win_end - c.win_start) soh_flow_window_days,
      CASE WHEN (c.win_end-c.win_start) < 14 THEN NULL
           WHEN c.had_stocktake THEN true
           WHEN c.soh_start IS NULL OR c.soh_end IS NULL THEN NULL
           ELSE ABS((c.soh_start+COALESCE(c.net_qty,0))-c.soh_end)
                <= GREATEST(2, 0.05*GREATEST(c.scan_raw_g,COALESCE(c.draw_raw_g,0))*(c.win_end-c.win_start))
      END soh_flow_closes,
      (c.promo_nr IS NOT NULL AND COALESCE(c.promo_uplift,1.0) > 1.0) promo_in_buyin_window,
      CASE WHEN c.promo_nr IS NOT NULL AND COALESCE(c.promo_uplift,1.0) > 1.0
           THEN c.promo_uplift ELSE 1.0 END promo_uplift_used,
      -- W1.6 at-cap marking (PM's owed gate): a capped uplift makes the lifted
      -- band a FLOOR, not a measurement. Named on the row, never silent.
      CASE WHEN c.promo_nr IS NULL OR COALESCE(c.promo_uplift,1.0) <= 1.0 THEN 'no_promo_window'
           WHEN c.promo_uplift >= v_uplift_cap THEN 'own_promo_provisional_capped_uplift'
           ELSE COALESCE(c.promo_uplift_source,'own_promo') END promo_uplift_basis
    FROM capped c
  ),
  computed AS (
    SELECT product_code, daily_ros, kvi_band,
      scan_raw_g, scan_used, scan_eligible, scan_eligibility_reason, scan_guard,
      draw_raw_g, draw_used, draw_eligible, draw_eligibility_reason, draw_guard,
      base_demand, demand_from_draw, soh_flow_closes, soh_flow_window_days,
      COALESCE(week_index_raw,1.0) week_index_used, COALESCE(current_month_factor,1.0) month_factor_used,
      promo_in_buyin_window, promo_nr, promo_window_start, promo_window_end,
      promo_uplift_used, promo_uplift_source, promo_uplift_basis,
      GREATEST(base_demand*COALESCE(week_index_raw,1.0)*COALESCE(current_month_factor,1.0),0) demand_pre_promo,
      GREATEST(base_demand*COALESCE(week_index_raw,1.0)*COALESCE(current_month_factor,1.0)*promo_uplift_used,0) rhythm_adjusted_demand,
      CASE kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END safety_days,
      gmroi_quartile, (COALESCE(bucket,'') IN ('COUNT','AMBIGUOUS')) bucket_blocked, bucket,
      (soh_flow_closes IS NOT NULL AND NOT soh_flow_closes) soh_flow_open
    FROM resolved
  ),
  banded AS (
    SELECT *, (rhythm_adjusted_demand*p_lead_days)+(safety_days*rhythm_adjusted_demand) min_candidate,
      (COALESCE(gmroi_quartile=1,false) AND kvi_band NOT IN ('KVI_CRITICAL','KVI_IMPORTANT')) gmroi_capped
    FROM computed
  ),
  reviewed AS (
    SELECT *, CASE WHEN gmroi_capped THEN p_target_cover_days*p_gmroi_cap_review_factor
                   ELSE p_target_cover_days END review_days_used FROM banded
  )
  INSERT INTO public.l2_stock_band (
    client_id, store_code, product_code, daily_ros,
    ros_scan_raw, ros_scan_used, scan_eligible, scan_eligibility_reason, ros_scan_guard,
    ros_draw_raw, ros_draw_used, draw_eligible, draw_eligibility_reason, ros_draw_guard,
    demand_source, base_demand, week_index_used, month_factor_used,
    demand_pre_promo, promo_in_buyin_window, promo_nr, promo_window_start,
    promo_window_end, promo_uplift_used, promo_uplift_source, promo_uplift_basis,
    rhythm_adjusted_demand, kvi_band, safety_days_used, lead_days_used, min_band,
    target_cover_days_used, max_band_uncapped, gmroi_quartile, gmroi_capped,
    shelf_life_cap_skipped, max_band, max_floored_to_min,
    soh_flow_closes, soh_flow_window_days, soh_flow_reason, soh_flow_open,
    band_blocked, band_blocked_reason, engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code, daily_ros,
    scan_raw_g, scan_used, scan_eligible, scan_eligibility_reason, scan_guard,
    draw_raw_g, draw_used, draw_eligible, draw_eligibility_reason, draw_guard,
    (CASE WHEN demand_from_draw THEN 'family_draw' ELSE 'scan' END), base_demand,
    week_index_used, month_factor_used,
    demand_pre_promo, promo_in_buyin_window, promo_nr, promo_window_start,
    promo_window_end, promo_uplift_used, promo_uplift_source, promo_uplift_basis,
    rhythm_adjusted_demand, kvi_band, safety_days, p_lead_days,
    min_candidate, p_target_cover_days,
    min_candidate + (rhythm_adjusted_demand*p_target_cover_days),
    gmroi_quartile, gmroi_capped, true,
    min_candidate + (rhythm_adjusted_demand*review_days_used),
    (rhythm_adjusted_demand*review_days_used) = 0,
    soh_flow_closes, soh_flow_window_days,
    (CASE WHEN soh_flow_closes IS NULL THEN 'not_checked_insufficient_history ('||soh_flow_window_days||'d available, need >=14)'
          WHEN soh_flow_closes THEN 'closes'
          ELSE 'open: ledger does not reconcile to observed SOH over '||soh_flow_window_days||'d (surfaced, NOT a band verdict -- W1.5)' END),
    soh_flow_open,
    bucket_blocked,
    CASE WHEN bucket_blocked THEN 'bucket='||bucket||': band blocked, count first' ELSE NULL END,
    'v3.1', now()
  FROM reviewed;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  SELECT COUNT(*) INTO v_violations FROM public.l2_stock_band
  WHERE store_code=p_store AND max_band < min_band;
  IF v_violations > 0 THEN
    RAISE EXCEPTION 'l2_stock_band invariant violated: % row(s) at store % have max_band < min_band', v_violations, p_store;
  END IF;

  SELECT COUNT(*) INTO v_zero_width FROM public.l2_stock_band
  WHERE store_code=p_store AND rhythm_adjusted_demand > 0 AND max_band = min_band;
  IF v_zero_width > 0 THEN
    RAISE EXCEPTION 'l2_stock_band width test failed: % row(s) at store % have a zero-width band with real demand', v_zero_width, p_store;
  END IF;

  RETURN jsonb_build_object('store_code',p_store,'rows',v_rows,'anchor',v_anchor,
    'promo_buyin_lead_days',v_buyin_lead,'promo_uplift_cap',v_uplift_cap,
    'promo_lifted_lines',(SELECT COUNT(*) FROM public.l2_stock_band WHERE store_code=p_store AND promo_in_buyin_window),
    'promo_at_cap_provisional',(SELECT COUNT(*) FROM public.l2_stock_band WHERE store_code=p_store AND promo_uplift_basis='own_promo_provisional_capped_uplift'),
    'band_blocked_lines',(SELECT COUNT(*) FROM public.l2_stock_band WHERE store_code=p_store AND band_blocked),
    'soh_flow_open_lines',(SELECT COUNT(*) FROM public.l2_stock_band WHERE store_code=p_store AND soh_flow_open),
    'engine_version','v3.1');
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_stock_band(text, numeric, numeric, numeric) TO authenticated;
