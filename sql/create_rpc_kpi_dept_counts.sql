-- =============================================================================
-- create_rpc_kpi_dept_counts.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_kpi_dept_counts.
-- DDL previously lived in rpc_kpi_dept_counts.sql + the sb_ap_004_c_* sediment
-- (latest definition). Extracted verbatim from LIVE 2026-06-17. Dept-scoped
-- neg-SOH + slow-mover counts; uses classify_snapshot_item + is_fresh_perishable.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_kpi_dept_counts(p_store_codes text[], p_dates text[], p_subdept text DEFAULT NULL::text, p_eans text[] DEFAULT NULL::text[])
 RETURNS TABLE(dept_name text, neg_soh_count bigint, slow_mover_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_dates date[] := p_dates::date[];   -- pre-cast ONCE (index-safe, Rule 4)
BEGIN
    SET LOCAL statement_timeout = '60s';
    RETURN QUERY
    SELECT
        ds.dept_name,
        COUNT(*) FILTER (WHERE ds.soh < 0)                                   AS neg_soh_count,
        COUNT(*) FILTER (
            WHERE ds.period_qty     = 0
              AND ds.soh            > 0
              AND ds.is_placeholder = FALSE
              AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                         ds.soh, ds.last_sales_date_iso) IS NULL
              AND NOT (
                  is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                  AND (ds.last_sales_date_iso IS NULL
                       OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
              )
        )                                                                     AS slow_mover_count
    FROM  daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = ANY(v_dates)
      AND (p_subdept IS NULL OR ds.sub_dept_name = p_subdept)
      AND (p_eans    IS NULL OR ds.ean            = ANY(p_eans))
    GROUP BY ds.dept_name
    ORDER BY ds.dept_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_kpi_dept_counts(text[], text[], text, text[]) TO anon, authenticated;
