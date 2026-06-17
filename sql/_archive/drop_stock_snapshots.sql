-- =============================================================================
-- DROP TABLE stock_snapshots
-- SB-SCH-001 Block 1 -- signed off 2026-05-23
--
-- stock_snapshots was the SOH store in the Phase 2c architecture.
-- daily_aggregates (sales) joined stock_snapshots (SOH) to build the old
-- v_kpi_by_date. Pipeline moved to daily_snapshots as the single fact table
-- -- SOH now lives in daily_snapshots.soh. stock_snapshots became redundant.
--
-- Verified 2026-05-23:
--   - No frontend RPC or view references this table.
--   - Push-StockSnapshots function removed from Push-SigmaToSupabase.ps1.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- VERIFY -- check row count and last snapshot before dropping
-- ---------------------------------------------------------------------------
SELECT
    COUNT(*)                                    AS total_rows,
    MAX(snapshot_at)                            AS last_snapshot
FROM stock_snapshots;
-- If last_snapshot is from today, investigate before proceeding.


-- ---------------------------------------------------------------------------
-- DROP
-- Run only after confirming last_snapshot is not recent.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stock_snapshots CASCADE;


-- ---------------------------------------------------------------------------
-- VERIFY drop succeeded
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'stock_snapshots';
-- Expected: 0 rows
