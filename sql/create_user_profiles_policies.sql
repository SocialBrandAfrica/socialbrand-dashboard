-- create_user_profiles_policies.sql
-- SB-RA-BLOOM-001 section 12: three roles (admin/town_manager/branch_manager)
-- read their own profile row for role + store-assignment lookup. RLS was
-- enabled with ZERO policies (locked by default per DB-SCHEMA note) -- this
-- was blocking the Replit app's own login flow, not protecting anything,
-- since no writes existed either.
--
-- Also revoke the table-level anon SELECT grant (PII: email, full_name) --
-- RLS already blocked anon reads with no matching policy, this is defense
-- in depth, same discipline as the R30 addendum PUBLIC-grant precedent.

REVOKE SELECT ON public.user_profiles FROM anon;

CREATE POLICY "user_profiles_select_own" ON public.user_profiles FOR SELECT TO authenticated
USING (id = auth.uid());

-- admin/town_manager assignment screens (not yet built) will need to see
-- other profiles -- deferred, not preemptively opened (R25/R32: build the
-- pantry fact when a screen needs it, never speculatively).
