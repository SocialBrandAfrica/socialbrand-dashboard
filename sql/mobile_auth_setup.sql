-- =============================================================================
-- Mobile Auth Setup -- user_profiles migration + RLS
-- Brief: MOBILE-AUTH-BRIEF-2026-05-24.md Parts 1-2
-- Run in Supabase SQL Editor AFTER Google OAuth is enabled.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Add missing columns to user_profiles
-- (table already exists from Block 8 Step 9)
-- ---------------------------------------------------------------------------

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS full_name text,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Drop the old role CHECK constraint (it only allowed shift_manager / store_manager / area_manager)
-- and replace with one that also includes 'manager' and 'owner'
ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_role_check;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_role_check
  CHECK (role IN ('owner', 'manager', 'shift_manager', 'store_manager', 'area_manager'));

-- Make id default to the auth.users UUID (not gen_random_uuid)
-- The DEFAULT stays but will be overridden when inserting with a specific UUID.
-- Add FK to auth.users so referential integrity is enforced.
ALTER TABLE public.user_profiles
  ADD CONSTRAINT IF NOT EXISTS user_profiles_id_auth_fkey
  FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- RLS (already enabled from Step 9; add policies now)
-- ---------------------------------------------------------------------------

-- Users can read their own profile row only
CREATE POLICY IF NOT EXISTS "users_read_own_profile"
ON public.user_profiles FOR SELECT
USING (auth.uid() = id);

-- Only service_role (Pieter via Supabase Dashboard) can insert/update profiles
-- No INSERT/UPDATE policy needed for regular users -- they can't self-assign stores


-- ---------------------------------------------------------------------------
-- STEP 3 -- Notify PostgREST to pick up schema changes
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- STEP 4 -- Supabase Auth configuration (manual -- Pieter does this in UI)
-- ---------------------------------------------------------------------------
-- In Supabase Dashboard: Authentication > URL Configuration
--   Site URL:          https://dashboard.socialbrand.africa
--   Redirect URLs:     https://dashboard.socialbrand.africa/auth/callback
--                      http://localhost:3000/auth/callback  (for local dev)
--
-- In Supabase Dashboard: Authentication > Providers > Google
--   Enable Google provider
--   Client ID:     (paste from Google Cloud Console)
--   Client Secret: (paste from Google Cloud Console)
--   Callback URL shown by Supabase: paste this into Google Cloud Console
--                                   as the authorised redirect URI


-- ---------------------------------------------------------------------------
-- STEP 5 -- Seed Pieter's owner account
-- Run AFTER Pieter has logged in at least once with socialbrand.africa@gmail.com
-- ---------------------------------------------------------------------------
-- Find his UUID first:
-- SELECT id, email FROM auth.users WHERE email = 'socialbrand.africa@gmail.com';

-- Then insert his profile (replace <UUID> with the actual UUID from above):
/*
INSERT INTO public.user_profiles (id, email, full_name, store_code, role, client_id)
VALUES (
  '<UUID>',
  'socialbrand.africa@gmail.com',
  'Pieter van der Westhuizen',
  NULL,   -- owner sees all stores; store_code not used
  'owner',
  (SELECT client_id FROM clients LIMIT 1)  -- DFM client
);
*/

-- For a store manager (after they sign in once):
/*
INSERT INTO public.user_profiles (id, email, full_name, store_code, role, client_id)
VALUES (
  '<UUID>',          -- from Authentication > Users in Supabase Dashboard
  '<manager@gmail>',
  '<Manager Name>',
  '10116',           -- store code: 10116=SPAR Del, 21355=TOPS Del, 80175=SPAR Roos, 80176=TOPS Roos, 80579=TOPS Dice
  'manager',
  (SELECT client_id FROM clients LIMIT 1)
);
*/


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'user_profiles'
ORDER BY ordinal_position;
-- Expected: id, client_id, store_code, role, email, created_at, full_name, updated_at

SELECT schemaname, tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE tablename = 'user_profiles';
-- Expected: users_read_own_profile
