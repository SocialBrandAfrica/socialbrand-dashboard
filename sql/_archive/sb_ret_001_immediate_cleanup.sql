-- =============================================================================
-- SB-RET-001 -- Immediate one-time data cleanup
-- Deletes daily_snapshots rows older than 16 months (before 2025-02-01).
--
-- Run per store to stay under Supabase dashboard 60-second timeout.
-- Run Steps 1-5 in order. Each DELETE is independent and safe.
-- After all DELETEs, run Step 6 (VACUUM + refresh).
--
-- Retention window: 16 months from start of current month.
-- Cutoff today (2026-05-23): snapshot_date < 2025-02-01
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0 -- Check how many rows will be deleted (read-only, run first)
-- ---------------------------------------------------------------------------
SELECT
    store_code,
    COUNT(*)                        AS rows_to_delete,
    MIN(snapshot_date)              AS oldest_date,
    MAX(snapshot_date)              AS newest_date_to_delete
FROM daily_snapshots
WHERE snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months'
GROUP BY store_code
ORDER BY store_code;


-- ---------------------------------------------------------------------------
-- STEP 1 -- Delete SPAR Delareyville (10116)
-- ---------------------------------------------------------------------------
DELETE FROM daily_snapshots
WHERE store_code  = '10116'
  AND snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months';


-- ---------------------------------------------------------------------------
-- STEP 2 -- Delete TOPS Delareyville (21355)
-- ---------------------------------------------------------------------------
DELETE FROM daily_snapshots
WHERE store_code  = '21355'
  AND snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months';


-- ---------------------------------------------------------------------------
-- STEP 3 -- Delete SPAR Roosville (80175)
-- ---------------------------------------------------------------------------
DELETE FROM daily_snapshots
WHERE store_code  = '80175'
  AND snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months';


-- ---------------------------------------------------------------------------
-- STEP 4 -- Delete TOPS Roosville (80176)
-- ---------------------------------------------------------------------------
DELETE FROM daily_snapshots
WHERE store_code  = '80176'
  AND snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months';


-- ---------------------------------------------------------------------------
-- STEP 5 -- Delete TOPS Dice (80579)
-- ---------------------------------------------------------------------------
DELETE FROM daily_snapshots
WHERE store_code  = '80579'
  AND snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months';


-- ---------------------------------------------------------------------------
-- STEP 6 -- Verify: confirm 0 rows remain outside the window
-- ---------------------------------------------------------------------------
SELECT
    store_code,
    COUNT(*) AS remaining_old_rows
FROM daily_snapshots
WHERE snapshot_date < DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '16 months'
GROUP BY store_code;
-- Expected: 0 rows returned


-- ---------------------------------------------------------------------------
-- STEP 7 -- Reclaim space + update planner statistics
-- Run after all DELETEs confirm 0 old rows.
-- VACUUM ANALYZE cannot run inside a transaction -- run it alone.
-- ---------------------------------------------------------------------------
VACUUM ANALYZE daily_snapshots;


-- ---------------------------------------------------------------------------
-- STEP 8 -- Refresh materialized views to reflect the cleaned data
-- ---------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW mv_kpi_by_date;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sparkline_14d;
