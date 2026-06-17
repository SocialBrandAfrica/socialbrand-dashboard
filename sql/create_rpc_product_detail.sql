-- =============================================================================
-- create_rpc_product_detail.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_product_detail.
-- DDL previously lived in rpc_search_detail.sql + fix_rpc_product_detail_pricing.sql
-- (sediment). Extracted verbatim from LIVE 2026-06-17. Per-EAN daily series.
-- NOTE (R26, capture-not-fix): uses snapshot_date::text = ANY(p_dates) (cast pattern);
-- bounded by ean so it performs acceptably. Logic unchanged by this reconcile.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_product_detail(p_ean text, p_store_codes text[], p_dates text[])
 RETURNS TABLE(snapshot_date text, store_code text, store_name text, today_qty numeric, today_sales numeric, today_cost numeric, soh numeric, sell_price numeric, unit_cost numeric, vat_pct numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT
        snapshot_date::text,
        store_code,
        store_name,
        today_qty::numeric,
        today_sales::numeric,
        today_cost::numeric,
        soh::numeric,
        sell_price::numeric,
        unit_cost::numeric,
        vat_pct::numeric
    FROM  daily_snapshots
    WHERE ean                = p_ean
      AND store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    ORDER BY snapshot_date ASC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_product_detail(text, text[], text[]) TO anon, authenticated;
