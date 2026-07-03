-- =============================================================================
-- create_l2_bloom_promo_pantry.sql
-- SB-CC-BLOOM-001. L2 pantry object per CLEANUP-ENGINE-CANON section 14:
-- `promo_uplift` only. R27: pure fact, scenario-blind, product-level,
-- date-independent. R28: effective_from 2026-07-02, scope GENERAL.
-- =============================================================================
-- WHY promo_eligibility(D,D2) AND promo_cost_delta are NOT in this table
-- (design decision, 2026-07-02): both depend on the caller's chosen delivery
-- dates (D, D2) and on sigma_promotion_articles' always-current cost fields.
-- Materializing them nightly would mean either re-running the refresh on
-- every Bloom call (defeats the point of a pantry) or serving stale promo
-- cost between refreshes -- a correctness risk canon's own R23/R22 language
-- would flag. They are computed INLINE in the L3 recipe (rpc_bloom_order_dc)
-- at query time instead, reading sigma_promotion_articles directly: always
-- current, no staleness window, and canon itself frames promo_eligibility as
-- a function of live parameters, not a stored column.
--
-- WHAT THIS COMPUTES (canon s14 promo_uplift):
--   "last completed promo's OOS-corrected ROS / its 28d pre-promo baseline,
--   cap 5.0; contamination ladder: prior promo -> same-EAN same-format
--   sibling store (DF-1, real GS1 only) -> default 2.00 labelled."
--
--   V1 SIMPLIFICATION, labelled (uplift_ros_basis column): the promo-period
--   ROS uses RAW net qty / promo-duration-days, not the OOS-corrected
--   run-detection formula from l2_bloom_ros_pantry. Generalising that
--   detector from fixed 14/28/56d windows anchored at today to an arbitrary
--   historical [start_date,end_date] promo window is a real follow-on build,
--   not done here. Rationale for shipping the simpler version now: an ACTIVE
--   promo is, by construction, a high-traffic period -- stockout gaps are
--   both less likely and less consequential to a ratio (uplift) than to an
--   absolute ROS figure. Flagged per R27 s6 (provisional until tested across
--   the bank) and R29 (the reason travels with the number) -- never silently
--   presented as the full DF-2 formula.
--
--   Contamination ladder (canon, unmodified):
--     (a) own_promo -- the product's own last COMPLETED promo (status='2'
--         in sigma_promotion_articles, latest end_date). ROS during the
--         promo / ROS in the 28 days immediately before it started. Capped
--         5.0. NULL baseline (never sold in the 28d pre-promo window) ->
--         falls through to (b), never a divide-by-zero.
--     (b) sibling_store -- DF-1 discipline: SPAR={10116,80175} /
--         TOPS={21355,80176,80579}, same-EAN only (real GS1, via
--         v_ean_bridge), same-format comparisons only. Any same-format
--         sibling's resolved own_promo uplift for the same EAN.
--     (c) default -- 2.00, LABELLED uplift_source='default'. Every row that
--         reaches this rung says so explicitly; never a silent 2.00.
--
-- SCOPE: same World-1 EAN-REAL NORMAL DC-linked, never_sold=false pool as
-- l2_bloom_ros_pantry (products that have never sold cannot have a
-- meaningful promo uplift either).
--
-- REFRESH: `SELECT refresh_l2_bloom_promo_pantry(p_store)` per store for the
-- own_promo pass (idempotent, DELETE+INSERT), THEN
-- `SELECT fill_l2_bloom_promo_pantry_sibling_fallback()` ONE call, platform-
-- wide, after all 5 stores' own_promo pass has run (DF-1 is inherently
-- cross-store -- "later-in-chain calculation," canon s9 DF-1). Not yet wired
-- into refresh_l2_pipeline, same reason as the ROS pantry (pending PM
-- sign-off review of this whole design before touching the shared pipeline).
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_bloom_promo_pantry CASCADE;

