-- =============================================================================
-- SB-SCH-001 Block 8 Step 3 -- Add client_id to daily_snapshots
--
-- Decisions (Block 4, signed off 2026-05-23):
--   - client_id is a deployment identifier, not a row-isolation key
--   - Per-project isolation handles client separation (each client = own project)
--   - client_id stays NULLABLE -- no NOT NULL enforcement here
--   - client_id is NOT added to the unique constraint
--     (store_code, snapshot_date, ean) remains the conflict key
--   - Push script already sends client_id on every row (no script change needed)
--
-- NOTE: The old add_client_id_to_daily_snapshots.sql is SUPERSEDED by this file.
-- That file added client_id to the unique constraint -- do NOT run it.
--
-- Safe to re-run: ADD COLUMN IF NOT EXISTS + WHERE client_id IS NULL backfill.
-- Run during off-hours -- UPDATE across 10M+ rows takes ~30-60 seconds.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Check current state
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'daily_snapshots'
  AND  column_name  = 'client_id';
-- 0 rows = column does not exist yet (proceed)
-- 1 row  = already added (ADD COLUMN below is a no-op, backfill still runs)

SELECT constraint_name, constraint_type
FROM   information_schema.table_constraints
WHERE  table_schema = 'public'
  AND  table_name   = 'daily_snapshots'
  AND  constraint_type = 'UNIQUE';
-- Confirm unique constraint is still (store_code, snapshot_date, ean) only.
-- client_id must NOT appear here.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Add column (nullable, FK to clients)
-- ---------------------------------------------------------------------------
ALTER TABLE daily_snapshots
ADD COLUMN IF NOT EXISTS client_id uuid REFERENCES clients(client_id);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Backfill all existing rows from the single client row
-- This runs on ~10M rows -- give it 60 seconds.
-- ---------------------------------------------------------------------------
UPDATE daily_snapshots
SET    client_id = (SELECT client_id FROM clients LIMIT 1)
WHERE  client_id IS NULL;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Supporting index for client_id lookups
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_daily_snapshots_client_id
ON daily_snapshots(client_id);


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS rows_without_client_id
FROM   daily_snapshots
WHERE  client_id IS NULL;
-- Expected: 0

SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'daily_snapshots'
  AND  column_name  = 'client_id';
-- Expected: 1 row, is_nullable = YES

SELECT constraint_name
FROM   information_schema.table_constraints
WHERE  table_schema = 'public'
  AND  table_name   = 'daily_snapshots'
  AND  constraint_type = 'UNIQUE';
-- Expected: daily_snapshots_store_date_ean_key only -- no client_id in key
