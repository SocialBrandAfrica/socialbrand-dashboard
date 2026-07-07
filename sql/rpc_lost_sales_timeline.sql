-- ─────────────────────────────────────────────────────────────────────────────
-- rpc_lost_sales_timeline
-- RETIRED IN PLACE 2026-07-07 (R28 lineage, effective_from 2026-07-07, scope GENERAL).
--   Zero frontend consumers verified (grep: the only match in src/ is the removed-
--   call comment in page.jsx, "rpc_lost_sales_timeline call removed with
--   rpc_lost_sales_oos; the RPC stays live in the DB", 2026-07-05 Lost Sales park).
--   Reads daily_snapshots for STOCK FACTS (soh/oos_bool) below -- kept live
--   (not dropped) as part of the daily_snapshots archive/truncate clearance
--   (PM ruling 2026-07-07): after truncate this simply returns empty snap_side
--   rows, which is harmless since nothing calls it. No successor; if Lost Sales
--   Timeline is ever un-parked, rebuild sourced off l2_soh_daily, not this file.
-- Returns day-by-day sold/OOS flags for a list of EANs over a rolling window.
-- Used by: Lost Sales Tracker widget (timeline bar per product row) -- PARKED.
--
-- SB-CC-DASH-SOURCE-002 Step 4 (SB-INDEX-005 Phase 2) -- HYBRID migration.
--   SALES FACT  sold_bool  -> sigma_sales (qty>0 that day, exact + missed-EOD
--                            complete). Bridged ean<->product_code via the SHARED
--                            v_ean_bridge view (one canonical ean per product --
--                            see create_v_ean_bridge.sql); falls back to the
--                            snapshot's today_qty for the unbridged tail.
--   STOCK FACTS oos_bool, soh -> STAY on daily_snapshots (the held stock-facts
--                            thread per the brief boundary -- DO NOT cross).
--                            On a missed-EOD day there is no snapshot row, so
--                            soh is NULL and oos_bool is NULL = honestly unknown
--                            OOS (UI merge rule treats it as not-oos). Those
--                            days still appear now (they did not before) carrying
--                            the sigma sold_bool. OOS accuracy on missed days is
--                            fixed only by the later stock-facts migration.
--
-- CONTRACT (for UI layer) -- UNCHANGED:
--   Input:
--     p_eans      text[]   -- up to 10 EANs
--     p_stores    text[]   -- store codes matching current filter
--     p_end_date  date     -- latest snapshot date already in state (no extra query)
--     p_days      int      -- rolling window length, default 28
--   Output (one row per EAN × store × date):
--     ean / store_code / snap_date / sold_bool / oos_bool / soh
--   UI merge rule (client-side, across stores per EAN per day):
--     sold (any store) > oos (any store) > neither
--
-- PERFORMANCE: sale_date / snapshot_date filtered as DATE ranges (never cast the
--   column, Rule 4). ean-bounded -> small scan, no pre-cast needed.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION rpc_lost_sales_timeline(
  p_eans     text[],
  p_stores   text[],
  p_end_date date,
  p_days     int DEFAULT 28
)
RETURNS TABLE (
  ean        text,
  store_code text,
  snap_date  date,
  sold_bool  bool,
  oos_bool   bool,
  soh        numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$
  WITH bridge AS (
    SELECT b.ean, b.store_code, b.product_code
    FROM   v_ean_bridge b
    WHERE  b.store_code = ANY(p_stores) AND b.ean = ANY(p_eans)
  ),
  sigma_side AS (              -- SALES FACT: did it move that day (sigma ledger)
    SELECT b.ean,
           ss.store_code,
           ss.sale_date AS snap_date,
           SUM(ss.qty)  AS sig_qty
    FROM   sigma_sales ss
    JOIN   bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    WHERE  ss.store_code  = ANY(p_stores)
      AND  ss.sale_date  >= (p_end_date - p_days)
      AND  ss.sale_date  <= p_end_date
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
    GROUP  BY b.ean, ss.store_code, ss.sale_date
  ),
  snap_side AS (              -- STOCK FACTS (held): soh / oos stay on snapshots
    SELECT ds.ean,
           ds.store_code,
           ds.snapshot_date AS snap_date,
           ds.today_qty     AS snap_qty,
           ds.soh,
           ds.is_placeholder
    FROM   daily_snapshots ds
    WHERE  ds.ean          = ANY(p_eans)
      AND  ds.store_code   = ANY(p_stores)
      AND  ds.snapshot_date >= (p_end_date - p_days)
      AND  ds.snapshot_date <= p_end_date
  )
  SELECT
    COALESCE(sg.ean,        sn.ean)        AS ean,
    COALESCE(sg.store_code, sn.store_code) AS store_code,
    COALESCE(sg.snap_date,  sn.snap_date)  AS snap_date,
    (COALESCE(sg.sig_qty, sn.snap_qty, 0) > 0)        AS sold_bool,   -- sigma-first
    (sn.soh <= 0 AND sn.is_placeholder = false)       AS oos_bool,    -- NULL when no snapshot
    sn.soh
  FROM   sigma_side sg
  FULL   OUTER JOIN snap_side sn
         ON sn.ean = sg.ean AND sn.store_code = sg.store_code AND sn.snap_date = sg.snap_date
  ORDER  BY 1, 2, 3;
$$;

-- Grant anon read access (required for dashboard calls via publishable key)
GRANT EXECUTE ON FUNCTION rpc_lost_sales_timeline(text[], text[], date, int) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
