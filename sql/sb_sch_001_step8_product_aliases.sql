-- =============================================================================
-- SB-SCH-001 Block 8 Step 8 -- Create product_aliases shell
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 7
--
-- Empty shell only. NLP mapping logic is deferred to a dedicated search session.
-- Purpose: natural language text → EAN mapping for product search.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Confirm table does not already exist
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'product_aliases';
-- Expected: 0 rows. If 1 row returned, stop and review before proceeding.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Create shell table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_aliases (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id   uuid        NOT NULL REFERENCES clients(client_id),
    ean         text        NOT NULL,
    alias_text  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_product_aliases_client_ean
    ON public.product_aliases (client_id, ean);

CREATE INDEX IF NOT EXISTS idx_product_aliases_alias_text
    ON public.product_aliases (client_id, alias_text);


-- ---------------------------------------------------------------------------
-- STEP 4 -- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.product_aliases ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'product_aliases' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON public.product_aliases
            FOR SELECT USING (true);
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'product_aliases'
ORDER  BY ordinal_position;
-- Expected: id, client_id, ean, alias_text, created_at

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'product_aliases';
-- Expected: 1 row
