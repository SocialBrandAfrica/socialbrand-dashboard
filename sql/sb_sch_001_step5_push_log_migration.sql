-- =============================================================================
-- SB-SCH-001 Block 8 Step 5 -- Migrate push_log (add new columns)
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 2
--
-- All new columns are NULLABLE -- non-breaking. Existing rows get NULL.
-- The nightly push continues working without any script change.
-- Push script Step 12 (v3.7) will populate these columns going forward.
--
-- IMPORTANT: The live push_log uses different column names from the Block 2
-- spec. Mapping:
--   Block 2 spec   -> Live table column
--   id             -> push_id (PK -- do NOT add id column)
--   pushed_at      -> completed_at (already exists -- do NOT duplicate)
--   rows_uploaded  -> rows_pushed (already exists -- do NOT duplicate)
-- New columns to add: snapshot_date, rows_expected, tac_filename, duration_seconds
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Inspect current push_log columns (read-only)
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'push_log'
ORDER  BY ordinal_position;
-- Review before proceeding. Confirm snapshot_date, rows_expected,
-- tac_filename, duration_seconds are NOT already present.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Add new columns (all nullable -- non-breaking)
-- ---------------------------------------------------------------------------
ALTER TABLE public.push_log
    ADD COLUMN IF NOT EXISTS snapshot_date    date    NULL,
    ADD COLUMN IF NOT EXISTS rows_expected    int     NULL,
    ADD COLUMN IF NOT EXISTS tac_filename     text    NULL,
    ADD COLUMN IF NOT EXISTS duration_seconds int     NULL;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Index on snapshot_date for push health queries
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_push_log_snapshot_date
    ON public.push_log (store_code, snapshot_date);


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'push_log'
ORDER  BY ordinal_position;
-- Expected: all original columns intact + 4 new nullable columns at the end
