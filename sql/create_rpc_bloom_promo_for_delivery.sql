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
           COALESCE((
             SELECT max(g.d)::date
             FROM generate_series(p_delivery_date - sc.order_cutoff_days::int - 6, p_delivery_date - sc.order_cutoff_days::int, interval '1 day') g(d)
             WHERE EXTRACT(ISODOW FROM g.d)::int IN (
               SELECT EXTRACT(ISODOW FROM o.order_date)::int
               FROM public.sigma_orders o
               JOIN public.v_supplier_class vc ON vc.store_code = o.store_code AND vc.supplier_nr = o.supplier_nr AND vc.supplier_class = 'DC'
               WHERE o.store_code = p_store_code
                 AND o.order_date <> DATE '1990-01-01'
                 AND o.order_date >= p_delivery_date - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'dow_regime_lookback_days' AND fc.store_format = '*' AND fc.retired_on IS NULL)
                 AND o.order_date < p_delivery_date
                 AND NOT EXISTS (SELECT 1 FROM public.bloom_route_config rd WHERE rd.store_code = o.store_code AND o.supplier_nr = ANY(rd.direct_supplier_nrs))
               GROUP BY 1
               HAVING count(*) >= (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'in_transit_min_received_orders' AND fc.store_format = '*' AND fc.retired_on IS NULL))
           ), p_delivery_date - sc.order_cutoff_days::int) AS placement_date
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
        AND cal.placement_date <= (
              pa.end_date
              - ((EXTRACT(ISODOW FROM pa.end_date)::int - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_week_start_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL) + 7) % 7)
              + (((SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_close_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL)
                  - (SELECT fc.value_num::int FROM public.forge_config fc WHERE fc.config_key = 'promo_order_week_start_dow' AND fc.store_format = '*' AND fc.retired_on IS NULL) + 7) % 7))))
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC
$function$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS $c$ENG-147 + ENG-082. The one home for promo membership on a delivery date, read by rpc_bloom_order_recipe and refresh_bloom_order_cache. A promo prices delivery D when D is on or after its start less promo_buyin_lead_days and either (a) D is on or before the route's last delivery day on or before the promo end date, or (b) on a DC route, the placement day for D falls on or before the promo_order_close_dow of the week the promo ends (Pieter ruling 2026-09-10). The placement day is the last day on or before D less order_cutoff_days whose weekday carried at least in_transit_min_received_orders DC orders in the dow_regime_lookback_days window before D (ORDERING-CANON A5, derived from sigma_orders). Supersedes the 2026-08-27 comment, which stated the end-date bound only and named three inline sites that no longer exist.$c$;

-- LINEAGE (R28): the COMMENT above superseded this one on 2026-09-10
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
