-- =============================================================================
-- create_rpc_kpi_dept_counts.sql
-- SB-CC-PRSSALE-RETIRE-001 -- migrated daily_snapshots -> l2_stock_position.
-- l2_stock_position is always-latest sigma-native position; no date scan needed.
-- p_dates retained as no-op for backward compatibility (remove in Phase 2).
-- Previous: SB-CC-DASH-TIMEOUT-001 (plpgsql + v_dates + SET LOCAL).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_kpi_dept_counts(p_store_codes text[], p_dates text[], p_subdept text DEFAULT NULL::text, p_eans text[] DEFAULT NULL::text[])
 RETURNS TABLE(dept_name text, neg_soh_count bigint, slow_mover_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(sp.dept_name, 'UNMAPPED')                    AS dept_name,
        COUNT(*) FILTER (WHERE sp.soh < 0)::bigint            AS neg_soh_count,
        COUNT(*) FILTER (WHERE sp.slow_mover_signal)::bigint  AS slow_mover_count
    FROM l2_stock_position sp
    WHERE sp.store_code = ANY(p_store_codes)
      AND (p_subdept IS NULL OR sp.subdept_name = p_subdept)
      AND (p_eans    IS NULL OR sp.product_code IN (
            SELECT b.product_code FROM v_ean_bridge b
            WHERE b.store_code = ANY(p_store_codes) AND b.ean = ANY(p_eans)
          ))
    GROUP BY sp.dept_name
    ORDER BY sp.dept_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_kpi_dept_counts(text[], text[], text, text[]) TO anon, authenticated;
