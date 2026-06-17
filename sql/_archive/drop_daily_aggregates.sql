-- =============================================================================
-- DROP TABLE daily_aggregates
--
-- daily_aggregates was the original pipeline table populated from DBAUms
-- (the Sigma data warehouse). It was retired after the DBAUms investigation
-- showed it only captured ~21% of actual turnover (DC transfer lines only,
-- not till sales). The push script was rewritten to use PRSSALE.DAT via
-- daily_snapshots instead.
--
-- The push script (v2.0+) no longer writes to daily_aggregates.
-- No dashboard component or RPC references this table.
-- The step09_new_views.sql views (v_dept_summary, v_top_products) that read
-- it were superseded by RPCs against daily_snapshots.
--
-- Safe to drop: verify with the SELECT below before running the DROP.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- VERIFY -- confirm no recent writes and row count
-- ---------------------------------------------------------------------------
SELECT
    COUNT(*)                                           AS total_rows,
    MAX(created_at)                                    AS last_write
FROM   daily_aggregates;
-- Expected: total_rows = whatever backfill produced, last_write = old date.
-- If last_write is recent, investigate before dropping.


-- ---------------------------------------------------------------------------
-- DROP
-- Run this only after confirming no recent writes above.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS daily_aggregates CASCADE;


-- ---------------------------------------------------------------------------
-- VERIFY drop succeeded
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'daily_aggregates';
-- Expected: 0 rows (table is gone)
