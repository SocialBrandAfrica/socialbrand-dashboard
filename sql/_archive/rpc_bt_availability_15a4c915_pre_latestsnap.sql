-- ROLLBACK FILE for migration bt012_rpc_bt_availability_latest_snap_probe (dashboard lane, 14-10-2026).
-- The LIVE body of public.rpc_bt_availability() before the latest_snap probe, md5 15a4c915adfd7097f026dc382325e512,
-- 1,911 characters, hash-gated before this file was written. To roll back: run this file (CREATE OR REPLACE keeps the ACL).

CREATE OR REPLACE FUNCTION public.rpc_bt_availability()
 RETURNS TABLE(store_code text, merch_group_nr integer, label text, bucket text, department_name text, product_code bigint, ean text, description text, soh numeric, daily_rate numeric, days_cover numeric, status text)
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
WITH latest_snap AS (
    SELECT store_code, MAX(snapshot_date) AS snap_date
    FROM public.l2_soh_daily
    GROUP BY store_code
),
j AS (
    SELECT
        h.store_code, h.merch_group_nr, h.label, h.bucket, h.department_name, h.product_code, h.ean, h.description,
        h.rn,
        COALESCE(ls.soh, 0)  AS soh,
        h.daily_rate,
        fr.product_code IS NOT NULL AS has_family,
        CASE WHEN fr.product_code IS NOT NULL THEN COALESCE(fr.family_soh_singles, 0) ELSE COALESCE(ls.soh, 0) END AS judge_soh,
        CASE WHEN fr.product_code IS NOT NULL THEN
                  CASE WHEN fr.family_days_cover >= 0 THEN fr.family_days_cover END
             WHEN h.daily_rate > 0 THEN COALESCE(ls.soh, 0) / h.daily_rate
        END AS judge_cover
    FROM public.l2_bt_heroes h
    LEFT JOIN latest_snap sn ON sn.store_code = h.store_code
    LEFT JOIN public.l2_soh_daily ls
        ON  ls.store_code    = h.store_code
        AND ls.product_code  = h.product_code
        AND ls.snapshot_date = sn.snap_date
    LEFT JOIN public.l2_family_ros fr
        ON  fr.store_code    = h.store_code
        AND fr.product_code  = h.product_code
)
SELECT
    j.store_code, j.merch_group_nr, j.label, j.bucket, j.department_name, j.product_code, j.ean, j.description,
    j.soh,
    j.daily_rate,
    j.judge_cover AS days_cover,
    CASE
        WHEN j.judge_soh <= 0                                  THEN 'OUT'
        WHEN j.judge_cover IS NOT NULL AND j.judge_cover < 7   THEN 'SHORT'
        ELSE 'OK'
    END AS status
FROM j
ORDER BY j.store_code, j.merch_group_nr, j.rn;
$function$
;
