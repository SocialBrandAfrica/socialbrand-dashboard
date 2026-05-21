-- =============================================================================
-- Item B: refresh_kpi_view times out (error 57014 — statement timeout)
--
-- Root cause: Supabase/PostgREST enforces a statement timeout (default ~10s).
-- REFRESH MATERIALIZED VIEW on mv_kpi_by_date aggregates 10.4M rows and takes
-- 15–60 seconds. The function never completes → today's uploaded data never
-- appears on the dashboard without a manual SQL refresh.
--
-- Fix: recreate refresh_kpi_view with set_config('statement_timeout', '0', true)
-- at the top. This is the plpgsql equivalent of SET LOCAL statement_timeout = 0:
-- it removes the timeout for the current transaction only and reverts at commit.
--
-- Run this in the Supabase SQL Editor. After running, trigger a push from any
-- store server (or call the function manually) to confirm it completes without
-- error 57014.
-- =============================================================================


-- Drop existing version (no signature — removes all overloads if any exist)
DROP FUNCTION IF EXISTS public.refresh_kpi_view CASCADE;


CREATE FUNCTION public.refresh_kpi_view()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER AS $$
BEGIN
  -- Remove the PostgREST statement timeout for this transaction only.
  -- Equivalent to SET LOCAL statement_timeout = 0.
  -- Does NOT permanently change the session timeout — only affects this call.
  PERFORM set_config('statement_timeout', '0', true);

  REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;
END;
$$;

-- Grant to all roles the push script and dashboard might use
GRANT EXECUTE ON FUNCTION public.refresh_kpi_view()
    TO anon, authenticated, service_role;


-- Verify the function exists with correct signature
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments,
    p.prosecdef                      AS security_definer
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'refresh_kpi_view';
-- Expected: 1 row, arguments = '' (no params), security_definer = true
