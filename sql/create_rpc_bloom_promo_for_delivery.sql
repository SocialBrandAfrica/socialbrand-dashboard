-- create_rpc_bloom_promo_for_delivery.sql
--
-- ENG-147. THE ONE HOME for "does a promo price this delivery for this line".
-- Migration: eng147_promo_membership_one_home (2026-08-27).
--
-- GENERATED FROM LIVE via pg_get_functiondef on 2026-08-30, never hand-written,
-- so this file can be hash-gated against the database (ENG-115 class rule).
--
-- WHY IT EXISTS. The SB-CC-BLOOM-026 §5(b2) hidden-append leg never computed
-- promo membership, so every appended line carried promo_active = false. The
-- frontend export split reads that flag, so a hidden line the buyer ordered
-- inside a live DC promo window exported to the NORMAL TLX with no promo suffix
-- reaching the DC. Pieter found it on his own 80175 exports, 2026-08-27:
-- 12 lines / 13 packs / R3,205.89 on the 2026-08-29 order, and 152 hidden lines
-- group-wide sitting inside a live promo window.
--
-- THE RULE IS LIFTED VERBATIM out of rpc_bloom_order_recipe's own promo_match
-- CTE, read via pg_get_functiondef, NEVER re-derived from canon prose, so the
-- two cannot disagree (R33: the fix lives in L2 once for everyone).
--
-- ORDERING-CANON §C4: the buy-in prices from the PLACEMENT side. A promo prices
-- delivery D when D is on or after (start - promo_buyin_lead_days) and on or
-- before the LAST delivery day of that route falling on or before end_date.
--
-- NAMED RESIDUAL (R30 addendum 3, site count discharged by PM 2026-08-27): the
-- rule is still carried inline at THREE other sites -- rpc_bloom_order_recipe,
-- rpc_bloom_order_dc and l2_stock_band. They repoint onto this one home in the
-- bundled recipe opening (ORDERING-CANON §H opening gate), never one at a time.
--
-- ENG-082, 2026-09-10 -- THE CLOSING BOUND GAINS THE THURSDAY RULE (Pieter ruling,
-- from the floor: "it's still open till thursdays for all promos ending during that
-- week"). On a DC route (a route with no bloom_route_config row), a delivery ALSO
-- matches a promo when its placement date, the delivery less the route's derived
-- order_cutoff_days, falls on or before the closing day of the promo's end week.
-- The day and the week start are config: forge_config promo_order_close_dow (4) and
-- promo_order_week_start_dow (1). A missing key leaves the old bound alone. Direct
-- routes are untouched. Migration eng082_promo_close_thursday_of_end_week, applied by
-- asserted replace() on the live body; sql/eng082_promo_close_thursday_of_end_week.sql
-- is the record. The recipe's promo_geared split (normal quantity after the shelf
-- end) rides the same migration. Live md5 after that first write:
-- e09d55868beaddf74e2d10243b66913e (commit 32781fb carries that body). Its placement
-- date is superseded by addendum 8 below, and so is the COMMENT it left in place.
--
-- SITE COUNT AT SOURCE, 2026-09-10 (pg_proc). This supersedes the NAMED RESIDUAL
-- paragraph above, which was true on 2026-08-27 and is kept as lineage. Two readers
-- of this home: rpc_bloom_order_recipe and refresh_bloom_order_cache. No live function
-- restates the rule. rpc_bloom_order_dc carries no promo window and is called by no
-- function and no cron job. refresh_l2_stock_band keeps its own gearing window, start
-- less the store's buy-in lead to end_date, which agrees with the recipe's promo_geared
-- split. Three dead shadow copies of the recipe (_shadow_recipe_eng052,
-- _w18_shadow_orig_recipe, _w19_shadow_pre_eng064) still carry the pre-ENG-147 inline
-- rule and are called by nothing.
--
-- ENG-082 ADDENDUM 8, 2026-09-10 -- THE PLACEMENT DAY IS DERIVED FROM THE ORDER LEDGER.
-- The Thursday leg took the placement day as the delivery less order_cutoff_days in
-- calendar days, which put a Monday delivery's placement on Saturday, a day no TOPS DC
-- order goes in, so RW4 and RW5 missed the TOPS Monday sheets. Pieter, from the floor:
-- TOPS orders go in any day, but the Thursday order serves the Saturday or the Monday
-- delivery. The placement day is now the last day on or before the delivery less
-- order_cutoff_days whose weekday carried at least in_transit_min_received_orders DC
-- orders in the dow_regime_lookback_days window before the delivery (ORDERING-CANON A5,
-- read from sigma_orders with the route test rpc_derive_order_cutoff uses). No new key.
-- A route with no weekday clearing the floor keeps the calendar-day answer. Migration
-- eng082_promo_placement_day, record sql/eng082_promo_placement_day.sql. Live md5 after:
-- 8feb43c04c694b4fa6118c87cfa0c7cd / 3,687. The body below is that live text, hash-gated
-- before commit. The same write replaced the COMMENT, which now states the current rule.
-- The 2026-08-27 comment it supersedes is kept at the foot of this file as lineage.

