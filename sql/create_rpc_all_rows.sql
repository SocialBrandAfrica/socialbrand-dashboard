-- =============================================================================
-- create_rpc_all_rows.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_all_rows.
-- DDL previously lived only in rpc_search_detail.sql (multi-RPC sediment).
-- Extracted verbatim from LIVE 2026-06-17. Paginated raw daily_snapshots dump.
-- NOTE (R26, capture-not-fix): this RPC uses snapshot_date::text = ANY(p_dates)
-- (the index-defeating cast pattern). Left as-is here -- it is a paginated raw dump,
-- and changing query logic is out of scope for the schema reconcile.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_all_rows(p_store_codes text[], p_dates text[], p_from integer DEFAULT 0, p_limit integer DEFAULT 1000)
 RETURNS TABLE(ean text, description text, size text, unit text, sell_price numeric, vat_pct numeric, today_qty numeric, today_cost numeric, today_sales numeric, period_qty numeric, period_cost numeric, period_sales numeric, soh numeric, dept_code text, dept_name text, sub_dept_code text, sub_dept_name text, internal_ref text, status text, last_sales_date_iso text, is_placeholder boolean, snapshot_date text, store_code text, store_name text, unit_cost numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT
        ean,
        description,
        size,
        unit,
        sell_price::numeric,
        vat_pct::numeric,
        today_qty::numeric,
        today_cost::numeric,
        today_sales::numeric,
        period_qty::numeric,
        period_cost::numeric,
        period_sales::numeric,
        soh::numeric,
        dept_code,
        dept_name,
        sub_dept_code,
        sub_dept_name,
        internal_ref,
        status::text,
        last_sales_date_iso::text,
        is_placeholder,
        snapshot_date::text,
        store_code,
        store_name,
        unit_cost::numeric
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    LIMIT  p_limit
    OFFSET p_from;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_all_rows(text[], text[], integer, integer) TO anon, authenticated;
