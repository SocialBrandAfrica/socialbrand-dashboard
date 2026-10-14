-- =============================================================================
-- eng257_rpc_bt_availability_family.sql   (migration eng257_rpc_bt_availability_family)
-- ENG-257: the Bonnie Tyler hero availability read is scan-keyed. Its stock is the
-- latest l2_soh_daily row of the HERO'S OWN product code and its rate is the hero's scan rate (l2_bt_heroes), so a hero that is a
-- pack code (stock sits on the single) would read OUT while its family holds stock, as milk did on the report leg (ENG-086).
-- The report rows already use the family rule (l2_family_ros, ENG-086); the same rule applies here.
--
-- THE RULE (the report rows' own, ENG-086): where the hero has a row in l2_family_ros, days_cover is the family's days cover
-- (family stock in singles over the family's daily rate in singles) and OUT / SHORT are judged on family stock and family cover;
-- where it has none, nothing changes. soh and daily_rate stay the hero's own scan figures (the BT page shows them beside the
-- hero's sales, in the hero's units); only the cover and the status take the family. A negative family cover is not a cover: it
-- reads NULL and the status is judged on the family stock (<= 0 is OUT).
--
-- MEASURED BEFORE BUILDING (14-10-2026 12:0x): 60 heroes (45 at 10116, 15 at 80175); none is in l2_family_ros (1,289 and 1,330 rows
-- at those stores), so this changes no status today. The class is closed so that it stays closed when the heroes list changes.
--
-- Same signature, same columns, same order: CREATE OR REPLACE keeps the ACL; no grant is restated. Rollback:
-- sql/_archive/rpc_bt_availability_71f44926_pre_eng257.sql (the live body, hash-proven md5 71f449267f3b294e7e5537333b350e17).
-- =============================================================================
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF md5(pg_get_functiondef('public.rpc_bt_availability()'::regprocedure)) <> '71f449267f3b294e7e5537333b350e17' THEN
    RAISE EXCEPTION 'rpc_bt_availability is not the body this migration was written against; refusing to overwrite';
  END IF;
END $$;

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
        -- the stock the status is judged on: the family's singles where there is a family, else the hero's own
        CASE WHEN fr.product_code IS NOT NULL THEN COALESCE(fr.family_soh_singles, 0) ELSE COALESCE(ls.soh, 0) END AS judge_soh,
        -- the cover: the family's where there is a family (negative = not a cover = NULL), else the scan cover as before
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
$function$;
