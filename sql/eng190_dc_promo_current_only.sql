-- eng190_dc_promo_current_only.sql
--
-- ENG-190. On a DC route only a CURRENT promo is orderable. Pieter, from the floor, 2026-09-15:
-- "the current promo's MUST be available to order and the old ones must not be active", with 1674
-- as the example. 1674 sits on RI4 (shelf 22-09 to 07-10) and was matched on the 15-09 placement by
-- the 7-day buy-in seed, so 196 lines on the 10116 Thursday sheet were geared on promos that have
-- not started (R117,998.47 geared, R31,989.05 at normal quantity, cache 1223).
--
-- THE RULE, DC routes only. Direct routes are unchanged (0 differences on every direct desk).
--   (1) The promo runs on the placement day: start_date <= placement <= end_date.
--   (2) It carries a DC promotion number, so a store markdown never rides the DC promo sheet.
--   (3) The line is live in Sigma: status '1', unless the promo has no live line yet. A status '0'
--       line inside a live promo is a line Sigma deleted and our mirror kept (ENG-189): all 1,854
--       such lines in RI1, RI2 and 6I3 at 10116 were not re-sent on the 14-09 run.
--   The DISTINCT ON gains a line_id tiebreak.
--
-- DRY RUN, 2026-09-15 10:4x SAST, same rollback block as ENG-188. Promo rows per desk:
--   10116 DC_AMBIENT  17-09 2,443 -> 969 | 19-09 2,438 -> 984 | 24-09 2,210 -> 2,167
--   80175 DC_AMBIENT  19-09 2,395 -> 950
--   21355 DC_TOPS     17-09 460 -> 222 | 21-09 460 -> 227 | 24-09 442 -> 430
--   80176 DC_TOPS     19-09 437 -> 225
--   80579 DC_TOPS     17-09 426 -> 211 | 21-09 426 -> 216 | 24-09 408 -> 400
--   Every DIRECT desk: 0 differences.
-- The TOPS DC desks lose RX4 (starts 21-09) by the same rule. Named for Pieter to confirm.
--
-- ASSERTED REPLACE. 79743e655868687448967e1d067187fc / 1,886 becomes
-- eb8e9e6d47451c9902532775689104cd / 3,227. NOT APPLIED: refused by the session's permission gate
-- on 2026-09-15. ORDERING-CANON C4 still names the 7-day buy-in as the running interim, and the
-- churn is PM's. After it applies, run sql/eng188_eng190_post_apply_refresh.sql.
--
SET lock_timeout = '5s';
DO $mig$
DECLARE v_old text; v_new text;
BEGIN
  SELECT md5(pg_get_functiondef('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure)) INTO v_old;
  IF v_old <> '79743e655868687448967e1d067187fc' THEN
    RAISE EXCEPTION 'ENG-190: rpc_bloom_promo_for_delivery moved under us, live md5 %, expected 79743e655868687448967e1d067187fc', v_old;
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
  -- ENG-190: the promos with at least one live line at this store, read once.
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
    AND (
      -- Direct routes: unchanged (ORDERING-CANON C4, direct routes untouched).
      (NOT cal.is_dc
        AND p_delivery_date >= (pa.start_date - cal.promo_buyin_lead_days::int)
        AND p_delivery_date <= (
          SELECT MAX(gs)::date
          FROM generate_series(pa.end_date - 6, pa.end_date, interval '1 day') gs
          WHERE EXTRACT(ISODOW FROM gs)::smallint = ANY(cal.delivery_dows)
        ))
      OR
      -- ENG-190 (Pieter, from the floor, 2026-09-15): on a DC route only a CURRENT promo is orderable.
      -- (1) It runs on the placement day. A promo that has not started is not on promotion (1674 on RI4,
      --     shelf 22-09, placed 15-09), and one that has ended is not active. The buy-in lead is not read here.
      -- (2) It carries a DC promotion number, so a store markdown never rides the DC promo sheet.
      -- (3) The line is live in Sigma: status '1', unless the promo has no live line yet. A status '0'
      --     line inside a live promo is a line Sigma deleted and our mirror kept (ENG-189).
      (cal.is_dc
        AND COALESCE(cal.placement_date, p_delivery_date) BETWEEN pa.start_date AND pa.end_date
        AND COALESCE(substring(sp2.description from '\(([A-Za-z0-9]+)\)\s*$'),
                     substring(sp2.description from 'DC Promotion Number\s+(\S+)')) IS NOT NULL
        AND (pa.status = '1' OR live.promo_nr IS NULL))
    )
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC, pa.line_id DESC
$function$
$body$;
  SELECT md5(pg_get_functiondef('public.rpc_bloom_promo_for_delivery(text, text, date)'::regprocedure)) INTO v_new;
  IF v_new <> 'eb8e9e6d47451c9902532775689104cd' THEN
    RAISE EXCEPTION 'ENG-190: rpc_bloom_promo_for_delivery post-apply md5 %, expected eb8e9e6d47451c9902532775689104cd', v_new;
  END IF;
END
$mig$;
