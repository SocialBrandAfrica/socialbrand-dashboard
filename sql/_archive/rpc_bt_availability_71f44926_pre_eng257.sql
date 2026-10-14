-- ROLLBACK FILE for migration eng257_rpc_bt_availability_family (ENG-257, dashboard lane, 14-10-2026).
-- The LIVE body of public.rpc_bt_availability() before the family join, md5 71f449267f3b294e7e5537333b350e17,
-- 1,502 characters, hash-gated before this file was written. To roll back: run this file (CREATE OR REPLACE keeps the ACL).

CREATE OR REPLACE FUNCTION public.rpc_bt_availability()
 RETURNS TABLE(store_code text, merch_group_nr integer, label text, bucket text, department_name text, product_code bigint, ean text, description text, soh numeric, daily_rate numeric, days_cover numeric, status text)
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
WITH latest_snap AS (
    SELECT store_code, MAX(snapshot_date) AS snap_date
    FROM public.l2_soh_daily
    GROUP BY store_code
)
SELECT
    h.store_code,
    h.merch_group_nr,
    h.label,
    h.bucket,
    h.department_name,
    h.product_code,
    h.ean,
    h.description,
    COALESCE(ls.soh, 0)                                                 AS soh,
    h.daily_rate,
    CASE WHEN h.daily_rate > 0
         THEN COALESCE(ls.soh, 0) / h.daily_rate
         ELSE NULL END                                                   AS days_cover,
    CASE
        WHEN COALESCE(ls.soh, 0) <= 0                                   THEN 'OUT'
        WHEN h.daily_rate > 0
         AND COALESCE(ls.soh, 0) / h.daily_rate < 7                    THEN 'SHORT'
        ELSE 'OK'
    END                                                                  AS status
FROM public.l2_bt_heroes h
LEFT JOIN latest_snap sn ON sn.store_code = h.store_code
LEFT JOIN public.l2_soh_daily ls
    ON  ls.store_code    = h.store_code
    AND ls.product_code  = h.product_code
    AND ls.snapshot_date = sn.snap_date
ORDER BY h.store_code, h.merch_group_nr, h.rn;
$function$
;
