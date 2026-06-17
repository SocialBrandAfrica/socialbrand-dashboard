-- =============================================================================
-- create_rpc_focus_chart.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for rpc_focus_chart.
-- DDL previously lived in rpc_focus_area.sql + fix_rpc_product_detail_pricing.sql
-- (sediment). Extracted verbatim from LIVE 2026-06-17. Hybrid: sigma_sales (today
-- sales/qty via v_ean_bridge) + daily_snapshots (SOH), per SB-CC-DASH-SOURCE-002.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_focus_chart(p_eans text[], p_store_codes text[], p_dates text[])
 RETURNS TABLE(ean text, description text, size text, unit text, snapshot_date text, store_code text, today_sales numeric, today_qty numeric, soh numeric)
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
               SUM(ss.sales_incl_vat) AS sig_sales,
               SUM(ss.qty)            AS sig_qty
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
               ds.today_sales AS snap_sales, ds.today_qty AS snap_qty, ds.soh
        FROM   daily_snapshots ds
        WHERE  ds.ean          = ANY(p_eans)
          AND  ds.store_code   = ANY(p_store_codes)
          AND  ds.snapshot_date = ANY(p_dates::date[])
    )
    SELECT
        COALESCE(sg.ean, sn.ean)                                       AS ean,
        COALESCE(sn.description, a.description, pc.description)        AS description,
        COALESCE(sn.size, pc.size_label)                              AS size,
        COALESCE(sn.unit, a.unit, pc.detail_unit)                    AS unit,
        COALESCE(sg.sale_date, sn.snapshot_date)::text                AS snapshot_date,
        COALESCE(sg.store_code, sn.store_code)                        AS store_code,
        ROUND(COALESCE(sg.sig_sales, sn.snap_sales, 0)::numeric, 2)   AS today_sales,
        COALESCE(sg.sig_qty, sn.snap_qty)::numeric                    AS today_qty,
        sn.soh::numeric                                              AS soh
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
