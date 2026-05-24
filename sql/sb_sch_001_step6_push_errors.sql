-- =============================================================================
-- SB-SCH-001 Block 8 Step 6 -- Create push_errors table
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 2
--
-- Links each error row back to push_log via push_id (FK).
-- CASCADE DELETE: purging a push_log row also removes its errors.
-- All columns except push_id and error_message are nullable -- captures
-- whatever context the push script has at the point of failure.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Inspect: confirm push_errors does not already exist
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'push_errors';
-- Expected: 0 rows. If 1 row is returned, stop and review before proceeding.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Create table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_errors (
    error_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    push_id         uuid        NOT NULL REFERENCES public.push_log(push_id) ON DELETE CASCADE,
    store_code      text        NULL,
    ean             text        NULL,
    snapshot_date   date        NULL,
    error_message   text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_push_errors_push_id
    ON public.push_errors (push_id);

CREATE INDEX IF NOT EXISTS idx_push_errors_store_date
    ON public.push_errors (store_code, snapshot_date);


-- ---------------------------------------------------------------------------
-- STEP 4 -- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.push_errors ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'push_errors' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON public.push_errors
            FOR SELECT USING (true);
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'push_errors'
ORDER  BY ordinal_position;
-- Expected: error_id, push_id, store_code, ean, snapshot_date, error_message, created_at

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'push_errors';
-- Expected: 1 row