-- RE-SPLICED FROM LIVE 2026-09-11 by CC (ENG-082 H14, migration eng082_h13_h14_placement_one_home): the body is
-- live 3291e2b932b7684a78759d47dc6d3ea4 / 2,488 chars, hash-gated on disk. The inline placement derivation is
-- replaced by a read of the one home, rpc_derive_placement_day. Membership identical on all 40 DC desk-dates to
-- 2026-10-09 (39,645 lines, fingerprint 3beb7f71b0110208cb408833b957b28c). Prior body 8feb43c04c694b4fa6118c87cfa0c7cd,
-- retired 2026-09-11 (R28).

-- ENG-208, 2026-09-14 17:50 SAST -- LINEAGE (R28), true for 54 minutes. ORDERING-CANON v1.25 section C4 bound the
-- closing Thursday to the DELIVERY date: leg B tested p_delivery_date, and the lateral's call to
-- rpc_derive_placement_day left. Migration eng208_promo_close_binds_delivery_date, asserted on live 3291e2b9; body
-- 330c15a9ec12843fdd167ac3cce0d4c6 / 2,348, COMMENT written twice (the second, eng208_promo_comment_named_limit_corrected,
-- corrected the named limit's reason). Its R22: 11 sheet lines and 47 packs left the promo sheet for the normal TLX.
-- R12,198.39 was the normal value of those packs changing sheets, never a cost difference: the mirror holds no promo
-- cost for status 0 lines. Retired by ORDERING-CANON v1.26 at 18:14 SAST (PM commit 1b1a9d5, stamped 16:14 +0000).
-- The file committed at 0dce938 carried that body correctly but spliced its COMMENT at a stale offset, which corrupted
-- the COMMENT and the start of the lineage block. This file is rebuilt from fe5e585 and replaces it.
-- Prior body 3291e2b932b7684a78759d47dc6d3ea4, retired 2026-09-14 17:50 (R28).

-- ENG-208 ADDENDUM, 2026-09-14 18:44 SAST -- THE BOUND IS THE PLACEMENT DAY AGAINST THE PROMO END DATE (ORDERING-CANON
-- v1.26 section C4, Pieter's floor test). A DC delivery matches a promo when its order is PLACED on or before the promo
-- END DATE. The window stays open to the Thursday and Sigma accepts the order, but the DC honours only what was placed
-- by the end date. Leg B tests the placement day rpc_derive_placement_day derives (back in the lateral) against
-- pa.end_date, and the closing-Thursday arithmetic leaves. Leg A, the buy-in start bound and direct routes are
-- unchanged. Migration eng208_v126_promo_bound_placement_vs_end_date, asserted on live 330c15a9. Live md5 after:
-- 79743e655868687448967e1d067187fc / 1,886, hash-gated on disk against the body below, and COMMENT 8b1cc998 likewise.
-- R22 (BUG-LOG ENG-208 addendum 1): the five Saturday and Monday sheets rebuild identical to their pre-ENG-208 builds.
-- On Thursday 24-09, 54 sheet lines (10116 46, 21355 4, 80579 4; promos ending Mon 21-09, placed Tue 22-09) leave the
-- promo sheet at normal quantity, and every desk total is unchanged to the cent.
-- NAMED LIMIT: the placement day is the DERIVED one. A buyer who places earlier than the derived weekday can hold a
-- promo this function understates. Thursday 24-09 is Heritage Day, a non-trading day, and it is the derived placement
-- day for the Saturday 26-09 deliveries.
-- Prior body 330c15a9ec12843fdd167ac3cce0d4c6, retired 2026-09-14 18:44 (R28).

-- ENG-190 LEGS (2) AND (3), 2026-09-15 17:04 SAST -- ON A DC ROUTE ONLY A PROMO WITH A DC NUMBER, AND NEVER A LINE
-- SIGMA DELETED (PM ruling, BUG-LOG ENG-190 addendum 3). Two tests join the DC route: the promo carries a DC promotion
-- number, the promo_suffix derivation, and the line is not a status '0' line inside a promo holding a live status '1'
-- line. A promo with no live line yet keeps its status '0' lines, and a status '2' payload row is never excluded. The
-- DISTINCT ON gains a line_id tiebreak. Leg (1) of the held build (c3eee32), the promo runs on the placement day, is
-- withdrawn: Sigma's Promotion Order screen suggests RI4 quantities before RI4's shelf start. Direct routes unchanged.
-- Migration eng190_legs23_dc_number_and_deleted_line, asserted on live 79743e65. Live md5 after: 0c41c4657e506b34668d5eec9ddfc894
-- / 3,124, hash-gated on disk against the body below, and COMMENT 9f14b0c6 likewise.
-- R22: BUG-LOG ENG-190 addendum 4. Rollback: sql/_archive/rpc_bloom_promo_for_delivery_79743e65_pre_eng190.sql.
-- Prior body 79743e655868687448967e1d067187fc, retired 2026-09-15 17:04 (R28).

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
$function$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS $c$GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208 + ENG-190. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC route, the order for D is PLACED on or before the promo end date, the placement day being the one rpc_derive_placement_day derives for D. On a DC route the line must also pass two tests (ENG-190, PM ruling 2026-09-15): the promo carries a DC promotion number, the promo_suffix derivation, so a store markdown never rides the DC promo sheet, and the line is not a status '0' line inside a promo holding a live status '1' line, which is a line Sigma deleted and the mirror kept (ENG-189). A line failing (a) and (b), or either DC test, is not promo_active and orders on the normal TLX at normal quantity. The order window stays open to the promo_order_close_dow of the promo-end week and Sigma accepts the order there, but the DC honours only what was placed by the end date, and this function binds on the honoured bound (ORDERING-CANON v1.26 section C4). EVIDENCE: RULING, Pieter 2026-09-14, floor-attested on a test he placed himself: a promo ending Tuesday, ordered Monday for Wednesday and Tuesday for Thursday, both honoured; ordered Wednesday for Saturday, not honoured. CONFIDENCE: n=3 orders on one promo with both outcomes observed; no base rate across promos. ENG-190 tests: CONTROLLED, whole population 2026-09-15, promos ending on or after 2026-09-08: 29 of 29 without a DC number are promo_type 0 and 88 of 88 with one are promo_type 1, and status '0' lines inside promos holding a live line number 10116 1,949, 80175 1,966, 21355 220, 80176 45, 80579 502. FALSIFIER: a DC delivery whose order was placed after the promo end date and was honoured at promo cost, or a DC sheet line promo_active on a promo with no DC number or on a status '0' line in a promo holding live lines. NAMED LIMIT: the placement day is the DERIVED one, not the day the buyer actually placed. Where the buyer places earlier than the derived weekday (a non-trading day such as Thursday 2026-09-24, Heritage Day, the derived placement day for the Saturday 2026-09-26 deliveries), a promo ending between the two days is understated here. Supersedes the two earlier 2026-09-14 comments, which bound the DELIVERY date to the closing Thursday (ORDERING-CANON v1.25, retired the same day, LEDGER section 6.22).$c$;

-- LINEAGE (R28), newest first. Kept as written, never deleted.
-- The v1.26 comment (migration eng208_v126_promo_bound_placement_vs_end_date), superseded 2026-09-15 17:04
-- by ENG-190 legs (2) and (3), because it stated no DC-route test:
-- 'GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208. The one home for promo membership on a delivery date, read by
-- rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its
-- start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the
-- promo end date, or (b) on a DC route, the order for D is PLACED on or before the promo end date, the placement day
-- being the one rpc_derive_placement_day derives for D. A line failing both is not promo_active and orders on the
-- normal TLX at normal quantity. The order window stays open to the promo_order_close_dow of the promo-end week and
-- Sigma accepts the order there, but the DC honours only what was placed by the end date, and this function binds on
-- the honoured bound (ORDERING-CANON v1.26 section C4). EVIDENCE: RULING, Pieter 2026-09-14, floor-attested on a
-- test he placed himself: a promo ending Tuesday, ordered Monday for Wednesday and Tuesday for Thursday, both
-- honoured; ordered Wednesday for Saturday, not honoured. CONFIDENCE: n=3 orders on one promo with both outcomes
-- observed; no base rate across promos. FALSIFIER: a DC delivery whose order was placed after the promo end date and
-- was honoured at promo cost. NAMED LIMIT: the placement day is the DERIVED one, not the day the buyer actually
-- placed. Where the buyer places earlier than the derived weekday (a non-trading day such as Thursday 2026-09-24,
-- Heritage Day, the derived placement day for the Saturday 2026-09-26 deliveries), a promo ending between the two
-- days is understated here. Supersedes the two earlier 2026-09-14 comments, which bound the DELIVERY date to the
-- closing Thursday (ORDERING-CANON v1.25, retired the same day, LEDGER section 6.22).'
-- The second 2026-09-14 comment (migration eng208_promo_comment_named_limit_corrected), superseded at 18:44 by the
-- v1.26 rebuild, because the canon it stated was retired (ORDERING-CANON-LEDGER section 6.22):
-- 'GRADE: VERDICT. ENG-147 + ENG-082 + ENG-208. The one home for promo membership on a delivery date, read by
-- rpc_bloom_order_recipe and refresh_bloom_order_cache. RULE: a promo prices delivery D when D is on or after its
-- start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the
-- promo end date, or (b) on a DC route, D itself falls on or before the promo_order_close_dow of the
-- promo_order_week_start_dow week in which the promo ends. A line failing both is not promo_active and orders on
-- the normal TLX at normal quantity. EVIDENCE: RULING, Pieter 2026-09-10 (the closing Thursday) and 2026-09-14 (it
-- binds the DELIVERY date, not the placement day), ORDERING-CANON section C4. CONFIDENCE: a ruling from the floor,
-- no base rate measured. FALSIFIER: a DC delivery after its closing Thursday that the DC fills at promo cost.
-- NAMED LIMIT: a delivery bound and a strict placement bound (placement before the closing Thursday) give the same
-- verdict wherever no route places before a closing Thursday for a delivery after it. On 2026-09-14 the five DC
-- desks that deliver after a Thursday all place on that Thursday, the three Saturday desks 2 days out and the two
-- TOPS Monday desks 4 days out (rpc_derive_placement_day), so today's estate cannot tell the two apart. They
-- diverge on a Friday-delivering route or on any earlier placement for a post-Thursday delivery, and store #6
-- inherits the delivery reading. This function no longer reads rpc_derive_placement_day. Supersedes the 2026-09-10
-- comment, which bound the placement day, and the first 2026-09-14 comment, which gave the limit's reason as a
-- 2-day cutoff on all five routes.'
-- The first 2026-09-14 comment (migration eng208_promo_close_binds_delivery_date), superseded at 18:0x by the
-- second, because it gave the named limit's reason as a 2-day cutoff on all five routes. Its text is in that
-- migration.
-- The 2026-09-10 comment (migration eng082_promo_placement_day), superseded 2026-09-14 by ENG-208:
-- 'ENG-147 + ENG-082. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and
-- refresh_bloom_order_cache. A promo prices delivery D when D is on or after its start less promo_buyin_lead_days
-- and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC
-- route, the placement day for D falls on or before the promo_order_close_dow of the week the promo ends (Pieter
-- ruling 2026-09-10). The placement day is the last day on or before D less order_cutoff_days whose weekday
-- carried at least in_transit_min_received_orders DC orders in the dow_regime_lookback_days window before D
-- (ORDERING-CANON A5, derived from sigma_orders). Supersedes the 2026-08-27 comment, which stated the end-date
-- bound only and named three inline sites that no longer exist.'
--
-- The 2026-09-10 comment superseded this one on 2026-09-10
-- (migration eng082_promo_placement_day). Kept as written, never deleted:
-- 'ENG-147. The one home for promo membership on a delivery date. Rule lifted verbatim
-- from rpc_bloom_order_recipe promo_match. The recipe, rpc_bloom_order_dc and l2_stock_band
-- still carry the rule inline as three further sites: repoint them in the bundled recipe
-- opening, do not edit the pinned body for this alone. ORDERING-CANON SSC4 (placement-side
-- buy-in window).'

-- Grants stated explicitly (R30 addendum extension: PUBLIC and anon BOTH
-- revoked, because a role-specific grant survives a REVOKE FROM PUBLIC).
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) TO service_role;
