-- =============================================================================
-- SB-SCH-001 Block 8 Step 9 -- Create user_profiles shell
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 7
--
-- Empty shell only. RLS policies are deferred to a future auth brief --
-- do NOT add "anon read" here. RLS is enabled so the table is locked
-- by default until policies are explicitly defined.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Confirm table does not already exist
-- ---------------------------------------------------------------------------
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'user_profiles';
-- Expected: 0 rows. If 1 row returned, stop and review before proceeding.


-- ---------------------------------------------------------------------------
-- STEP 2 -- Create shell table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_profiles (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id   uuid        NOT NULL REFERENCES clients(client_id),
    store_code  text        NULL,
    role        text        NOT NULL CHECK (role IN ('shift_manager', 'store_manager', 'area_manager')),
    email       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_profiles_client
    ON public.user_profiles (client_id);

CREATE INDEX IF NOT EXISTS idx_user_profiles_email
    ON public.user_profiles (email);


-- ---------------------------------------------------------------------------
-- STEP 4 -- Enable RLS (no policies yet -- future auth brief)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'user_profiles'
ORDER  BY ordinal_position;
-- Expected: id, client_id, store_code, role, email, created_at

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name   = 'user_profiles';
-- Expected: 1 row
