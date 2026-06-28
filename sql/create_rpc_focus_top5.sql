-- =============================================================================
-- create_rpc_focus_top5.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_focus_top5.
-- DDL previously lived in rpc_focus_area.sql + fix_dept_name_normalize_top20_focus.sql
-- (sediment). Extracted verbatim from LIVE 2026-06-17. sigma_sales via v_ean_bridge,
-- dept/subdept sigma-native, plpgsql date pre-cast (avoids the param-cast index trap).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_focus_top5(p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL::text, p_subdept text DEFAULT NULL::text)
 RETURNS TABLE(ean text, description text, store_code text, dept_name text, sub_dept_name text, period_sales numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_dates date[] := p_dates::date[];
BEGIN
    SET LOCAL statement_timeout = '60s';
    RETURN QUERY
    SELECT
        b.ean,
        MAX(COALESCE(a.description, a.short_description)) AS description,
        ss.store_code,
        MAX(COALESCE(sd.name,  'UNMAPPED'))               AS dept_name,
        MAX(COALESCE(sub.name, 'UNMAPPED'))               AS sub_dept_name,
        ROUND(SUM(ss.sales_incl_vat)::numeric, 2)         AS period_sales
    FROM   sigma_sales ss
    JOIN   v_ean_bridge b         ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    LEFT   JOIN sigma_articles a  ON a.store_code = ss.store_code AND a.product_code = ss.product_code
    LEFT   JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
    LEFT   JOIN sigma_subdepts sub   ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
    WHERE  ss.store_code  = ANY(p_store_codes)
      AND  ss.sale_date   = ANY(v_dates)
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
      AND  ss.sales_incl_vat > 0
      AND  (p_dept    IS NULL OR sd.name  = p_dept)
      AND  (p_subdept IS NULL OR sub.name = p_subdept)
    GROUP  BY b.ean, ss.store_code
    ORDER  BY period_sales DESC
    LIMIT  50;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_focus_top5(text[], text[], text, text) TO anon, authenticated;
