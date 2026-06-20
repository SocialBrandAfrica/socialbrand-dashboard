-- =============================================================================
-- fix_rpc_focus_chart_exvat.sql
-- SB-CC-VAT-GAP1-001 -- add today_sales_ex_vat to rpc_focus_chart.
--
-- Gap confirmed live 2026-06-20: return type had no ex-VAT column.
--   today_sales = COALESCE(sigma sig_sales, daily_snapshots snap_sales) = incl-VAT.
--
-- Fix: add today_sales_ex_vat beside today_sales (today_sales kept for compat).
--   sigma path  -> SUM(sales_incl_vat - COALESCE(vat_value, 0))   (native per-line VAT,
--                  same formula as mv_kpi_by_date.total_sales_ex_vat)
--   snap fallback -> snap_sales * 100 / (100 + COALESCE(vat_pct, 15))
--                  (daily_snapshots has vat_pct but not vat_value; 15% default
--                  mirrors prior FocusAreaPanel /1.15 hardcode)
--
-- No other incl-VAT sales fields exist in this RPC return (today_qty / soh are units).
--
-- APPLY ORDER: run this file, then reload schema (pg_notify line at end).
-- Returns TABLE change requires DROP -- per Function Change Protocol (DB-SCHEMA.md).
-- =============================================================================

-- 1. Drop all overloads (DB-SCHEMA.md Function Change Protocol)
DROP FUNCTION IF EXISTS public.rpc_focus_chart(text[], text[], text[]) CASCADE;

-- 2. Recreate with today_sales_ex_vat added
CREATE OR REPLACE FUNCTION public.rpc_focus_chart(p_eans text[], p_store_codes text[], p_dates text[])
 RETURNS TABLE(
   ean                text,
   description        text,
   size               text,
   unit               text,
   snapshot_date      text,
   store_code         text,
   today_sales        numeric,
   today_sales_ex_vat numeric,
   today_qty          numeric,
   soh                numeric
 )
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    WITH bridge AS (
        SELECT b.ean, b.store_code, b.product_code
        FROM   v_ean_bridge b
        WHERE  b.store_code = ANY(p_store_codes) AND b.ean = ANY(p_eans)
    ),
    sigma_side AS (
        SELECT b.ean, ss.store_code, ss.sale_date,
               SUM(ss.sales_incl_vat)                              AS sig_sales,
               SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0)) AS sig_sales_ex_vat,
               SUM(ss.qty)                                         AS sig_qty
        FROM   sigma_sales ss
        JOIN   bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
        WHERE  ss.store_code  = ANY(p_store_codes)
          AND  ss.sale_date   = ANY(p_dates::date[])
          AND  ss.period_kind = 'T' AND ss.txn_kind = 1
        GROUP  BY b.ean, ss.store_code, ss.sale_date
    ),
    snap_side AS (
        SELECT ds.ean, ds.store_code, ds.snapshot_date,
               ds.description, ds.size, ds.unit,
               ds.today_sales AS snap_sales, ds.today_qty AS snap_qty, ds.soh,
               ds.vat_pct
        FROM   daily_snapshots ds
        WHERE  ds.ean           = ANY(p_eans)
          AND  ds.store_code    = ANY(p_store_codes)
          AND  ds.snapshot_date = ANY(p_dates::date[])
    )
    SELECT
        COALESCE(sg.ean, sn.ean)                                       AS ean,
        COALESCE(sn.description, a.description, pc.description)        AS description,
        COALESCE(sn.size, pc.size_label)                              AS size,
        COALESCE(sn.unit, a.unit, pc.detail_unit)                    AS unit,
        COALESCE(sg.sale_date, sn.snapshot_date)::text                AS snapshot_date,
        COALESCE(sg.store_code, sn.store_code)                        AS store_code,
        ROUND(COALESCE(sg.sig_sales,    sn.snap_sales, 0)::numeric, 2) AS today_sales,
        ROUND(COALESCE(
            sg.sig_sales_ex_vat,
            CASE WHEN sn.snap_sales IS NOT NULL
                 THEN sn.snap_sales * 100.0 / (100.0 + COALESCE(sn.vat_pct, 15))
                 ELSE 0
            END,
            0
        )::numeric, 2)                                                 AS today_sales_ex_vat,
        COALESCE(sg.sig_qty,   sn.snap_qty)::numeric                  AS today_qty,
        sn.soh::numeric                                               AS soh
    FROM   sigma_side sg
    FULL   OUTER JOIN snap_side sn
           ON sn.ean = sg.ean AND sn.store_code = sg.store_code AND sn.snapshot_date = sg.sale_date
    LEFT   JOIN v_ean_bridge bb ON bb.ean = COALESCE(sg.ean, sn.ean)
                               AND bb.store_code = COALESCE(sg.store_code, sn.store_code)
    LEFT   JOIN sigma_articles a ON a.store_code = COALESCE(sg.store_code, sn.store_code)
                                AND a.product_code = bb.product_code
    LEFT   JOIN product_catalog pc ON pc.store_code = COALESCE(sg.store_code, sn.store_code)
                                  AND pc.ean = COALESCE(sg.ean, sn.ean)
    ORDER  BY snapshot_date ASC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_focus_chart(text[], text[], text[]) TO anon, authenticated;

-- Reload PostgREST schema cache
SELECT pg_notify('pgrst', 'reload schema');
