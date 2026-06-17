-- =============================================================================
-- create_rpc_subdepts.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_subdepts.
-- DDL previously lived in rpc_search_detail.sql + fix_rpc_subdepts_sel002.sql
-- (sediment; SEL-002 removed the today_sales>0 filter + fixed the date cast).
-- Extracted verbatim from LIVE 2026-06-17.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_subdepts(p_store_codes text[], p_dates text[], p_dept_names text[] DEFAULT NULL::text[])
 RETURNS TABLE(sub_dept_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT DISTINCT sub_dept_name
    FROM  daily_snapshots
    WHERE store_code     = ANY(p_store_codes)
      AND snapshot_date  = ANY(p_dates::date[])
      AND is_placeholder = FALSE
      AND sub_dept_name  IS NOT NULL
      AND (p_dept_names IS NULL OR dept_name = ANY(p_dept_names))
    ORDER BY sub_dept_name;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_subdepts(text[], text[], text[]) TO anon, authenticated;
