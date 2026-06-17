-- =============================================================================
-- Add unique constraint to daily_snapshots
--
-- Why: the push script uses INSERT ... ON CONFLICT (store_code, snapshot_date,
-- ean) DO UPDATE to upsert rows in batches. Without this named constraint,
-- Postgres cannot resolve the ON CONFLICT target and falls back to a slower
-- row-by-row path (or errors, depending on the client).
--
-- Run this BEFORE add_client_id_to_daily_snapshots.sql. The client_id
-- migration's Step 5 drops this constraint and replaces it with one that
-- also includes client_id.
--
-- Safe to re-run: DO $$ guard checks pg_constraint before adding.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Verify no duplicate (store_code, snapshot_date, ean) rows exist.
--           If count > 0, deduplicate first (contact Pieter).
-- ---------------------------------------------------------------------------
SELECT store_code, snapshot_date, ean, COUNT(*) AS dupes
FROM   daily_snapshots
GROUP  BY store_code, snapshot_date, ean
HAVING COUNT(*) > 1
LIMIT  20;
-- Expected: 0 rows. If any rows returned, stop here.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Add the constraint
--           DO $$ block is the Postgres-safe way to guard against re-runs.
--           (ADD CONSTRAINT IF NOT EXISTS is MySQL syntax, not supported here.)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE  conname = 'daily_snapshots_store_date_ean_key'
    ) THEN
        ALTER TABLE daily_snapshots
        ADD CONSTRAINT daily_snapshots_store_date_ean_key
        UNIQUE (store_code, snapshot_date, ean);
        RAISE NOTICE 'Constraint added.';
    ELSE
        RAISE NOTICE 'Constraint already exists - skipped.';
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT
    tc.constraint_name,
    tc.constraint_type,
    string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS columns
FROM   information_schema.table_constraints  tc
JOIN   information_schema.key_column_usage   kcu
       ON kcu.constraint_name = tc.constraint_name
      AND kcu.table_name      = tc.table_name
WHERE  tc.table_name = 'daily_snapshots'
  AND  tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
GROUP  BY tc.constraint_name, tc.constraint_type
ORDER  BY tc.constraint_type, tc.constraint_name;
-- Expected:
--   daily_snapshots_store_date_ean_key  |  UNIQUE  |  store_code, snapshot_date, ean
