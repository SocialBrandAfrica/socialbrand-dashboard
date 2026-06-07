-- RPT-001 FIX -- deploy rpc_stock_integrity_report
-- Run in Supabase SQL Editor.
-- Depends on is_fresh_perishable() which is already live (v_kpi_by_date uses it).
-- Extracted from sb_ap_004_c_interim_exclusion.sql Step 6.

DROP FUNCTION IF EXISTS public.rpc_stock_integrity_report CASCADE;

CREATE FUNCTION public.rpc_stock_integrity_report(
    p_store_codes  text[],
    p_date         text
)
RETURNS TABLE(
    store_code     text,
    store_name     text,
    ean            text,
    description    text,
    dept_name      text,
    sub_dept_name  text,
    soh            numeric,
    sell_price     numeric,
    integrity_type text,
    days_no_sale   int,
    value_at_risk  numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.sell_price)                                                   AS sell_price,
        'RECEIPTING_BREAK'::text                                             AS integrity_type,
        NULL::int                                                            AS days_no_sale,
        ROUND((ABS(MAX(ds.soh)) * COALESCE(MAX(ds.sell_price), 0))::numeric, 2) AS value_at_risk
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            < -50
    GROUP BY ds.store_code, ds.ean

    UNION ALL

    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.sell_price)                                                   AS sell_price,
        'FRESH_IMPOSSIBLE'::text                                             AS integrity_type,
        MAX(CASE
            WHEN ds.last_sales_date_iso IS NULL THEN NULL
            ELSE (CURRENT_DATE - ds.last_sales_date_iso)::int
        END)                                                                 AS days_no_sale,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.sell_price), 0))::numeric, 2)  AS value_at_risk
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
      AND (ds.last_sales_date_iso IS NULL
           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
    GROUP BY ds.store_code, ds.ean

    ORDER BY integrity_type, value_at_risk DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stock_integrity_report(text[], text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
