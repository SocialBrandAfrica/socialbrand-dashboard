-- =============================================================================
-- eng086_rpc_report_rows_family_cover.sql   (APPLIED 14-10-2026, migration eng086_rpc_report_rows_family_cover)
-- ENG-086 / ENG-073 (dashboard lane): rpc_report_rows carries the FAMILY-resolved cover beside the scan-keyed one.
-- ADDITIVE: three new keys per row (family_daily_ros, family_days_cover, family_ratio) from l2_family_ros (unique per
-- store and product: 6,804 rows = 6,804 distinct). sp.daily_ros and sp.days_cover are UNCHANGED (R27, R29).
-- Same signature, SECURITY DEFINER, statement_timeout and STABLE, so CREATE OR REPLACE keeps the ACL; no GRANT.
-- Built FROM THE LIVE TEXT and gated on its md5 (72d93b9607790e9da702465cd5f7116b), never from the repo copy.
-- Rollback: sql/_archive/rpc_report_rows_72d93b96_pre_eng086.sql (hash-proven).
-- R22 after apply, 13-10-2026 (old keys only, md5 of the sorted row hashes, equal before and after):
--   80175 6,487 rows, R77,015.44, 954dadfb59606a16e6a848885e7c182e; 10116 10,357 rows, R152,477.39,
--   d3d21892c9daad1241caecd986cb6273. Rows with a family figure: 80175 194, 10116 236.
-- =============================================================================
SET LOCAL lock_timeout = '8s';
DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.rpc_report_rows(text[],text[])'::regprocedure);
  IF md5(v_def) <> '72d93b9607790e9da702465cd5f7116b' THEN
    RAISE EXCEPTION 'rpc_report_rows changed since it was read (md5 %), re-diff before applying', md5(v_def);
  END IF;
  v_new := replace(v_def,
    E'    sp.days_cover,\n    sp.tier,\n    sp.class\n',
    E'    sp.days_cover,\n    fr.family_daily_ros_91d AS family_daily_ros,\n    fr.family_days_cover,\n    fr.family_ratio,\n    sp.tier,\n    sp.class\n');
  IF v_new = v_def THEN RAISE EXCEPTION 'select-list anchor not found'; END IF;
  v_def := v_new;
  v_new := replace(v_def,
    E'  LEFT JOIN public.l2_rate_of_sale ros  ON ros.store_code = u.store_code AND ros.product_code = u.product_code\n',
    E'  LEFT JOIN public.l2_rate_of_sale ros  ON ros.store_code = u.store_code AND ros.product_code = u.product_code\n  LEFT JOIN public.l2_family_ros fr     ON fr.store_code = u.store_code AND fr.product_code = u.product_code\n');
  IF v_new = v_def THEN RAISE EXCEPTION 'join anchor not found'; END IF;
  EXECUTE v_new;
END
$mig$;
SELECT pg_notify('pgrst', 'reload schema');
