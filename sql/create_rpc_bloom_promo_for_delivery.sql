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
    SELECT sc.delivery_dows, sc.promo_buyin_lead_days
    FROM public.supplier_calendar sc
    WHERE sc.store_code = p_store_code
      AND sc.route_key  = p_route
    LIMIT 1
  ) cal
  WHERE pa.store_code = p_store_code
    AND p_delivery_date >= (pa.start_date - cal.promo_buyin_lead_days::int)
    AND p_delivery_date <= (
      SELECT MAX(gs)::date
      FROM generate_series(pa.end_date - 6, pa.end_date, interval '1 day') gs
      WHERE EXTRACT(ISODOW FROM gs)::smallint = ANY(cal.delivery_dows)
    )
  ORDER BY pa.product_code, (pa.status = '1') DESC, pa.end_date DESC
$function$;

COMMENT ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) IS
'ENG-147. The one home for promo membership on a delivery date. Rule lifted verbatim from rpc_bloom_order_recipe promo_match. The recipe, rpc_bloom_order_dc and l2_stock_band still carry the rule inline as three further sites: repoint them in the bundled recipe opening, do not edit the pinned body for this alone. ORDERING-CANON SSC4 (placement-side buy-in window).';

-- Grants stated explicitly (R30 addendum extension: PUBLIC and anon BOTH
-- revoked, because a role-specific grant survives a REVOKE FROM PUBLIC).
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_promo_for_delivery(text,text,date) TO service_role;
