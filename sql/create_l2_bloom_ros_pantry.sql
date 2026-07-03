-- =============================================================================
-- create_l2_bloom_ros_pantry.sql
-- SB-CC-BLOOM-001. L2 pantry object per CLEANUP-ENGINE-CANON section 14 (the
-- ordering recipe). R27: pure facts, scenario-blind, every window its own
-- named field. R28: effective_from 2026-07-02, scope GENERAL (the formula
-- structure travels to store #6 unchanged; per-store constants live in
-- bloom_dc_config, not here).
-- =============================================================================
-- ARCHITECTURE (revised 2026-07-02 after two migration timeouts): a single
-- platform-wide CREATE MATERIALIZED VIEW ... AS <big query> timed out twice,
-- even after cutting the candidate pool ~4.5x (see below) and fixing a
-- non-sargable date bound. This codebase already has the correct, PROVEN
-- pattern for exactly this class of problem -- l2_classification,
-- l2_anomaly_daily and l2_consignment_daily are all PERSISTENT TABLES
-- refreshed ONE STORE AT A TIME via refresh_<name>(p_store), idempotent
-- (DELETE store's rows + re-INSERT), called in a per-store loop from
-- refresh_l2_pipeline. This file follows that pattern instead of inventing a
-- new one. Each store's computation is a few seconds (measured on 80175,
-- ~5-8s), comfortably inside any per-call timeout; five sequential calls
-- comfortably inside a nightly pipeline window.
--
-- SCOPE (canon s9, binding for all derived facts): World-1 EAN-REAL NORMAL
-- buy-and-sell lines only -- "items that can be tied only to itself in the
-- ledger." PLU/scale/production lines are excluded; their ledgers are not
-- self-contained (canon s9). Further scoped to DC-supplier-linked
-- (sigma_supplier_master.supplier_type='Z', active link) -- the population
-- Bloom's ORDER_DC recipe ever reads. NOT department-filtered -- the DC cycle
-- department set is an L3 recipe-level (bloom_dc_config) choice, R27: the
-- pantry must not depend on which recipe reads it.
--
-- PERF/CORRECTNESS FILTER: also requires l2_stock_position.never_sold=false.
-- A lifetime-never-sold line trivially has ros=0 across every window and no
-- stockout story to tell -- computing the 182d run-detection for it is pure
-- waste, not lost accuracy (a line absent from this table reads as ros=0 via
-- COALESCE at the L3 recipe, identical to what the full computation would
-- have produced). This filter alone cut the platform-wide candidate pool
-- ~4.5x (79,095 -> 17,661): the TOPS stores' "DORMANT PRODUCTS" department
-- (verified 2026-07-02: 0% of it sold anything in 91d at all three TOPS
-- stores; its one sub-department is literally named DORMANT ITEMS) was the
-- dominant, correctly-excludable cost driver.
--
-- WHAT THIS COMPUTES (canon s14 pantry items ros_14d/28d/56d + corrected):
--   ros_Xd = SUM(net qty, K sales) over the trailing X days ending at the
--     store's own MAX(sale_date) in sigma_sales, divided by X. Net qty proven
--     sign-correct 2026-07-02 (R22): a till return/refund carries a NEGATIVE
--     qty matching its negative rand value in sigma_sales (spot-checked
--     10116, 5 refund rows, qty and sales_incl_vat both negative together) --
--     so a plain SUM(qty) over K-rows (period_kind='T', txn_kind=1) already
--     nets returns out with no special-casing (canon's numerator instruction,
--     closed).
--
--   ros_Xd_corrected (DF-2, canon s9 -- the stockout-aware rate): calendar-day
--     ROS understates demand when the line sat OOS. Presumed-stockout days are
--     excluded from the divisor:
--     1. p = the line's raw selling-day probability over a trailing 182-day
--        lookback = COUNT(days with net qty > 0) / COUNT(days in the window).
--        V1 APPROXIMATION, labelled: canon's exact wording ("share of
--        PRESUMED-IN-STOCK days with >=1 sale") is self-referential -- you
--        need to already know which days were in-stock to compute p, and p
--        to detect which days were in-stock. This build uses the unconditional
--        182d selling-day frequency as the p estimate (no iterative
--        refinement) -- a standard, defensible first pass, not the literal
--        circular reading. Flagged here and in the story fields
--        (p_estimate_basis) per R27 s6 (provisional until tested across the
--        bank) and R29 (the reason travels with the number).
--     2. For each of the 3 windows (14d/28d/56d), walk consecutive zero-net-
--        sale-day runs. A run of length g is a PRESUMED STOCKOUT when
--        (1-p)^g < 0.05 (the silence is statistically improbable for that
--        line's own rhythm) -- canon's exact rule, unmodified.
--     3. ros_Xd_corrected = SUM(net qty) over the window / (window_days -
--        presumed_stockout_days_in_window). NULL when the whole window is
--        presumed stockout (divide-by-zero guard) -- never a fake number.
--     4. correction_days_removed_Xd stored per window -- the story (R29):
--        how many days were excluded and why.
--
--   promo_uplift (canon s14) is NOT in this object -- see
--     create_l2_bloom_promo_pantry.sql. It needs each line's promo history
--     (start/end dates, cost) which this ROS-only pantry doesn't carry; kept
--     as a separate object so a promo-schema change never forces a rebuild
--     of the (expensive) stockout-detection table above it.
--
-- REFRESH: `SELECT refresh_l2_bloom_ros_pantry(p_store)` per store, idempotent
--   (DELETE store rows + re-INSERT). Not yet wired into refresh_l2_pipeline
--   pending PM sign-off on the department-set proposal (bloom_dc_config) --
--   this object has no such dependency and can be wired independently
--   whenever that lands; deliberately NOT touching the shared pipeline
--   function mid-design.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_bloom_ros_pantry CASCADE;

CREATE TABLE public.l2_bloom_ros_pantry (
  store_code                 text NOT NULL,
  product_code                bigint NOT NULL,
  ean                          text NOT NULL,
  p_sell_estimate              numeric,
  p_estimate_basis             text,
  ros_14d                      numeric,
  ros_28d                      numeric,
  ros_56d                      numeric,
  ros_14d_corrected            numeric,
  ros_28d_corrected            numeric,
  ros_56d_corrected            numeric,
  correction_days_removed_14d  int,
  correction_days_removed_28d  int,
  correction_days_removed_56d  int,
  pantry_refreshed_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX l2_bloom_ros_pantry_ean ON public.l2_bloom_ros_pantry (ean, store_code);

GRANT SELECT ON public.l2_bloom_ros_pantry TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_l2_bloom_ros_pantry(p_store text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
BEGIN
  DELETE FROM public.l2_bloom_ros_pantry WHERE store_code = p_store;

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
  store_anchor AS (
    SELECT store_code, MAX(sale_date) AS anchor_date
    FROM public.sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1 AND store_code = p_store
    GROUP BY store_code
  ),
  daily_net AS (
    SELECT ss.store_code, ss.product_code, ss.sale_date, SUM(ss.qty) AS net_qty
    FROM public.sigma_sales ss
    JOIN dc_pool p ON p.store_code = ss.store_code AND p.product_code = ss.product_code
    JOIN store_anchor sa ON sa.store_code = ss.store_code
    WHERE ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.store_code = p_store
      AND ss.sale_date >= CURRENT_DATE - INTERVAL '200 days'
      AND ss.sale_date >= sa.anchor_date - INTERVAL '181 days'
      AND ss.sale_date <= sa.anchor_date
    GROUP BY ss.store_code, ss.product_code, ss.sale_date
  ),
  calendar_182 AS (
    SELECT sa.store_code, sa.anchor_date, gs.d::date AS cal_date
    FROM store_anchor sa
    CROSS JOIN LATERAL generate_series(sa.anchor_date - INTERVAL '181 days', sa.anchor_date, INTERVAL '1 day') AS gs(d)
  ),
  line_days AS (
    SELECT p.store_code, p.product_code, c.cal_date, c.anchor_date,
           COALESCE(dn.net_qty, 0) AS net_qty
    FROM dc_pool p
    JOIN calendar_182 c ON c.store_code = p.store_code
    LEFT JOIN daily_net dn ON dn.store_code = p.store_code AND dn.product_code = p.product_code AND dn.sale_date = c.cal_date
  ),
  p_estimate AS (
    SELECT store_code, product_code,
           AVG(CASE WHEN net_qty > 0 THEN 1.0 ELSE 0.0 END) AS p_sell
    FROM line_days
    GROUP BY store_code, product_code
  ),
  runs AS (
    SELECT store_code, product_code, cal_date, anchor_date, net_qty,
           CASE WHEN net_qty <= 0 THEN 1 ELSE 0 END AS is_zero_day,
           cal_date - (ROW_NUMBER() OVER (PARTITION BY store_code, product_code, (CASE WHEN net_qty <= 0 THEN 1 ELSE 0 END)
                                           ORDER BY cal_date))::int * INTERVAL '1 day' AS run_key
    FROM line_days
  ),
  run_lengths AS (
    SELECT store_code, product_code, run_key,
           MIN(cal_date) AS run_start, MAX(cal_date) AS run_end, COUNT(*) AS run_len
    FROM runs
    WHERE is_zero_day = 1
    GROUP BY store_code, product_code, run_key
  ),
  presumed_stockout_days AS (
    SELECT r.store_code, r.product_code, r.run_start, r.run_end, r.run_len
    FROM run_lengths r
    JOIN p_estimate pe ON pe.store_code = r.store_code AND pe.product_code = r.product_code
    WHERE POWER(1.0 - LEAST(GREATEST(pe.p_sell, 0.0001), 0.9999), r.run_len) < 0.05
  ),
  stockout_day_spine AS (
    SELECT psd.store_code, psd.product_code, gs.d::date AS stockout_date
    FROM presumed_stockout_days psd
    CROSS JOIN LATERAL generate_series(psd.run_start, psd.run_end, INTERVAL '1 day') AS gs(d)
  ),
  windows AS (
    SELECT * FROM (VALUES (14), (28), (56)) AS w(window_days)
  ),
  window_calc AS (
    SELECT p.store_code, p.product_code, w.window_days,
           sa.anchor_date - (w.window_days - 1) * INTERVAL '1 day' AS win_start,
           sa.anchor_date AS win_end
    FROM dc_pool p
    JOIN store_anchor sa ON sa.store_code = p.store_code
    CROSS JOIN windows w
  ),
  window_qty AS (
    SELECT wc.store_code, wc.product_code, wc.window_days,
           COALESCE(SUM(dn.net_qty), 0) AS window_net_qty
    FROM window_calc wc
    LEFT JOIN daily_net dn ON dn.store_code = wc.store_code AND dn.product_code = wc.product_code
                          AND dn.sale_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.store_code, wc.product_code, wc.window_days
  ),
  window_stockout AS (
    SELECT wc.store_code, wc.product_code, wc.window_days,
           COUNT(sds.stockout_date) AS stockout_days_in_window
    FROM window_calc wc
    LEFT JOIN stockout_day_spine sds ON sds.store_code = wc.store_code AND sds.product_code = wc.product_code
                                     AND sds.stockout_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.store_code, wc.product_code, wc.window_days
  ),
  ros_pivot AS (
    SELECT q.store_code, q.product_code,
      MAX(CASE WHEN q.window_days=14 THEN ROUND(q.window_net_qty / 14.0, 4) END) AS ros_14d,
      MAX(CASE WHEN q.window_days=28 THEN ROUND(q.window_net_qty / 28.0, 4) END) AS ros_28d,
      MAX(CASE WHEN q.window_days=56 THEN ROUND(q.window_net_qty / 56.0, 4) END) AS ros_56d,
      MAX(CASE WHEN q.window_days=14 AND (14 - so.stockout_days_in_window) > 0
               THEN ROUND(q.window_net_qty / (14 - so.stockout_days_in_window), 4) END) AS ros_14d_corrected,
      MAX(CASE WHEN q.window_days=28 AND (28 - so.stockout_days_in_window) > 0
               THEN ROUND(q.window_net_qty / (28 - so.stockout_days_in_window), 4) END) AS ros_28d_corrected,
      MAX(CASE WHEN q.window_days=56 AND (56 - so.stockout_days_in_window) > 0
               THEN ROUND(q.window_net_qty / (56 - so.stockout_days_in_window), 4) END) AS ros_56d_corrected,
      MAX(CASE WHEN q.window_days=14 THEN so.stockout_days_in_window END) AS correction_days_removed_14d,
      MAX(CASE WHEN q.window_days=28 THEN so.stockout_days_in_window END) AS correction_days_removed_28d,
      MAX(CASE WHEN q.window_days=56 THEN so.stockout_days_in_window END) AS correction_days_removed_56d
    FROM window_qty q
    JOIN window_stockout so ON so.store_code=q.store_code AND so.product_code=q.product_code AND so.window_days=q.window_days
    GROUP BY q.store_code, q.product_code
  )
  INSERT INTO public.l2_bloom_ros_pantry (
    store_code, product_code, ean, p_sell_estimate, p_estimate_basis,
    ros_14d, ros_28d, ros_56d, ros_14d_corrected, ros_28d_corrected, ros_56d_corrected,
    correction_days_removed_14d, correction_days_removed_28d, correction_days_removed_56d
  )
  SELECT
    p.store_code, p.product_code, p.ean,
    pe.p_sell, 'unconditional_182d_frequency',
    rp.ros_14d, rp.ros_28d, rp.ros_56d,
    rp.ros_14d_corrected, rp.ros_28d_corrected, rp.ros_56d_corrected,
    rp.correction_days_removed_14d, rp.correction_days_removed_28d, rp.correction_days_removed_56d
  FROM dc_pool p
  JOIN p_estimate pe ON pe.store_code = p.store_code AND pe.product_code = p.product_code
  JOIN ros_pivot rp ON rp.store_code = p.store_code AND rp.product_code = p.product_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'store_code', p_store,
    'rows', v_rows,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bloom_ros_pantry(text) TO authenticated;
