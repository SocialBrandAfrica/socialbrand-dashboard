-- =============================================================================
-- create_rpc_ghost_stock_report.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_ghost_stock_report.
-- DDL previously lived only in sb_ap_003_a6_*/sb_ap_004_c_* sediment (latest def).
-- Extracted verbatim from LIVE 2026-06-17. (DB-SCHEMA had it as PENDING; it is LIVE.)
-- PRODUCTION/NON_STOCK slow-movers + fresh-impossible stock, valued for the report.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_ghost_stock_report(p_store_codes text[], p_date text)
 RETURNS TABLE(store_code text, store_name text, ean text, description text, dept_name text, sub_dept_name text, soh numeric, unit_cost numeric, ghost_value numeric, exclusion_class text, score integer, why_flagged text, confirmed_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    -- PRODUCTION and NON_STOCK slow-movers (incl. never-sold production inputs)
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.unit_cost)                                                    AS unit_cost,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.unit_cost), 0))::numeric, 2)   AS ghost_value,
        MAX(classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                   ds.soh, ds.last_sales_date_iso))         AS exclusion_class,
        NULL::int                                                            AS score,
        MAX(
            CASE classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso)
                WHEN 'PRODUCTION' THEN
                    'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
                    || CASE WHEN ds.last_sales_date_iso IS NULL
                            THEN ' | never-sold production input'
                            ELSE ' | production sub-dept keyword'
                       END
                WHEN 'NON_STOCK' THEN
                    'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
                    || ' | non-stock/store-use'
                ELSE NULL
            END
        )                                                                    AS why_flagged,
        NULL::text                                                           AS confirmed_by
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND ds.period_qty     = 0
      AND ds.is_placeholder = FALSE
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                 ds.soh, ds.last_sales_date_iso)
          IN ('PRODUCTION', 'NON_STOCK')
    GROUP BY ds.store_code, ds.ean

    UNION ALL

    -- Fresh impossible-stock slow-movers
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.unit_cost)                                                    AS unit_cost,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.unit_cost), 0))::numeric, 2)   AS ghost_value,
        'FRESH_ALERT'::text                                                  AS exclusion_class,
        NULL::int                                                            AS score,
        MAX('dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
            || ' | fresh perishable, no sale '
            || COALESCE((CURRENT_DATE - ds.last_sales_date_iso)::text, 'ever')
            || 'd')                                                          AS why_flagged,
        NULL::text                                                           AS confirmed_by
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND ds.period_qty     = 0
      AND ds.is_placeholder = FALSE
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                 ds.soh, ds.last_sales_date_iso) IS NULL
      AND is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
      AND (ds.last_sales_date_iso IS NULL
           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
    GROUP BY ds.store_code, ds.ean, ds.last_sales_date_iso

    ORDER BY ghost_value DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_ghost_stock_report(text[], text) TO anon, authenticated;
