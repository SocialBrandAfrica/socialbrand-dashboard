-- eng208_v126_promo_bound_placement_vs_end_date.sql
-- RECORD of migration eng208_v126_promo_bound_placement_vs_end_date, applied 2026-09-14 by CC through the Supabase
-- connector. The text below is the migration as applied. The live body it produced, 79743e65 / 1,886, and its
-- COMMENT are carried hash-gated in sql/create_rpc_bloom_promo_for_delivery.sql. The two earlier ENG-208 migrations
-- of the same evening (eng208_promo_close_binds_delivery_date and eng208_promo_comment_named_limit_corrected) built
-- the delivery bound this one retires; their text is in the database's migration history and their effect is
-- recorded in that source file's header and in BUG-LOG ENG-208.

-- ENG-208 addendum (CC 2026-09-14): ORDERING-CANON v1.26 section C4 (PM commit 1b1a9d5, 18:14 SAST) retired the
-- closing-Thursday-binds-the-DELIVERY-date rule this function took at 17:50 SAST (migration
-- eng208_promo_close_binds_delivery_date), and replaced it with Pieter's floor-attested bound: a DC delivery matches
-- a promo when its order is PLACED on or before the promo END DATE. The order window stays open to the Thursday and
-- Sigma accepts the order, but the DC honours only what was placed by the end date; the engine binds on the honoured
-- bound. Leg B now tests the derived placement day (rpc_derive_placement_day, the one home, back in the lateral)
-- against pa.end_date, and the closing-Thursday arithmetic leaves. Leg A and direct routes are untouched.
-- Simulated before applying, three bodies (live, this one, the pre-ENG-208 one rebuilt md5-proven) on every DC
-- desk-date 2026-09-15 to 2026-10-09: against live, Sat 19-09 and Mon 21-09 regain 36 membership rows (the 11 sheet
-- lines ENG-208 moved), Thu 24-09 loses 216 at 10116 and 14 each at 21355 and 80579 (promos ending Mon 21-09, placed
-- Tue 22-09), Sat 03-10 at 10116 gains 10 and Mon 28-09 at 21355 gains 13; every other desk-date identical.
DO $do$
DECLARE d text; v text; i int; j int;
  a2n text := E'AS is_dc\n';
  a2o text := E'AS is_dc,\n           (SELECT pd.placement_date FROM public.rpc_derive_placement_day(p_store_code, p_route, p_delivery_date) pd) AS placement_date\n';
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
       WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one overload of rpc_bloom_promo_for_delivery';
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_promo_for_delivery';
  IF md5(d) <> '330c15a9ec12843fdd167ac3cce0d4c6' THEN RAISE EXCEPTION 'live body moved: %', md5(d); END IF;
  IF (length(d) - length(replace(d, a2n, ''))) / length(a2n) <> 1 THEN RAISE EXCEPTION 'lateral anchor not found exactly once'; END IF;
  IF (length(d) - length(replace(d, 'OR (cal.is_dc', ''))) / length('OR (cal.is_dc') <> 1 THEN RAISE EXCEPTION 'leg B anchor not found exactly once'; END IF;
  v := replace(d, a2n, a2o);
  i := position('OR (cal.is_dc' in v);
  j := position(E'\n  ORDER BY pa.product_code' in v);
  IF i = 0 OR j = 0 OR j < i THEN RAISE EXCEPTION 'leg B bounds not found'; END IF;
  v := left(v, i - 1) || E'OR (cal.is_dc\n        AND cal.placement_date <= pa.end_date))' || substr(v, j);
  IF position('promo_order_close_dow' in v) > 0 OR position('promo_order_week_start_dow' in v) > 0 THEN
    RAISE EXCEPTION 'the closing-Thursday leg is still present';
  END IF;
  IF (length(v) - length(replace(v, 'cal.placement_date <= pa.end_date', ''))) / length('cal.placement_date <= pa.end_date') <> 1 THEN
    RAISE EXCEPTION 'the new leg B is not present exactly once';
  END IF;
  EXECUTE v;
END $do$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text, text, date) IS
'GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route''s last delivery day on or before the promo end date, or (b) on a DC route, the order for D is PLACED on or before the promo end date, the placement day being the one rpc_derive_placement_day derives for D. A line failing both is not promo_active and orders on the normal TLX at normal quantity. The order window stays open to the promo_order_close_dow of the promo-end week and Sigma accepts the order there, but the DC honours only what was placed by the end date, and this function binds on the honoured bound (ORDERING-CANON v1.26 section C4). EVIDENCE: RULING, Pieter 2026-09-14, floor-attested on a test he placed himself: a promo ending Tuesday, ordered Monday for Wednesday and Tuesday for Thursday, both honoured; ordered Wednesday for Saturday, not honoured. CONFIDENCE: n=3 orders on one promo with both outcomes observed; no base rate across promos. FALSIFIER: a DC delivery whose order was placed after the promo end date and was honoured at promo cost. NAMED LIMIT: the placement day is the DERIVED one, not the day the buyer actually placed. Where the buyer places earlier than the derived weekday (a non-trading day such as Thursday 2026-09-24, Heritage Day, the derived placement day for the Saturday 2026-09-26 deliveries), a promo ending between the two days is understated here. Supersedes the two earlier 2026-09-14 comments, which bound the DELIVERY date to the closing Thursday (ORDERING-CANON v1.25, retired the same day, LEDGER section 6.22).';
