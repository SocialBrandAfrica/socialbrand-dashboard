-- =============================================================================
-- create_l2_bloom_ros_pantry.sql
-- SB-CC-BLOOM-001. L2 pantry object per CLEANUP-ENGINE-CANON section 14 (the
-- ordering recipe). R27: pure facts, scenario-blind, every window its own
-- named field. R28: effective_from 2026-07-02, scope GENERAL (the formula
-- structure travels to store #6 unchanged; per-store constants live in
-- bloom_dc_config, not here).
-- =============================================================================
-- SB-CC-BLOOM-005 REWRITE (2026-07-10 off-peak, closes BUG-LOG ENG-002's
-- perf debt + ENG-009's beer-coverage gap in one pass, per brief "the perf
-- fix and the coverage fix are the same problem"):
--
-- (A) PERF -- gaps-and-islands, not a calendar spine. The pre-BLOOM-005
--   version built a `calendar_182` row per (product, day) via
--   `CROSS JOIN LATERAL generate_series(...)` -- pool_size x 182 rows -- to
--   feed both the p_sell estimate AND the zero-run detector, TWICE (once for
--   the scan chain, once for the draw chain). On 10116 (8,483-row DC pool)
--   that is ~1.54M spine rows per chain before any window-function work even
--   starts. Measured cost: 80176 (769 rows) 43.3s; 10116 (8,483 rows)
--   exceeded 2m13s and was aborted rather than forced through mid-trading
--   (canon's own named ~310s figure, SB-CC-BLOOM-004 item 4).
--
--   This version never materializes a day-grain spine. Two structural
--   changes, same formula, same numeric output (R22 regression-proven
--   against the live pre-rewrite table for a store that had already
--   completed under the old method -- see verification note in the deploy
--   record):
--     1. p_sell (the 182d selling-day probability) = COUNT(actual positive-
--        net days) / 182, computed directly from the sales/movement rows
--        that exist -- no need to enumerate the 182 calendar days a product
--        DIDN'T sell on; the pool JOIN + COUNT already implies the zero
--        days.
--     2. Zero-runs = a gaps-and-islands pass over the ACTUAL positive-net
--        days only: LAG() finds the gap before each "hit" day, plus one
--        trailing-gap row (last hit to anchor) and one whole-window row for
--        products with zero hits anywhere in the 182d lookback. Row count
--        per product is bounded by (hit_days + 2), not 182 -- for any line
--        that sells more than a handful of times a day-count spine was
--        mostly wasted rows. The stockout-days-per-window figure (previously
--        counted by exploding each run into daily rows via a SECOND
--        `generate_series` and joining to the window bounds) is now a plain
--        interval-overlap calculation: `GREATEST(0, LEAST(run_end,win_end) -
--        GREATEST(run_start,win_start) + 1)`, summed per (product, window)
--        -- arithmetic, not row explosion.
--   Same `(1-p)^run_len < 0.05` test, same three windows (14/28/56), same
--   0.0001/0.9999 floor/ceiling guard on p -- the CORRECTION FORMULA is
--   unchanged (that is ratified canon, not perf-rewrite scope). Only the
--   mechanism that computes run lengths and window overlap changed.
--
-- (B) COVERAGE -- beer/cider on BOTH routes (ENG-009, BUG-LOG HIGH). The
--   pool's supplier-link join previously required `supplier_type = 'Z'`
--   (DC-only) unconditionally -- correct for the DC-scoped recipe this
--   pantry was built for, but it meant the 375 direct-beer lines
--   (`bloom_route_config.route_key='DIRECT_BEER'`, non-Z suppliers, the 3
--   TOPS stores) had ZERO corrected-ROS coverage, so `rpc_bloom_order_direct_
--   beer` had no family-draw/corrected rate to read and fell back to raw
--   calendar ROS -- the direct cause of the ~3x-5.8x under-order on SAB beer
--   (ENG-009). Fix: the pool now ALSO admits any line in the beer/cider
--   merch groups (201-205 BEER *, 401 CIDERS ALL -- the exact set
--   `bloom_route_config` already uses for DIRECT_BEER) via an active
--   supplier link of ANY type, not just Z. The original Z-scope branch is
--   UNCHANGED (same join columns, same lack of a status filter) -- this is
--   an additive OR, not a rewrite of the DC population, so the already-
--   verified DC recipe math cannot regress. The new beer branch carries its
--   own active-link guard (`sl.status <> 'S'`, `sm.status = 'A'`) matching
--   `rpc_bloom_order_direct_beer`'s own filters, so a suspended/inactive
--   supplier link never pulls a beer line into the pantry that the recipe
--   itself would reject.
--
-- Everything below this point that is not perf/coverage (the formula, the
-- draw-vs-scan dual-ledger design, the unit gate, the DRAW-BELOW-SCAN
-- finding) is UNCHANGED from the 2026-07-09 ENG-005 build; original comments
-- retained.
-- =============================================================================
-- ARCHITECTURE: this codebase's proven pattern for platform-wide-but-heavy L2
-- facts -- a PERSISTENT TABLE refreshed ONE STORE AT A TIME via
-- refresh_<name>(p_store), idempotent (DELETE store's rows + re-INSERT),
-- called in a per-store loop from refresh_l2_pipeline (same shape as
-- l2_classification, l2_anomaly_daily, l2_consignment_daily).
--
-- SCOPE (canon s9, binding for all derived facts): World-1 EAN-REAL NORMAL
-- buy-and-sell lines only -- "items that can be tied only to itself in the
-- ledger." PLU/scale/production lines are excluded; their ledgers are not
-- self-contained (canon s9). Supplier-link scope: DC (type Z, unchanged) OR
-- beer/cider merch groups on an active link of any type (SB-CC-BLOOM-005,
-- above) -- NOT department-filtered otherwise; the DC cycle department set
-- and the direct-beer route set are both L3 recipe-level choices
-- (bloom_dc_config / bloom_route_config), R27: the pantry must not depend on
-- which recipe reads it.
--
-- PERF/CORRECTNESS FILTER: also requires l2_stock_position.never_sold=false.
-- A lifetime-never-sold line trivially has ros=0 across every window and no
-- stockout story to tell -- computing the 182d run-detection for it is pure
-- waste, not lost accuracy (a line absent from this table reads as ros=0 via
-- COALESCE at the L3 recipe, identical to what the full computation would
-- have produced).
--
-- WHAT THIS COMPUTES (canon s14 pantry items ros_14d/28d/56d + corrected):
--   ros_Xd = SUM(net qty, K sales) over the trailing X days ending at the
--     store's own MAX(sale_date) in sigma_sales, divided by X. Net qty proven
--     sign-correct 2026-07-02 (R22): a till return/refund carries a NEGATIVE
--     qty matching its negative rand value in sigma_sales -- a plain
--     SUM(qty) over K-rows (period_kind='T', txn_kind=1) already nets returns
--     out with no special-casing.
--
--   ros_Xd_corrected (DF-2, canon s9 -- the stockout-aware rate): calendar-day
--     ROS understates demand when the line sat OOS. Presumed-stockout days are
--     excluded from the divisor:
--     1. p = the line's raw selling-day probability over a trailing 182-day
--        lookback = COUNT(days with net qty > 0) / COUNT(days in the window).
--        V1 APPROXIMATION, labelled: canon's exact wording ("share of
--        PRESUMED-IN-STOCK days with >=1 sale") is self-referential -- this
--        build uses the unconditional 182d selling-day frequency as the p
--        estimate (no iterative refinement), flagged via p_estimate_basis
--        per R27 s6 (provisional until tested across the bank) and R29.
--     2. For each of the 3 windows (14d/28d/56d), a run of `g` consecutive
--        zero-net-sale days is a PRESUMED STOCKOUT when (1-p)^g < 0.05.
--     3. ros_Xd_corrected = SUM(net qty) over the window / (window_days -
--        presumed_stockout_days_in_window). NULL when the whole window is
--        presumed stockout (divide-by-zero guard) -- never a fake number.
--     4. correction_days_removed_Xd stored per window -- the story (R29).
--
--   promo_uplift (canon s14) is NOT in this object -- see
--     create_l2_bloom_promo_pantry.sql.
--
-- ENG-005 (2026-07-09) -- ros_draw_Xd / ros_draw_Xd_corrected added beside
--   ros_Xd / ros_Xd_corrected above. ros_scan is keyed on sigma_sales -- the
--   SCANNED product_code. For a parent-child family (case/six-pack/single
--   sharing one physical stock position, canon s14 v5 / BLOOM-003 s7) the
--   scan can post against the PARENT code while the stock depletion posts
--   against the CHILD's stock position in sigma_movements -- Sigma nets the
--   family there, not in sigma_sales. ros_draw reads sigma_movements
--   (movement_type='K') at the SAME product_code the pantry already keys on
--   -- no family join, no sibling lookup. Two traps, both live-proven:
--     1. NO DOUBLE COUNT -- sigma_movements at the child's own product_code
--        already carries the family's true draw; never add the parent's
--        sigma_sales qty on top.
--     2. THE UNIT GATE -- ros_draw is computed ONLY for count-unit lines:
--        `sigma_articles.unit='EA' AND scale_flag <> '1'` (both signals
--        required). Every gated line stays ros_draw_*=NULL, never a wrong
--        number standing in for a real one. Proof case: 10116 product 1674
--        (SPAR MILK L/L F/CREAM) -- ros_draw_28d 478.32/day against ros_28d
--        38.18/day = ~12.53x.
--
-- DRAW-BELOW-SCAN (BUG-LOG ENG-005B): ~1,620 genuinely EA lines bank-wide
--   still show ros_draw < ros_scan in at least one window (small, proportional
--   gaps on slow movers -- ~1% cross-feed drift between independently-posted
--   ledgers, not a bug). This pantry deliberately does NOT resolve it -- R27:
--   the pantry holds both variants, the recipe picks. Any consumer computing
--   a demand input MUST apply GREATEST(ros_draw_*_corrected, ros_scan_*), per
--   window, never ros_draw alone.
--
-- REFRESH: `SELECT refresh_l2_bloom_ros_pantry(p_store)` per store, idempotent
--   (DELETE store rows + re-INSERT). WIRED into refresh_l2_pipeline (ENG-002,
--   SB-CC-BLOOM-005) -- see that function for call order (this object first,
--   l2_stock_band depends on it).
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
  -- SB-CC-BLOOM-005: additive OR -- the original Z-only branch is byte-
  -- identical (same join columns, no status filter added to it); the new
  -- beer/cider branch (any active supplier link) is what closes ENG-009's
  -- coverage gap. A product qualifying via BOTH branches collapses to one
  -- row via the outer DISTINCT (no per-supplier columns are selected).
  CREATE TEMP TABLE tmp_bloom_ros_pool AS
  SELECT DISTINCT ic.store_code, ic.product_code, b.ean,
         a.unit,
         (COALESCE(a.unit, '') = 'EA' AND COALESCE(a.scale_flag, '0') <> '1') AS is_draw_eligible
  FROM public.l2_item_classification ic
  JOIN public.sigma_articles a
    ON a.store_code = ic.store_code AND a.product_code = ic.product_code
  JOIN public.sigma_supplier_link sl
    ON sl.store_code = ic.store_code AND sl.product_code = ic.product_code
  JOIN public.sigma_supplier_master sm
    ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
  JOIN public.v_ean_bridge b
    ON b.store_code = ic.store_code AND b.product_code = ic.product_code
  JOIN public.l2_stock_position sp
    ON sp.store_code = ic.store_code AND sp.product_code = ic.product_code AND sp.never_sold = false
  WHERE ic.class = 'NORMAL' AND ic.store_code = p_store
    AND (
      sm.supplier_type = 'Z'                                              -- unchanged DC scope
      OR (
        a.merch_group_nr IN (201,202,203,204,205,401)                     -- SB-CC-BLOOM-005: beer/cider, either route
        AND COALESCE(sl.status,'') <> 'S' AND sm.status = 'A'             -- active-link guard, matches rpc_bloom_order_direct_beer
      )
    );

  CREATE UNIQUE INDEX ON tmp_bloom_ros_pool (store_code, product_code);
  ANALYZE tmp_bloom_ros_pool;

  -- ===================== SCAN chain (sigma_sales) -- SB-CC-BLOOM-005 gaps-and-islands rewrite =====================
  CREATE TEMP TABLE tmp_bloom_ros_scan AS
  WITH store_anchor AS (
    SELECT MAX(sale_date) AS anchor_date
    FROM public.sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1 AND store_code = p_store
  ),
  bounds AS (
    SELECT anchor_date, anchor_date - 181 AS win182_start FROM store_anchor
  ),
  windows AS (
    SELECT * FROM (VALUES (14), (28), (56)) AS w(window_days)
  ),
  daily_net AS (
    SELECT ss.product_code, ss.sale_date, SUM(ss.qty) AS net_qty
    FROM public.sigma_sales ss
    JOIN tmp_bloom_ros_pool p ON p.store_code = ss.store_code AND p.product_code = ss.product_code
    CROSS JOIN bounds b
    WHERE ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.store_code = p_store
      AND ss.sale_date >= b.win182_start AND ss.sale_date <= b.anchor_date
    GROUP BY ss.product_code, ss.sale_date
  ),
  sale_days AS (
    SELECT product_code, sale_date FROM daily_net WHERE net_qty > 0
  ),
  p_estimate AS (
    SELECT pool.product_code,
           COUNT(sd.sale_date)::numeric / 182.0 AS p_sell
    FROM tmp_bloom_ros_pool pool
    LEFT JOIN sale_days sd ON sd.product_code = pool.product_code
    GROUP BY pool.product_code
  ),
  hit_gaps AS (
    SELECT product_code, sale_date AS hit_date,
           LAG(sale_date) OVER (PARTITION BY product_code ORDER BY sale_date) AS prev_hit_date
    FROM sale_days
  ),
  runs_interior AS (
    SELECT hg.product_code,
           COALESCE(hg.prev_hit_date + 1, b.win182_start) AS run_start,
           hg.hit_date - 1 AS run_end
    FROM hit_gaps hg CROSS JOIN bounds b
    WHERE hg.hit_date - 1 >= COALESCE(hg.prev_hit_date + 1, b.win182_start)
  ),
  runs_trailing AS (
    SELECT sd.product_code, MAX(sd.sale_date) + 1 AS run_start, b.anchor_date AS run_end
    FROM sale_days sd CROSS JOIN bounds b
    GROUP BY sd.product_code, b.anchor_date
    HAVING MAX(sd.sale_date) < b.anchor_date
  ),
  runs_no_hits AS (
    SELECT pool.product_code, b.win182_start AS run_start, b.anchor_date AS run_end
    FROM tmp_bloom_ros_pool pool CROSS JOIN bounds b
    WHERE NOT EXISTS (SELECT 1 FROM sale_days sd WHERE sd.product_code = pool.product_code)
  ),
  runs AS (
    SELECT * FROM runs_interior
    UNION ALL SELECT * FROM runs_trailing
    UNION ALL SELECT * FROM runs_no_hits
  ),
  run_lengths AS (
    SELECT product_code, run_start, run_end, (run_end - run_start + 1)::int AS run_len
    FROM runs
  ),
  presumed_stockout_runs AS (
    SELECT rl.product_code, rl.run_start, rl.run_end, rl.run_len
    FROM run_lengths rl
    JOIN p_estimate pe ON pe.product_code = rl.product_code
    WHERE POWER(1.0 - LEAST(GREATEST(pe.p_sell, 0.0001), 0.9999), rl.run_len) < 0.05
  ),
  window_calc AS (
    SELECT pool.product_code, w.window_days,
           b.anchor_date - (w.window_days - 1) AS win_start,
           b.anchor_date AS win_end
    FROM tmp_bloom_ros_pool pool CROSS JOIN bounds b CROSS JOIN windows w
  ),
  window_qty AS (
    SELECT wc.product_code, wc.window_days,
           COALESCE(SUM(dn.net_qty), 0) AS window_net_qty
    FROM window_calc wc
    LEFT JOIN daily_net dn ON dn.product_code = wc.product_code
                          AND dn.sale_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.product_code, wc.window_days
  ),
  window_stockout AS (
    -- BUG FIX (SB-CC-BLOOM-005 build, caught by R22 regression check before
    -- ship): LEAST()/GREATEST() in Postgres IGNORE a NULL argument (return
    -- the non-NULL one) rather than propagating NULL like a normal operator
    -- -- so on the LEFT JOIN's NULL-padded "no matching run" rows, the old
    -- form `LEAST(pr.run_end, wc.win_end) - GREATEST(pr.run_start,
    -- wc.win_start) + 1` silently collapsed to `win_end - win_start + 1`,
    -- i.e. the FULL window length, for every product/window with ZERO
    -- overlapping stockout runs. FILTER (WHERE pr.product_code IS NOT NULL)
    -- excludes the join-padding rows from the SUM entirely -- only real
    -- overlaps contribute days. Caught on product 129 @ 10116: presumed_
    -- stockout_runs had no run anywhere near the last 28 days, yet
    -- window_stockout was reporting the entire 28-day window as stockout.
    SELECT wc.product_code, wc.window_days,
           COALESCE(SUM(GREATEST(0, LEAST(pr.run_end, wc.win_end) - GREATEST(pr.run_start, wc.win_start) + 1))
                     FILTER (WHERE pr.product_code IS NOT NULL), 0)::int
             AS stockout_days_in_window
    FROM window_calc wc
    LEFT JOIN presumed_stockout_runs pr
      ON pr.product_code = wc.product_code
     AND pr.run_start <= wc.win_end AND pr.run_end >= wc.win_start
    GROUP BY wc.product_code, wc.window_days
  )
  SELECT q.product_code,
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
  JOIN window_stockout so ON so.product_code=q.product_code AND so.window_days=q.window_days
  JOIN p_estimate pe ON pe.product_code = q.product_code
  GROUP BY q.product_code, pe.p_sell;

  CREATE UNIQUE INDEX ON tmp_bloom_ros_scan (product_code);
  ANALYZE tmp_bloom_ros_scan;

  -- ===================== DRAW chain (sigma_movements, EA-only) -- same SB-CC-BLOOM-005 rewrite =====================
  CREATE TEMP TABLE tmp_bloom_ros_draw AS
  WITH ea_pool AS (
    SELECT product_code FROM tmp_bloom_ros_pool WHERE is_draw_eligible
  ),
  store_anchor AS (
    SELECT MAX(sale_date) AS anchor_date
    FROM public.sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1 AND store_code = p_store
  ),
  bounds AS (
    SELECT anchor_date, anchor_date - 181 AS win182_start FROM store_anchor
  ),
  windows AS (
    SELECT * FROM (VALUES (14), (28), (56)) AS w(window_days)
  ),
  daily_net_draw AS (
    SELECT sm2.product_code, sm2.movement_date, SUM(sm2.qty) AS net_qty
    FROM public.sigma_movements sm2
    JOIN ea_pool p ON p.product_code = sm2.product_code
    CROSS JOIN bounds b
    WHERE sm2.movement_type = 'K' AND sm2.store_code = p_store
      AND sm2.movement_date >= b.win182_start AND sm2.movement_date <= b.anchor_date
    GROUP BY sm2.product_code, sm2.movement_date
  ),
  sale_days_draw AS (
    SELECT product_code, movement_date FROM daily_net_draw WHERE net_qty > 0
  ),
  p_estimate_draw AS (
    SELECT p.product_code,
           COUNT(sd.movement_date)::numeric / 182.0 AS p_sell
    FROM ea_pool p
    LEFT JOIN sale_days_draw sd ON sd.product_code = p.product_code
    GROUP BY p.product_code
  ),
  hit_gaps_draw AS (
    SELECT product_code, movement_date AS hit_date,
           LAG(movement_date) OVER (PARTITION BY product_code ORDER BY movement_date) AS prev_hit_date
    FROM sale_days_draw
  ),
  runs_interior_draw AS (
    SELECT hg.product_code,
           COALESCE(hg.prev_hit_date + 1, b.win182_start) AS run_start,
           hg.hit_date - 1 AS run_end
    FROM hit_gaps_draw hg CROSS JOIN bounds b
    WHERE hg.hit_date - 1 >= COALESCE(hg.prev_hit_date + 1, b.win182_start)
  ),
  runs_trailing_draw AS (
    SELECT sd.product_code, MAX(sd.movement_date) + 1 AS run_start, b.anchor_date AS run_end
    FROM sale_days_draw sd CROSS JOIN bounds b
    GROUP BY sd.product_code, b.anchor_date
    HAVING MAX(sd.movement_date) < b.anchor_date
  ),
  runs_no_hits_draw AS (
    SELECT p.product_code, b.win182_start AS run_start, b.anchor_date AS run_end
    FROM ea_pool p CROSS JOIN bounds b
    WHERE NOT EXISTS (SELECT 1 FROM sale_days_draw sd WHERE sd.product_code = p.product_code)
  ),
  runs_draw AS (
    SELECT * FROM runs_interior_draw
    UNION ALL SELECT * FROM runs_trailing_draw
    UNION ALL SELECT * FROM runs_no_hits_draw
  ),
  run_lengths_draw AS (
    SELECT product_code, run_start, run_end, (run_end - run_start + 1)::int AS run_len
    FROM runs_draw
  ),
  presumed_stockout_runs_draw AS (
    SELECT rl.product_code, rl.run_start, rl.run_end, rl.run_len
    FROM run_lengths_draw rl
    JOIN p_estimate_draw pe ON pe.product_code = rl.product_code
    WHERE POWER(1.0 - LEAST(GREATEST(pe.p_sell, 0.0001), 0.9999), rl.run_len) < 0.05
  ),
  window_calc_draw AS (
    SELECT p.product_code, w.window_days,
           b.anchor_date - (w.window_days - 1) AS win_start,
           b.anchor_date AS win_end
    FROM ea_pool p CROSS JOIN bounds b CROSS JOIN windows w
  ),
  window_qty_draw AS (
    SELECT wc.product_code, wc.window_days,
           COALESCE(SUM(dnd.net_qty), 0) AS window_net_qty
    FROM window_calc_draw wc
    LEFT JOIN daily_net_draw dnd ON dnd.product_code = wc.product_code
                                AND dnd.movement_date BETWEEN wc.win_start AND wc.win_end
    GROUP BY wc.product_code, wc.window_days
  ),
  window_stockout_draw AS (
    -- Same FILTER fix as the scan chain's window_stockout -- see comment there.
    SELECT wc.product_code, wc.window_days,
           COALESCE(SUM(GREATEST(0, LEAST(pr.run_end, wc.win_end) - GREATEST(pr.run_start, wc.win_start) + 1))
                     FILTER (WHERE pr.product_code IS NOT NULL), 0)::int
             AS stockout_days_in_window
    FROM window_calc_draw wc
    LEFT JOIN presumed_stockout_runs_draw pr
      ON pr.product_code = wc.product_code
     AND pr.run_start <= wc.win_end AND pr.run_end >= wc.win_start
    GROUP BY wc.product_code, wc.window_days
  )
  SELECT q.product_code,
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
  JOIN window_stockout_draw so ON so.product_code=q.product_code AND so.window_days=q.window_days
  JOIN p_estimate_draw pe ON pe.product_code = q.product_code
  GROUP BY q.product_code, pe.p_sell;

  CREATE UNIQUE INDEX ON tmp_bloom_ros_draw (product_code);
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
  JOIN tmp_bloom_ros_scan s ON s.product_code = p.product_code
  LEFT JOIN tmp_bloom_ros_draw d ON d.product_code = p.product_code;

  -- GET DIAGNOSTICS must read the INSERT's row count HERE, before any further
  -- statement runs -- see 2026-07-09 note: it captures the MOST RECENTLY
  -- EXECUTED command, and the three DROP TABLEs below all report ROW_COUNT=0.
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
