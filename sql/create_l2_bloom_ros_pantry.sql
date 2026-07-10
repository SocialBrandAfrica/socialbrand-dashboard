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
-- ENG-005 (2026-07-09, SB-CC-BLOOM-004 item 1, BUG-LOG ENG-005 CRITICAL) --
--   ros_draw_Xd / ros_draw_Xd_corrected added beside ros_Xd / ros_Xd_corrected
--   above. ros_scan (the columns above) is keyed on sigma_sales -- the
--   SCANNED product_code. For a parent-child family (case/six-pack/single
--   sharing one physical stock position, canon s14 v5 / BLOOM-003 s7) the
--   scan can post against the PARENT code while the stock depletion posts
--   against the CHILD's stock position in sigma_movements -- Sigma nets the
--   family there, not in sigma_sales. ros_draw reads sigma_movements
--   (movement_type='K', the till-sale channel, canon s1) at the SAME
--   product_code the pantry already keys on -- no family join, no sibling
--   lookup. Sigma's own posting already rolls the family's true draw onto
--   whichever code holds the stock; reading the ledger at that code is
--   sufficient. Two traps, both live-proven (Pieter, 2026-07-09):
--     1. NO DOUBLE COUNT. Never add the parent's sigma_sales qty onto the
--        child's draw -- sigma_movements at the child's own product_code
--        already carries it. Canon s14 addendum v5 as originally worded would
--        count the milk twice; this build does not roll anything onto
--        anything, it just reads a different ledger at the same key.
--     2. THE UNIT GATE. A weighed (scale) line posts KILOGRAMS on the ledger
--        and WEIGH-TICKETS at the till -- different measures, not
--        commensurable (RULE-BOOK s2 Quantity family). ros_draw is computed
--        ONLY for count-unit lines: `sigma_articles.unit='EA' AND scale_flag
--        <> '1'` -- BOTH signals required (PM correction, 2026-07-09; the
--        `unit` text field alone is not reliable: 234 scale_flag='1' lines
--        bank-wide carry `unit='EA'` in the article master while their
--        movement ledger posts fractional, weight-shaped quantities, e.g.
--        10116/3970 "F/L BANANAS LSE", pack_content='P/KG', movements like
--        8.82/6.32/4.142 units on a line the article master calls each-based
--        -- these leaked ros_draw before this fix and are now correctly
--        unit_incommensurable=true). Every gated line stays ros_draw_*=NULL,
--        never a wrong number standing in for a real one. Proof case: 10116
--        product 1674 (SPAR MILK L/L F/CREAM, the child/loose code holding
--        the family's stock) -- ros_draw_28d 478.32/day against ros_28d
--        38.18/day = **12.53x** (PM-verified figure, report the windowed
--        ratio, not a blended one -- 14d=16.45x, 56d=13.17x, same story,
--        different denominators). Closed by reading sigma_movements at 1674
--        directly. l2_rate_of_sale (9 readers) is NEVER touched by this
--        change -- ros_draw lives only in this pantry.
--
-- DRAW-BELOW-SCAN (found 2026-07-09, PM, BUG-LOG ENG-005B): even after the
--   scale_flag fix above, ~1,620 genuinely EA (scale_flag='0') lines bank-wide
--   still show ros_draw < ros_scan in at least one window. Characterized, not
--   a logic bug: 48/1,676 lines exceed a 0.5 unit/day absolute gap, 14 exceed
--   1 unit/day, 2 exceed 5 units/day -- the population is dominated by small,
--   proportionally-larger gaps on slow movers (matches RULE-BOOK R22 s13.2's
--   standing ~1% cross-feed drift between independently-posted ledgers --
--   sigma_sales/DBUmBA vs sigma_movements/DBBEBE -- amplified in percentage
--   terms on a low base, not evidence the ledger draw is wrong). **This
--   pantry deliberately does NOT resolve it** -- R27: the pantry holds both
--   variants (ros_scan, ros_draw), the recipe picks. THE RECIPE (item 5,
--   rpc_bloom_order_recipe, NOT YET BUILT) MUST apply a floor: demand input
--   = GREATEST(ros_draw_*_corrected, ros_scan_*) per window, never ros_draw
--   alone -- a real till scan already proves that many units moved, and a
--   ledger-side timing gap is never grounds to order to less than what the
--   floor is proven to have sold (same governing law as the OOS safeguard,
--   canon s14 addendum v2: never under-order a proven seller). Do not build
--   item 5 without this guard.
--
-- REFRESH: `SELECT refresh_l2_bloom_ros_pantry(p_store)` per store, idempotent
--   (DELETE store rows + re-INSERT). Not yet wired into refresh_l2_pipeline
--   (ENG-002, SB-CC-BLOOM-004 item 4) -- refreshed by hand until that lands.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_bloom_ros_pantry CASCADE;

CREATE TABLE public.l2_bloom_ros_pantry (
  store_code                    text NOT NULL,
  product_code                  bigint NOT NULL,
  ean                           text NOT NULL,
  unit                          text,
  unit_incommensurable          boolean NOT NULL DEFAULT true,
  p_sell_estimate               numeric,
  p_estimate_basis              text,
  ros_14d                       numeric,
  ros_28d                       numeric,
  ros_56d                       numeric,
  ros_14d_corrected             numeric,
  ros_28d_corrected             numeric,
  ros_56d_corrected             numeric,
  correction_days_removed_14d   int,
  correction_days_removed_28d   int,
  correction_days_removed_56d   int,
  p_sell_estimate_draw          numeric,
  p_estimate_basis_draw         text,
  ros_draw_14d                  numeric,
  ros_draw_28d                  numeric,
  ros_draw_56d                  numeric,
  ros_draw_14d_corrected        numeric,
  ros_draw_28d_corrected        numeric,
  ros_draw_56d_corrected        numeric,
  draw_correction_days_removed_14d  int,
  draw_correction_days_removed_28d  int,
  draw_correction_days_removed_56d  int,
  pantry_refreshed_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX l2_bloom_ros_pantry_ean ON public.l2_bloom_ros_pantry (ean, store_code);

GRANT SELECT ON public.l2_bloom_ros_pantry TO anon, authenticated;

COMMENT ON COLUMN public.l2_bloom_ros_pantry.ros_14d IS
  'ros_scan (till-scan demand): SUM(sigma_sales.qty)/14 at this product_code. '
  'Understates a parent-child family when the parent code is what gets scanned '
  '(ENG-005). Kept for the DC recipe delta report (canon s14, never the tier '
  'driver) and any consumer that wants pure scan behaviour.';
COMMENT ON COLUMN public.l2_bloom_ros_pantry.ros_draw_14d IS
  'ros_draw (ledger demand): SUM(sigma_movements.qty)/14 at this SAME '
  'product_code, movement_type=K, net of till returns. Sigma nets a '
  'parent-child family at the stock-holding code''s own ledger, so this '
  'closes the family gap ros_scan misses (ENG-005) with no sibling join. '
  'NULL when unit_incommensurable (non-EA unit -- see that column).';
COMMENT ON COLUMN public.l2_bloom_ros_pantry.unit_incommensurable IS
  'TRUE when sigma_articles.unit <> ''EA'' (or unmapped): the ledger posts a '
  'different measure (e.g. KG on weighed lines) than the till''s selling-unit '
  'count, so a draw-vs-scan comparison is not commensurable. ros_draw_* stays '
  'NULL rather than publish a number that compares kilograms to units.';

-- PERFORMANCE NOTE (2026-07-09, ENG-005 build): the scan chain and the draw
-- chain are each materialized into their OWN physical temp table rather than
-- combined into one ~24-CTE statement. A single-statement combine was tried
-- first and blew up from the proven 5-8s/store to 22-31 minutes/store (one
-- store's statement_timeout-canceled outright) -- the planner mis-estimated
-- across the doubled CTE graph even though each chain alone is cheap. Two
-- separate `CREATE TEMP TABLE ... AS` statements each get planned against a
-- real table with real stats (ANALYZE'd immediately after), reproducing the
-- original's plan shape for both chains independently.
--   MEASURED AFTER THE SPLIT (2026-07-09, all 5 stores, via pg log durations):
--   10116 ~22min / 21355 ~26min / 80176 ~27min BEFORE the split; 80175 ~5.2min
--   (310.9s) AFTER the split -- a large improvement (no more hard
--   statement_timeout cancellation, all 5 stores now complete and reconcile),
--   but NOT back to the original 5-8s/store baseline. Root cause not fully
--   chased down (leading suspect: store_anchor's underlying MAX(sale_date)
--   scan over sigma_sales -- up to ~1.3M rows/store -- now runs twice, once
--   per temp-table build, plus the run-length/stockout-detection window
--   function now runs twice per store instead of once). CORRECT and SAFE to
--   run (verified R22: 10116/1674 milk ros_draw ~487.9-609.6/day vs ros_scan
--   ~37/day depending on window, ~13.1x, matching the cited proof; unit gate
--   holds 0/83 KG-line leaks store-wide on 10116; draw >= scan on all but 4
--   lines bank-wide, each within ~2% -- explainable feed-timing drift, not a
--   bug) but this remains a NAMED PERFORMANCE DEBT for ENG-002 (SB-CC-BLOOM-004
--   item 4): six pantry refreshers landing in refresh_l2_pipeline, and this
--   one alone costs single-digit minutes per store x5 stores. Revisit at that
--   wiring step -- do not assume this is fast enough for the nightly window
--   without re-measuring the full six-refresher chain.

CREATE OR REPLACE FUNCTION public.refresh_l2_bloom_ros_pantry(p_store text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
BEGIN
  DELETE FROM public.l2_bloom_ros_pantry WHERE store_code = p_store;

  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_pool;
  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_scan;
  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_draw;

  -- ===================== POOL (materialized as a real temp table) =====================
  CREATE TEMP TABLE tmp_bloom_ros_pool AS
  SELECT DISTINCT ic.store_code, ic.product_code, b.ean,
         a.unit,
         (COALESCE(a.unit, '') = 'EA' AND COALESCE(a.scale_flag, '0') <> '1') AS is_draw_eligible
  FROM public.l2_item_classification ic
  JOIN public.sigma_supplier_link sl
    ON sl.store_code = ic.store_code AND sl.product_code = ic.product_code
  JOIN public.sigma_supplier_master sm
    ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr AND sm.supplier_type = 'Z'
  JOIN public.v_ean_bridge b
    ON b.store_code = ic.store_code AND b.product_code = ic.product_code
  JOIN public.l2_stock_position sp
    ON sp.store_code = ic.store_code AND sp.product_code = ic.product_code AND sp.never_sold = false
  JOIN public.sigma_articles a
    ON a.store_code = ic.store_code AND a.product_code = ic.product_code
  WHERE ic.class = 'NORMAL' AND ic.store_code = p_store;

  CREATE UNIQUE INDEX ON tmp_bloom_ros_pool (store_code, product_code);
  ANALYZE tmp_bloom_ros_pool;

  -- ===================== SCAN chain (sigma_sales) -- unchanged v1 logic, now over the temp pool =====================
  CREATE TEMP TABLE tmp_bloom_ros_scan AS
  WITH store_anchor AS (
    SELECT store_code, MAX(sale_date) AS anchor_date
    FROM public.sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1 AND store_code = p_store
    GROUP BY store_code
  ),
  windows AS (
    SELECT * FROM (VALUES (14), (28), (56)) AS w(window_days)
  ),
  daily_net AS (
    SELECT ss.store_code, ss.product_code, ss.sale_date, SUM(ss.qty) AS net_qty
    FROM public.sigma_sales ss
    JOIN tmp_bloom_ros_pool p ON p.store_code = ss.store_code AND p.product_code = ss.product_code
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
    FROM tmp_bloom_ros_pool p
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
  window_calc AS (
    SELECT p.store_code, p.product_code, w.window_days,
           sa.anchor_date - (w.window_days - 1) * INTERVAL '1 day' AS win_start,
           sa.anchor_date AS win_end
    FROM tmp_bloom_ros_pool p
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
  )
  SELECT q.store_code, q.product_code,
    pe.p_sell AS p_sell_estimate,
    'unconditional_182d_frequency'::text AS p_estimate_basis,
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
  JOIN p_estimate pe ON pe.store_code = q.store_code AND pe.product_code = q.product_code
  GROUP BY q.store_code, q.product_code, pe.p_sell;

  CREATE UNIQUE INDEX ON tmp_bloom_ros_scan (store_code, product_code);
  ANALYZE tmp_bloom_ros_scan;

  -- ===================== DRAW chain (sigma_movements, EA-only) -- ENG-005 =====================
  CREATE TEMP TABLE tmp_bloom_ros_draw AS
  WITH ea_pool AS (
    SELECT store_code, product_code FROM tmp_bloom_ros_pool WHERE is_draw_eligible
  ),
  store_anchor AS (
    SELECT store_code, MAX(sale_date) AS anchor_date
    FROM public.sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1 AND store_code = p_store
    GROUP BY store_code
  ),
  windows AS (
    SELECT * FROM (VALUES (14), (28), (56)) AS w(window_days)
  ),
  daily_net_draw AS (
    SELECT sm2.store_code, sm2.product_code, sm2.movement_date, SUM(sm2.qty) AS net_qty
    FROM public.sigma_movements sm2
    JOIN ea_pool p ON p.store_code = sm2.store_code AND p.product_code = sm2.product_code
    JOIN store_anchor sa ON sa.store_code = sm2.store_code
    WHERE sm2.movement_type = 'K' AND sm2.store_code = p_store
      AND sm2.movement_date >= CURRENT_DATE - INTERVAL '200 days'
      AND sm2.movement_date >= sa.anchor_date - INTERVAL '181 days'
      AND sm2.movement_date <= sa.anchor_date
    GROUP BY sm2.store_code, sm2.product_code, sm2.movement_date
  ),
  calendar_182 AS (
    SELECT sa.store_code, sa.anchor_date, gs.d::date AS cal_date
    FROM store_anchor sa
    CROSS JOIN LATERAL generate_series(sa.anchor_date - INTERVAL '181 days', sa.anchor_date, INTERVAL '1 day') AS gs(d)
  ),
  line_days_draw AS (
    SELECT p.store_code, p.product_code, c.cal_date, c.anchor_date,
           COALESCE(dnd.net_qty, 0) AS net_qty
    FROM ea_pool p
    JOIN calendar_182 c ON c.store_code = p.store_code
    LEFT JOIN daily_net_draw dnd ON dnd.store_code = p.store_code AND dnd.product_code = p.product_code AND dnd.movement_date = c.cal_date
  ),
  p_estimate_draw AS (
    SELECT store_code, product_code,
           AVG(CASE WHEN net_qty > 0 THEN 1.0 ELSE 0.0 END) AS p_sell
    FROM line_days_draw
    GROUP BY store_code, product_code
  ),
  runs_draw AS (
    SELECT store_code, product_code, cal_date, anchor_date, net_qty,
           CASE WHEN net_qty <= 0 THEN 1 ELSE 0 END AS is_zero_day,
           cal_date - (ROW_NUMBER() OVER (PARTITION BY store_code, product_code, (CASE WHEN net_qty <= 0 THEN 1 ELSE 0 END)
                                           ORDER BY cal_date))::int * INTERVAL '1 day' AS run_key
    FROM line_days_draw
  ),
  run_lengths_draw AS (
    SELECT store_code, product_code, run_key,
           MIN(cal_date) AS run_start, MAX(cal_date) AS run_end, COUNT(*) AS run_len
    FROM runs_draw
    WHERE is_zero_day = 1
    GROUP BY store_code, product_code, run_key
  ),
  presumed_stockout_days_draw AS (
    SELECT r.store_code, r.product_code, r.run_start, r.run_end, r.run_len
    FROM run_lengths_draw r
    JOIN p_estimate_draw pe ON pe.store_code = r.store_code AND pe.product_code = r.product_code
    WHERE POWER(1.0 - LEAST(GREATEST(pe.p_sell, 0.0001), 0.9999), r.run_len) < 0.05
  ),
  stockout_day_spine_draw AS (
    SELECT psd.store_code, psd.product_code, gs.d::date AS stockout_date
    FROM presumed_stockout_days_draw psd
    CROSS JOIN LATERAL generate_series(psd.run_start, psd.run_end, INTERVAL '1 day') AS gs(d)
  ),
  window_calc_draw AS (
    SELECT p.store_code, p.product_code, w.window_days,
           sa.anchor_date - (w.window_days - 1) * INTERVAL '1 day' AS win_start,
           sa.anchor_date AS win_end
    FROM ea_pool p
    JOIN store_anchor sa ON sa.store_code = p.store_code
    CROSS JOIN windows w
  ),
  window_qty_draw AS (
    SELECT wc.store_code, wc.product_code, wc.window_days,
           COALESCE(SUM(dnd.net_qty), 0) AS window_net_qty
    FROM window_calc_draw wc
    LEFT JOIN daily_net_draw dnd ON dnd.store_code = wc.store_code AND dnd.product_code = wc.product_code
                                AND dnd.movement_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.store_code, wc.product_code, wc.window_days
  ),
  window_stockout_draw AS (
    SELECT wc.store_code, wc.product_code, wc.window_days,
           COUNT(sds.stockout_date) AS stockout_days_in_window
    FROM window_calc_draw wc
    LEFT JOIN stockout_day_spine_draw sds ON sds.store_code = wc.store_code AND sds.product_code = wc.product_code
                                          AND sds.stockout_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.store_code, wc.product_code, wc.window_days
  )
  SELECT q.store_code, q.product_code,
    pe.p_sell AS p_sell_estimate_draw,
    'unconditional_182d_frequency_ledger_draw'::text AS p_estimate_basis_draw,
    MAX(CASE WHEN q.window_days=14 THEN ROUND(q.window_net_qty / 14.0, 4) END) AS ros_draw_14d,
    MAX(CASE WHEN q.window_days=28 THEN ROUND(q.window_net_qty / 28.0, 4) END) AS ros_draw_28d,
    MAX(CASE WHEN q.window_days=56 THEN ROUND(q.window_net_qty / 56.0, 4) END) AS ros_draw_56d,
    MAX(CASE WHEN q.window_days=14 AND (14 - so.stockout_days_in_window) > 0
             THEN ROUND(q.window_net_qty / (14 - so.stockout_days_in_window), 4) END) AS ros_draw_14d_corrected,
    MAX(CASE WHEN q.window_days=28 AND (28 - so.stockout_days_in_window) > 0
             THEN ROUND(q.window_net_qty / (28 - so.stockout_days_in_window), 4) END) AS ros_draw_28d_corrected,
    MAX(CASE WHEN q.window_days=56 AND (56 - so.stockout_days_in_window) > 0
             THEN ROUND(q.window_net_qty / (56 - so.stockout_days_in_window), 4) END) AS ros_draw_56d_corrected,
    MAX(CASE WHEN q.window_days=14 THEN so.stockout_days_in_window END) AS draw_correction_days_removed_14d,
    MAX(CASE WHEN q.window_days=28 THEN so.stockout_days_in_window END) AS draw_correction_days_removed_28d,
    MAX(CASE WHEN q.window_days=56 THEN so.stockout_days_in_window END) AS draw_correction_days_removed_56d
  FROM window_qty_draw q
  JOIN window_stockout_draw so ON so.store_code=q.store_code AND so.product_code=q.product_code AND so.window_days=q.window_days
  JOIN p_estimate_draw pe ON pe.store_code = q.store_code AND pe.product_code = q.product_code
  GROUP BY q.store_code, q.product_code, pe.p_sell;

  CREATE UNIQUE INDEX ON tmp_bloom_ros_draw (store_code, product_code);
  ANALYZE tmp_bloom_ros_draw;

  -- ===================== COMBINE (cheap: two small, indexed, ANALYZE'd temp tables) =====================
  INSERT INTO public.l2_bloom_ros_pantry (
    store_code, product_code, ean, unit, unit_incommensurable,
    p_sell_estimate, p_estimate_basis,
    ros_14d, ros_28d, ros_56d, ros_14d_corrected, ros_28d_corrected, ros_56d_corrected,
    correction_days_removed_14d, correction_days_removed_28d, correction_days_removed_56d,
    p_sell_estimate_draw, p_estimate_basis_draw,
    ros_draw_14d, ros_draw_28d, ros_draw_56d,
    ros_draw_14d_corrected, ros_draw_28d_corrected, ros_draw_56d_corrected,
    draw_correction_days_removed_14d, draw_correction_days_removed_28d, draw_correction_days_removed_56d
  )
  SELECT
    p.store_code, p.product_code, p.ean, p.unit, NOT p.is_draw_eligible,
    s.p_sell_estimate, s.p_estimate_basis,
    s.ros_14d, s.ros_28d, s.ros_56d, s.ros_14d_corrected, s.ros_28d_corrected, s.ros_56d_corrected,
    s.correction_days_removed_14d, s.correction_days_removed_28d, s.correction_days_removed_56d,
    d.p_sell_estimate_draw, d.p_estimate_basis_draw,
    d.ros_draw_14d, d.ros_draw_28d, d.ros_draw_56d,
    d.ros_draw_14d_corrected, d.ros_draw_28d_corrected, d.ros_draw_56d_corrected,
    d.draw_correction_days_removed_14d, d.draw_correction_days_removed_28d, d.draw_correction_days_removed_56d
  FROM tmp_bloom_ros_pool p
  JOIN tmp_bloom_ros_scan s ON s.store_code = p.store_code AND s.product_code = p.product_code
  LEFT JOIN tmp_bloom_ros_draw d ON d.store_code = p.store_code AND d.product_code = p.product_code;

  -- GET DIAGNOSTICS must read the INSERT's row count HERE, before any further
  -- statement runs -- it captures the MOST RECENTLY EXECUTED command, and the
  -- three DROP TABLEs below all report ROW_COUNT=0. Moving this call after
  -- them (as an earlier draft did) made every return value read 'rows: 0'
  -- even on a fully correct refresh -- caught 2026-07-09 when 80176 showed
  -- 'rows: 0' from the function but the table's own pantry_refreshed_at and
  -- unit_incommensurable count had genuinely moved. Cosmetic only, but a
  -- diagnostic nobody can trust is a diagnostic that shouldn't ship (R22).
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_pool;
  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_scan;
  DROP TABLE IF EXISTS pg_temp.tmp_bloom_ros_draw;

  RETURN jsonb_build_object(
    'store_code', p_store,
    'rows', v_rows,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bloom_ros_pantry(text) TO authenticated;
