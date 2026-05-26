-- ─────────────────────────────────────────────────────────────────────────────
-- rpc_lost_sales_timeline
-- Returns day-by-day sold/OOS flags for a list of EANs over a rolling window.
-- Used by: Lost Sales Tracker widget (timeline bar per product row)
--
-- CONTRACT (for UI layer):
--   Input:
--     p_eans      text[]   -- up to 10 EANs
--     p_stores    text[]   -- store codes matching current filter
--     p_end_date  date     -- latest snapshot date already in state (no extra query)
--     p_days      int      -- rolling window length, default 28
--
--   Output (one row per EAN × store × date):
--     ean         text
--     store_code  text
--     snap_date   date
--     sold_bool   bool    -- today_qty > 0
--     oos_bool    bool    -- soh <= 0 AND NOT is_placeholder
--     soh         numeric -- raw value (available for tooltip)
--
--   UI merge rule (client-side, across stores per EAN per day):
--     sold (any store) > oos (any store) > neither
--
-- PERFORMANCE NOTES:
--   * Filters snapshot_date as a DATE range — never cast the column.
--   * Filters ean = ANY(p_eans) — uses composite index.
--   * Expected scan: ~10 EANs × 5 stores × 28 days = ~1,400 rows max.
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
  SELECT
    ds.ean,
    ds.store_code,
    ds.snapshot_date                                  AS snap_date,
    (ds.today_qty > 0)                                AS sold_bool,
    (ds.soh <= 0 AND ds.is_placeholder = false)       AS oos_bool,
    ds.soh
  FROM daily_snapshots ds
  WHERE ds.ean          = ANY(p_eans)
    AND ds.store_code   = ANY(p_stores)
    AND ds.snapshot_date >= (p_end_date - p_days)
    AND ds.snapshot_date <= p_end_date
  ORDER BY ds.ean, ds.store_code, ds.snapshot_date;
$$;

-- Grant anon read access (required for dashboard calls via publishable key)
GRANT EXECUTE ON FUNCTION rpc_lost_sales_timeline(text[], text[], date, int) TO anon;