CREATE TABLE public.l2_bloom_promo_pantry (
  store_code            text NOT NULL,
  product_code           bigint NOT NULL,
  ean                     text NOT NULL,
  last_promo_nr           bigint,
  last_promo_start        date,
  last_promo_end          date,
  promo_period_ros        numeric,
  pre_promo_28d_ros       numeric,
  promo_uplift            numeric,
  promo_uplift_source     text,   -- 'own_promo' | 'sibling_store' | 'default'
  uplift_ros_basis        text NOT NULL DEFAULT 'raw_net_qty_v1_not_oos_corrected',
  pantry_refreshed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX l2_bloom_promo_pantry_ean ON public.l2_bloom_promo_pantry (ean, store_code);

GRANT SELECT ON public.l2_bloom_promo_pantry TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_l2_bloom_promo_pantry(p_store text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
BEGIN
  DELETE FROM public.l2_bloom_promo_pantry WHERE store_code = p_store;

  WITH dc_pool AS (
    SELECT DISTINCT ic.store_code, ic.product_code, b.ean
    FROM public.l2_item_classification ic
    JOIN public.sigma_supplier_link sl
      ON sl.store_code = ic.store_code AND sl.product_code = ic.product_code
    JOIN public.sigma_supplier_master sm
      ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr AND sm.supplier_type = 'Z'
    JOIN public.v_ean_bridge b
      ON b.store_code = ic.store_code AND b.product_code = ic.product_code
    JOIN public.l2_stock_position sp
      ON sp.store_code = ic.store_code AND sp.product_code = ic.product_code AND sp.never_sold = false
    WHERE ic.class = 'NORMAL' AND ic.store_code = p_store
  ),
  last_completed_promo AS (
    -- Unfiltered by dc_pool here on purpose (measured cost: this shape uses
    -- idx_sigma_promo_art_product efficiently; joining dc_pool up front
    -- forced a slower nested-loop plan on this table). dc_pool is applied
    -- at the final SELECT instead -- same result, much cheaper.
    SELECT DISTINCT ON (pa.store_code, pa.product_code)
      pa.store_code, pa.product_code, pa.promo_nr, pa.start_date, pa.end_date
    FROM public.sigma_promotion_articles pa
    WHERE pa.store_code = p_store AND pa.status = '2'
    ORDER BY pa.store_code, pa.product_code, pa.end_date DESC
  ),
  promo_period_qty AS (
    SELECT lcp.store_code, lcp.product_code,
           COALESCE(SUM(ss.qty), 0) AS qty,
           GREATEST(lcp.end_date - lcp.start_date + 1, 1) AS duration_days
    FROM last_completed_promo lcp
    LEFT JOIN public.sigma_sales ss
      ON ss.store_code = lcp.store_code AND ss.product_code = lcp.product_code
     AND ss.period_kind = 'T' AND ss.txn_kind = 1
     AND ss.sale_date BETWEEN lcp.start_date AND lcp.end_date
    GROUP BY lcp.store_code, lcp.product_code, lcp.end_date, lcp.start_date
  ),
  pre_promo_qty AS (
    SELECT lcp.store_code, lcp.product_code,
           COALESCE(SUM(ss.qty), 0) AS qty
    FROM last_completed_promo lcp
    LEFT JOIN public.sigma_sales ss
      ON ss.store_code = lcp.store_code AND ss.product_code = lcp.product_code
     AND ss.period_kind = 'T' AND ss.txn_kind = 1
     AND ss.sale_date BETWEEN (lcp.start_date - INTERVAL '28 days') AND (lcp.start_date - INTERVAL '1 day')
    GROUP BY lcp.store_code, lcp.product_code
  )
  INSERT INTO public.l2_bloom_promo_pantry (
    store_code, product_code, ean, last_promo_nr, last_promo_start, last_promo_end,
    promo_period_ros, pre_promo_28d_ros, promo_uplift, promo_uplift_source
  )
  SELECT
    p.store_code, p.product_code, p.ean,
    lcp.promo_nr, lcp.start_date, lcp.end_date,
    ROUND(ppq.qty / ppq.duration_days, 4) AS promo_period_ros,
    ROUND(prq.qty / 28.0, 4) AS pre_promo_28d_ros,
    CASE
      WHEN lcp.promo_nr IS NULL THEN NULL  -- no completed promo ever; ladder falls to sibling/default in the next pass
      WHEN prq.qty IS NULL OR prq.qty <= 0 THEN NULL  -- no pre-promo baseline; can't compute a ratio
      ELSE LEAST(ROUND((ppq.qty / ppq.duration_days) / (prq.qty / 28.0), 4), 5.0)
    END AS promo_uplift,
    CASE
      WHEN lcp.promo_nr IS NOT NULL AND prq.qty > 0 THEN 'own_promo'
      ELSE NULL  -- resolved by the sibling-fallback pass, or defaulted there
    END AS promo_uplift_source
  FROM dc_pool p
  LEFT JOIN last_completed_promo lcp ON lcp.store_code = p.store_code AND lcp.product_code = p.product_code
  LEFT JOIN promo_period_qty ppq ON ppq.store_code = p.store_code AND ppq.product_code = p.product_code
  LEFT JOIN pre_promo_qty prq ON prq.store_code = p.store_code AND prq.product_code = p.product_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('store_code', p_store, 'rows', v_rows,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bloom_promo_pantry(text) TO authenticated;

-- Cross-store DF-1 fallback pass (canon s9 DF-1: "later-in-chain calculation
-- -- runs on the cascade's output"). Fills promo_uplift for rows where the
-- own_promo pass left it NULL, from a same-format sibling's resolved
-- own_promo uplift on the same EAN. Then defaults anything still NULL to
-- 2.00, LABELLED. Run once, platform-wide, after all 5 stores' own_promo
-- pass has completed.
CREATE OR REPLACE FUNCTION public.fill_l2_bloom_promo_pantry_sibling_fallback()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_sibling_filled int;
  v_defaulted int;
BEGIN
  -- Sibling fill: same-format (DF-1), same real EAN, sibling already resolved own_promo.
  WITH format_groups AS (
    SELECT unnest(ARRAY['10116','80175']) AS store_code, 'SPAR' AS format_group
    UNION ALL
    SELECT unnest(ARRAY['21355','80176','80579']), 'TOPS'
  ),
  sibling_uplift AS (
    SELECT p.store_code, p.product_code, sib.promo_uplift AS sibling_uplift
    FROM public.l2_bloom_promo_pantry p
    JOIN format_groups fg ON fg.store_code = p.store_code
    JOIN format_groups fg2 ON fg2.format_group = fg.format_group AND fg2.store_code <> p.store_code
    JOIN public.l2_bloom_promo_pantry sib
      ON sib.store_code = fg2.store_code AND sib.ean = p.ean AND sib.promo_uplift_source = 'own_promo'
    WHERE p.promo_uplift IS NULL
  )
  UPDATE public.l2_bloom_promo_pantry p
  SET promo_uplift = su.sibling_uplift, promo_uplift_source = 'sibling_store'
  FROM (SELECT DISTINCT ON (store_code, product_code) store_code, product_code, sibling_uplift
        FROM sibling_uplift ORDER BY store_code, product_code) su
  WHERE p.store_code = su.store_code AND p.product_code = su.product_code AND p.promo_uplift IS NULL;
  GET DIAGNOSTICS v_sibling_filled = ROW_COUNT;

  -- Default: anything still NULL gets the labelled 2.00 fallback -- never a silent blank.
  UPDATE public.l2_bloom_promo_pantry
  SET promo_uplift = 2.00, promo_uplift_source = 'default'
  WHERE promo_uplift IS NULL;
  GET DIAGNOSTICS v_defaulted = ROW_COUNT;

  RETURN jsonb_build_object(
    'sibling_filled', v_sibling_filled, 'defaulted', v_defaulted,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$$;

GRANT EXECUTE ON FUNCTION public.fill_l2_bloom_promo_pantry_sibling_fallback() TO authenticated;
