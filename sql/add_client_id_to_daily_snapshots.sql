-- =============================================================================
-- Add client_id to daily_snapshots
--
-- Why: multi-tenant isolation. Without client_id, store_code is the only
-- discriminator — two clients sharing a store code prefix would see each
-- other's data. This adds the column, backfills it for the single existing
-- client, tightens the unique constraint, and adds a supporting index.
--
-- Run in Supabase SQL Editor during off-hours (the UPDATE on 10M+ rows
-- takes ~30s; the UNIQUE index rebuild takes ~60s).
--
-- Safe to re-run: each step uses IF NOT EXISTS / IF EXISTS guards.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Show current unique constraints on daily_snapshots
--           Review this output before proceeding.
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


-- ---------------------------------------------------------------------------
-- STEP 2 -- Add client_id column (nullable so existing rows don't break)
-- ---------------------------------------------------------------------------
ALTER TABLE daily_snapshots
ADD COLUMN IF NOT EXISTS client_id uuid REFERENCES clients(client_id);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Backfill existing rows (single client)
-- ---------------------------------------------------------------------------
UPDATE daily_snapshots
SET    client_id = (SELECT client_id FROM clients LIMIT 1)
WHERE  client_id IS NULL;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Enforce NOT NULL now that all rows are populated
-- ---------------------------------------------------------------------------
ALTER TABLE daily_snapshots
ALTER COLUMN client_id SET NOT NULL;


-- ---------------------------------------------------------------------------
-- STEP 5 -- Drop the old unique constraint (store_code, snapshot_date, ean)
--           Name is known: set by add_unique_constraint_daily_snapshots.sql
-- ---------------------------------------------------------------------------
ALTER TABLE daily_snapshots DROP CONSTRAINT IF EXISTS daily_snapshots_store_date_ean_key;


-- ---------------------------------------------------------------------------
-- STEP 6 -- Add new unique constraint including client_id
-- ---------------------------------------------------------------------------
ALTER TABLE daily_snapshots
ADD CONSTRAINT IF NOT EXISTS daily_snapshots_client_store_date_ean_key
UNIQUE (client_id, store_code, snapshot_date, ean);


-- ---------------------------------------------------------------------------
-- STEP 7 -- Supporting index for client_id-only lookups
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_daily_snapshots_client_id
ON daily_snapshots(client_id);


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
-- Expected after migration:
--   daily_snapshots_client_store_date_ean_key  |  UNIQUE  |  client_id, store_code, snapshot_date, ean
--   (old constraint gone)

SELECT COUNT(*) AS rows_without_client_id
FROM   daily_snapshots
WHERE  client_id IS NULL;
-- Expected: 0
