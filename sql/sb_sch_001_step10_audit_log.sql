-- =============================================================================
-- SB-SCH-001 Block 8 Step 10 -- Create audit_log shell
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 7
--
-- Compliance trail and session audit. Empty shell only.
-- user_id is nullable: system actions (e.g. nightly push) have no user.
-- row_id is text (not uuid) to support tables with non-uuid PKs.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Confirm table does not already exist
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'audit_log';
-- Expected: 0 rows. If 1 row returned, stop and review before proceeding.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Create shell table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_log (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id   uuid        NOT NULL REFERENCES clients(client_id),
    store_code  text        NULL,
    user_id     uuid        NULL,
    action      text        NOT NULL,
    table_name  text        NOT NULL,
    row_id      text        NULL,
    changed_at  timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_audit_log_client_changed
    ON public.audit_log (client_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_user
    ON public.audit_log (user_id);

CREATE INDEX IF NOT EXISTS idx_audit_log_table_row
    ON public.audit_log (table_name, row_id);


-- ---------------------------------------------------------------------------
-- STEP 4 -- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'audit_log' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON public.audit_log
            FOR SELECT USING (true);
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'audit_log'
ORDER  BY ordinal_position;
-- Expected: id, client_id, store_code, user_id, action, table_name, row_id, changed_at

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'audit_log';
-- Expected: 1 row
