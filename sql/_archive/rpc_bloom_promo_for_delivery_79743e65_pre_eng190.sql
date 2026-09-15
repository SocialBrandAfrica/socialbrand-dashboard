-- rpc_bloom_promo_for_delivery 79743e655868687448967e1d067187fc / 1886, the live body before ENG-190 legs (2)+(3).
-- Captured byte-exact from pg_get_functiondef on 2026-09-15 (md5-proven). To roll back, run this file.
CREATE OR REPLACE FUNCTION public.rpc_bloom_promo_for_delivery(p_store_code text, p_route text, p_delivery_date date)
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
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC
$function$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS $c$GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC route, the order for D is PLACED on or before the promo end date, the placement day being the one rpc_derive_placement_day derives for D. A line failing both is not promo_active and orders on the normal TLX at normal quantity. The order window stays open to the promo_order_close_dow of the promo-end week and Sigma accepts the order there, but the DC honours only what was placed by the end date, and this function binds on the honoured bound (ORDERING-CANON v1.26 section C4). EVIDENCE: RULING, Pieter 2026-09-14, floor-attested on a test he placed himself: a promo ending Tuesday, ordered Monday for Wednesday and Tuesday for Thursday, both honoured; ordered Wednesday for Saturday, not honoured. CONFIDENCE: n=3 orders on one promo with both outcomes observed; no base rate across promos. FALSIFIER: a DC delivery whose order was placed after the promo end date and was honoured at promo cost. NAMED LIMIT: the placement day is the DERIVED one, not the day the buyer actually placed. Where the buyer places earlier than the derived weekday (a non-trading day such as Thursday 2026-09-24, Heritage Day, the derived placement day for the Saturday 2026-09-26 deliveries), a promo ending between the two days is understated here. Supersedes the two earlier 2026-09-14 comments, which bound the DELIVERY date to the closing Thursday (ORDERING-CANON v1.25, retired the same day, LEDGER section 6.22).$c$;
