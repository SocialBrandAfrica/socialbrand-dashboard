-- create_rpc_derive_placement_day.sql
--
-- GENERATED FROM LIVE 2026-09-11 by CC (ENG-082 H13/H14 stage 1, migration eng082_h13_h14_placement_one_home):
-- body = live 2a52347ec54f56a6e188694e9ad4035e / 4,367 chars, via the MCP result file as base64, hash-gated on disk.
--
-- WHAT IT IS. The one home of the placement weekday (ORDERING-CANON-REGISTERS H14, PM ruling 2026-09-10; scope
-- Pieter 2026-09-10: DC routes only). Read by rpc_bloom_promo_for_delivery (the promo test) and
-- rpc_bloom_next_deliveries (the desk's offered dates and its deadline). The cutoff fallback,
-- rpc_derive_order_cutoff, repoints in stage 2.
--
-- SECURITY DEFINER IS LOAD-BEARING: sigma_orders carries RLS and rpc_bloom_next_deliveries runs as its anon or
-- authenticated caller (the ENG-068 trap). EXECUTE to anon, authenticated and service_role, PUBLIC revoked.

CREATE OR REPLACE FUNCTION public.rpc_derive_placement_day(p_store_code text, p_route_key text, p_delivery_date date)
 RETURNS TABLE(placement_date date, is_dc boolean, admitted_dows smallint[], admitted_share numeric, placements integer, verify boolean, basis text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- ENG-082 H13/H14 (ORDERING-CANON-REGISTERS H14, PM ruling 2026-09-10; scope Pieter 2026-09-10: DC routes only).
  -- ONE placement derivation, read by the promo test (rpc_bloom_promo_for_delivery), the desk deadline
  -- (rpc_bloom_next_deliveries) and, in the next pass, the cutoff fallback (rpc_derive_order_cutoff).
  -- On a DC route a weekday is a placement day when it carries >= placement_dow_min_orders of the store's DC
  -- orders (sigma_orders headers, direct suppliers out, the 1990 sentinel out) in the dow_regime_lookback_days
  -- before the delivery. Delivery D places on the latest admitted weekday on or before D less order_cutoff_days.
  -- The admitted weekdays must hold >= dow_confidence_min percent of the placements, else VERIFY and the
  -- calendar-day answer (D less the cutoff) carries the flag. On a direct or dropship route no weekday binds
  -- and the placement is D less the cutoff (ENG-110 add.1). SECURITY DEFINER because sigma_orders carries RLS
  -- and rpc_bloom_next_deliveries runs as its anon or authenticated caller (the ENG-068 trap).
  WITH cal AS (
    SELECT sc.order_cutoff_days::int AS cut,
           NOT EXISTS (SELECT 1 FROM bloom_route_config rc WHERE rc.store_code = sc.store_code AND rc.route_key = sc.route_key) AS is_dc
      FROM supplier_calendar sc
     WHERE sc.store_code = p_store_code AND sc.route_key = p_route_key
     LIMIT 1),
  cfg AS (
    SELECT (SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'dow_regime_lookback_days' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS lb,
           (SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'placement_dow_min_orders' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS minr,
           (SELECT fc.value_num::numeric FROM forge_config fc WHERE fc.config_key = 'dow_confidence_min' AND fc.store_format = '*' AND fc.retired_on IS NULL) AS conf),
  wk AS (
    SELECT EXTRACT(ISODOW FROM o.order_date)::int AS dw, count(*)::int AS n
      FROM sigma_orders o
      JOIN v_supplier_class vc ON vc.store_code = o.store_code AND vc.supplier_nr = o.supplier_nr AND vc.supplier_class = 'DC'
     WHERE (SELECT cal.is_dc FROM cal)
       AND o.store_code = p_store_code
       AND o.order_date <> DATE '1990-01-01'
       AND o.order_date >= p_delivery_date - (SELECT cfg.lb FROM cfg)
       AND o.order_date < p_delivery_date
       AND NOT EXISTS (SELECT 1 FROM bloom_route_config dr WHERE dr.store_code = o.store_code AND o.supplier_nr = ANY(dr.direct_supplier_nrs))
     GROUP BY 1),
  adm AS (
    SELECT array_agg(wk.dw::smallint ORDER BY wk.dw) FILTER (WHERE wk.n >= (SELECT cfg.minr FROM cfg)) AS dows,
           COALESCE(sum(wk.n) FILTER (WHERE wk.n >= (SELECT cfg.minr FROM cfg)), 0)::int AS adm_n,
           COALESCE(sum(wk.n), 0)::int AS tot
      FROM wk),
  calc AS (
    SELECT cal.cut, cal.is_dc, adm.dows, adm.tot,
           ROUND(100.0 * adm.adm_n / NULLIF(adm.tot, 0), 1) AS share,
           (SELECT max(g.d)::date FROM generate_series(p_delivery_date - cal.cut - 6, p_delivery_date - cal.cut, interval '1 day') g(d)
             WHERE EXTRACT(ISODOW FROM g.d)::int = ANY(adm.dows)) AS derived
      FROM cal CROSS JOIN adm)
  SELECT CASE WHEN NOT calc.is_dc THEN p_delivery_date - calc.cut
              WHEN calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg) THEN calc.derived
              ELSE p_delivery_date - calc.cut END,
         calc.is_dc, calc.dows, calc.share, calc.tot,
         calc.is_dc AND NOT (calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg)),
         CASE WHEN NOT calc.is_dc THEN 'calendar days: direct or dropship route, no placement gate (ENG-110 add.1)'
              WHEN calc.derived IS NOT NULL AND calc.share >= (SELECT cfg.conf FROM cfg) THEN 'derived from the order ledger (ORDERING-CANON-REGISTERS H14)'
              ELSE 'VERIFY: no admitted placement weekday clears dow_confidence_min; the calendar-day answer is carried (H14 c)' END
    FROM calc
$function$;

REVOKE ALL ON FUNCTION public.rpc_derive_placement_day(text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_derive_placement_day(text, text, date) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.rpc_derive_placement_day(text, text, date) IS 'GRADE: VERDICT. The placement day of one delivery on one route. Rule: a weekday is admitted at placement_dow_min_orders DC orders in dow_regime_lookback_days. Confidence: the admitted weekdays hold dow_confidence_min percent of placements. Falsifier: the ledger itself, a DC order placed on a weekday outside the admitted set. ORDERING-CANON-REGISTERS H14, the one home read by rpc_bloom_promo_for_delivery and rpc_bloom_next_deliveries. On a direct or dropship route it returns the delivery less the cutoff, no placement gate. verify true means the admitted set is below the floor and the calendar-day answer is carried. ENG-082 H13/H14 stage 1, 2026-09-11.';
