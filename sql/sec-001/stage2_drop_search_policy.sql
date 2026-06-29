-- =============================================================================
-- stage2_drop_search_policy.sql
-- SB-CC-SEC-001 Stage 2 close -- drop the residual anon read policy on
-- product_search_index.
--
-- ON PIETER: run ONLY after sec-001-rls is merged, Vercel has deployed,
-- and you have confirmed product search still works on the live dashboard.
-- Running this before the deploy = product search goes blank.
-- =============================================================================

DROP POLICY IF EXISTS "anon read" ON public.product_search_index;

-- Confirm: should return 0 rows after this:
-- curl 'https://crklvhfwyxlisfcvqenc.supabase.co/rest/v1/product_search_index?select=*&limit=1' \
--   -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>"
