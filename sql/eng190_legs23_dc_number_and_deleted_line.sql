-- eng190_legs23_dc_number_and_deleted_line.sql
--
-- ENG-190 legs (2) and (3), WITHOUT leg (1). PM ruling 2026-09-15 16:3x SAST, BUG-LOG ENG-190 addendum 3:
-- "Ship legs (2) and (3) together, without leg (1), as their own migration." Leg (1), the promo runs on the
-- placement day, stays withdrawn: Sigma's Promotion Order screen suggests RI4 quantities before RI4's shelf
-- start, so a promo that has not started may be a legitimate buy-in. The buy-in start bound is unchanged.
--
-- THE RULE, DC routes only. Direct routes are unchanged.
--   (2) The promo carries a DC promotion number, read with the same derivation as the promo_suffix column,
--       so a store markdown or loyalty construct never rides the DC promo sheet.
--   (3) A status '0' line inside a promo that holds a live status '1' line is a line Sigma deleted and the
--       mirror kept (ENG-189). It is not orderable. A promo with no live line yet keeps its status '0' lines.
--   The DISTINCT ON gains a line_id tiebreak (line_id is unique per store, the table's primary key).
--
-- WHAT CHANGED FROM THE HELD BUILD (dashboard c3eee32, sql/eng190_dc_promo_current_only.sql, never applied,
-- kept as the record of the three-leg build):
--   - leg (1) is gone, and this build sits on the live ENG-208 body (79743e65).
--   - leg (3) excludes status '0' only. The held form kept status '1' only, which would also have dropped
--     248 status '2' rows in live promos (10116 3, 80579 245). LEDGER 6.22 names a status '2' row as the
--     populated payload row, and PM counted status '0'.
--
-- SOURCE CHECKS, 2026-09-15 16:5x SAST.
--   Leg (2): promos ending on or after 2026-09-08, 29 of 29 without a DC number carry promo_type 0 and 88 of
--   88 with one carry promo_type 1. Over the whole table the two are NOT one signal: 1,108 promo_type 1
--   promos carry no DC number (none ending after 2026-09-08). The regex stays, as ruled.
--   Leg (3): status '0' rows in promos holding a live line, 10116 1,949, 80175 1,966, 21355 220, 80176 45,
--   80579 502. PM's count exactly.
--
-- DRY RUN, 2026-09-15 17:0x SAST. A pg_temp copy of this body against the live function in one snapshot,
-- every desk-date cached in the last 40 hours. Promo rows per desk (dropped by leg 2 / leg 3 / other):
--   10116 DC_AMBIENT  17-09 2,443 -> 2,399 (18/26/0) | 19-09 2,438 -> 2,399 (13/26/0) | 24-09 2,210 -> 2,170 (12/28/0)
--   80175 DC_AMBIENT  16-09 and 19-09 2,395 -> 2,371 (0/24/0)
--   21355 DC_TOPS     17-09 and 21-09 460 -> 448 | 24-09 442 -> 430 (12/0/0)
--   80176 DC_TOPS     16-09 and 19-09 437 -> 432 (5/0/0)
--   80579 DC_TOPS     17-09 and 21-09 426 -> 418 | 24-09 408 -> 400 (8/0/0)
--   Every DIRECT desk: 0 differences and 0 pick changes. No row added anywhere.
-- On the cached sheets: 10116 Thu 17-09 (1266) 6 promo lines leave the promo sheet, none geared, R1,444.00,
-- the same value on the normal TLX. 10116 Sat 19-09 (1270) 7 lines, 1 geared, R2,057.00 to R1,721.00 at
-- normal. 10116 Thu 24-09 (1220) 5 lines, R1,167.00. 80175 3 and 2 lines and 80579 1 line, all at 0 packs.
-- The 10116 and 80175 lines are RI1 or RI2 lines Sigma deleted. The 80579 line is promo 120, no DC number.
--
-- ASSERTED REPLACE. def 79743e655868687448967e1d067187fc / 1,886 becomes 0c41c4657e506b34668d5eec9ddfc894 / 3,124.
-- COMMENT 8b1cc998aaeccebc922025a2643afde7 becomes 9f14b0c668bb0468281d19b551e1355f, stating legs (2) and (3), their evidence
-- and their falsifier. Rollback: sql/_archive/rpc_bloom_promo_for_delivery_79743e65_pre_eng190.sql.
-- After the apply: refresh_bloom_order_cache_all for DC_AMBIENT and DC_TOPS. The grants are unchanged
-- (CREATE OR REPLACE keeps the ACL: authenticated and service_role, no PUBLIC, no anon).
--
SET lock_timeout = '5s';
DO $mig$
DECLARE v_old text; v_oldc text; v_new text; v_newc text;
  v_cmt text := $c$GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208 + ENG-190. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC route, the order for D is PLACED on or before the promo end date, the placement day being the one rpc_derive_placement_day derives for D. On a DC route the line must also pass two tests (ENG-190, PM ruling 2026-09-15): the promo carries a DC promotion number, the promo_suffix derivation, so a store markdown never rides the DC promo sheet, and the line is not a status '0' line inside a promo holding a live status '1' line, which is a line Sigma deleted and the mirror kept (ENG-189). A line failing (a) and (b), or either DC test, is not promo_active and orders on the normal TLX at normal quantity. The order window stays open to the promo_order_close_dow of the promo-end week and Sigma accepts the order there, but the DC honours only what was placed by the end date, and this function binds on the honoured bound (ORDERING-CANON v1.26 section C4). EVIDENCE: RULING, Pieter 2026-09-14, floor-attested on a test he placed himself: a promo ending Tuesday, ordered Monday for Wednesday and Tuesday for Thursday, both honoured; ordered Wednesday for Saturday, not honoured. CONFIDENCE: n=3 orders on one promo with both outcomes observed; no base rate across promos. ENG-190 tests: CONTROLLED, whole population 2026-09-15, promos ending on or after 2026-09-08: 29 of 29 without a DC number are promo_type 0 and 88 of 88 with one are promo_type 1, and status '0' lines inside promos holding a live line number 10116 1,949, 80175 1,966, 21355 220, 80176 45, 80579 502. FALSIFIER: a DC delivery whose order was placed after the promo end date and was honoured at promo cost, or a DC sheet line promo_active on a promo with no DC number or on a status '0' line in a promo holding live lines. NAMED LIMIT: the placement day is the DERIVED one, not the day the buyer actually placed. Where the buyer places earlier than the derived weekday (a non-trading day such as Thursday 2026-09-24, Heritage Day, the derived placement day for the Saturday 2026-09-26 deliveries), a promo ending between the two days is understated here. Supersedes the two earlier 2026-09-14 comments, which bound the DELIVERY date to the closing Thursday (ORDERING-CANON v1.25, retired the same day, LEDGER section 6.22).$c$;
BEGIN
  SELECT md5(pg_get_functiondef('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure)),
         md5(obj_description('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure, 'pg_proc'))
    INTO v_old, v_oldc;
  IF v_old <> '79743e655868687448967e1d067187fc' THEN
    RAISE EXCEPTION 'ENG-190 legs 2+3: rpc_bloom_promo_for_delivery moved under us, live md5 %, expected 79743e655868687448967e1d067187fc', v_old;
  END IF;
  IF v_oldc <> '8b1cc998aaeccebc922025a2643afde7' THEN
    RAISE EXCEPTION 'ENG-190 legs 2+3: COMMENT moved under us, live md5 %, expected 8b1cc998aaeccebc922025a2643afde7', v_oldc;
  END IF;
  EXECUTE $body$CREATE OR REPLACE FUNCTION public.rpc_bloom_promo_for_delivery(p_store_code text, p_route text, p_delivery_date date)
 RETURNS TABLE(product_code bigint, promo_nr bigint, start_date date, end_date date, status text, promo_unit_cost numeric, promo_description text, promo_suffix text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT DISTINCT ON (pa.product_code)
         pa.product_code,
         pa.promo_nr,
         pa.start_date,
         pa.end_date,
         pa.status,
         pa.list_cost,
         sp2.description,
         COALESCE(
           substring(sp2.description from '\(([A-Za-z0-9]+)\)\s*$'),
           substring(sp2.description from 'DC Promotion Number\s+(\S+)')
         )
  FROM public.sigma_promotion_articles pa
  LEFT JOIN public.sigma_promotions sp2
         ON sp2.store_code = pa.store_code
        AND sp2.promo_nr   = pa.promo_nr
  -- ENG-190 leg (3): the promos holding at least one live (status '1') line at this store, read once.
  LEFT JOIN (SELECT DISTINCT a2.promo_nr FROM public.sigma_promotion_articles a2
              WHERE a2.store_code = p_store_code AND a2.status = '1') live
         ON live.promo_nr = pa.promo_nr
  CROSS JOIN LATERAL (
    SELECT sc.delivery_dows, sc.promo_buyin_lead_days, sc.order_cutoff_days,
           NOT EXISTS (SELECT 1 FROM public.bloom_route_config rc WHERE rc.store_code = sc.store_code AND rc.route_key = sc.route_key) AS is_dc,
           (SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, p_delivery_date) pd) AS placement_date
    FROM public.supplier_calendar sc
    WHERE sc.store_code = p_store_code
      AND sc.route_key  = p_route
    LIMIT 1
  ) cal
  WHERE pa.store_code = p_store_code
    AND p_delivery_date >= (pa.start_date - cal.promo_buyin_lead_days::int)
    AND (p_delivery_date <= (
      SELECT MAX(gs)::date
      FROM generate_series(pa.end_date - 6, pa.end_date, interval '1 day') gs
      WHERE EXTRACT(ISODOW FROM gs)::smallint = ANY(cal.delivery_dows)
    )
  OR (cal.is_dc
        AND cal.placement_date <= pa.end_date))
    -- ENG-190 legs (2) and (3), DC routes only (PM ruling 2026-09-15, BUG-LOG ENG-190 addendum 3).
    -- Direct routes are unchanged. Leg (1), the promo runs on the placement day, stays withdrawn.
    -- (2) The promo carries a DC promotion number, the same derivation as promo_suffix above, so a
    --     store markdown or loyalty construct never rides the DC promo sheet.
    -- (3) A status '0' line inside a promo that holds a live line is a line Sigma deleted and the
    --     mirror kept (ENG-189). A promo with no live line yet keeps its status '0' lines, and a
    --     status '2' line, the populated payload row, is never excluded here.
    AND (NOT cal.is_dc
      OR (COALESCE(substring(sp2.description from '\(([A-Za-z0-9]+)\)\s*$'),
                   substring(sp2.description from 'DC Promotion Number\s+(\S+)')) IS NOT NULL
          AND (pa.status IS DISTINCT FROM '0' OR live.promo_nr IS NULL)))
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC, pa.line_id DESC
$function$
$body$;
  EXECUTE format('COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS %L', v_cmt);
  SELECT md5(pg_get_functiondef('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure)),
         md5(obj_description('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure, 'pg_proc'))
    INTO v_new, v_newc;
  IF v_new <> '0c41c4657e506b34668d5eec9ddfc894' THEN
    RAISE EXCEPTION 'ENG-190 legs 2+3: post-apply md5 %, expected 0c41c4657e506b34668d5eec9ddfc894', v_new;
  END IF;
  IF v_newc <> '9f14b0c668bb0468281d19b551e1355f' THEN
    RAISE EXCEPTION 'ENG-190 legs 2+3: post-apply COMMENT md5 %, expected 9f14b0c668bb0468281d19b551e1355f', v_newc;
  END IF;
END
$mig$;
