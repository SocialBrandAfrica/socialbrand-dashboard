-- =============================================================================
-- rpc_diag_push_log
--
-- SECURITY DEFINER RPC so diagnose.html (hosted at /diagnostics.html) can
-- read push_log using the publishable (anon) key. Replaces the direct
-- REST query that required the secret key.
--
-- Run in Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- Follow with pg_notify so PostgREST picks up the new function immediately.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_diag_push_log(timestamptz, int) CASCADE;

CREATE FUNCTION public.rpc_diag_push_log(
    p_from  timestamptz,
    p_limit int DEFAULT 2000
)
RETURNS TABLE (
    store_code    text,
    snapshot_date date,
    tac_filename  text,
    status        text,
    rows_pushed   int,
    started_at    timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET statement_timeout = '15s'
AS $$
    SELECT
        store_code,
        snapshot_date,
        tac_filename,
        status,
        rows_pushed,
        started_at
    FROM push_log
    WHERE started_at >= p_from
    ORDER BY started_at DESC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_diag_push_log(timestamptz, int)
    TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');

-- Verify
SELECT proname, pg_get_function_arguments(oid) AS args, prosecdef AS secdef
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'rpc_diag_push_log';
-- Expected: 1 row, secdef = true
