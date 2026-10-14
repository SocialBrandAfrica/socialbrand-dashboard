-- Re-synced from the live definition 2026-10-14 (after bloom035_1b_dc_fresh_phase0, ENG-204). This function had no source file in the repo before.
-- The live definition is the source of record; change it by an asserted-replace migration and re-sync this file.

CREATE OR REPLACE FUNCTION public.rpc_bloom_delivery_budget(p_store_code text, p_route text, p_delivery_date date)
 RETURNS TABLE(budget_week_start date, week_needs_budget numeric, ledger_route text, deliveries_in_week date[], delivery_index integer, deliveries_total integer, landed_before_this_delivery numeric, in_transit_into_this_week numeric, already_consumed numeric, balance_for_this_delivery numeric, basis text, story text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ws        date;
  v_route     text;
  v_budget    numeric;
  v_manual    boolean;
  v_note      text;
  v_dows      smallint[];
  v_dates     date[];
  v_idx       int;
  v_landed    numeric;
  v_transit   numeric;
BEGIN
  -- The budget-week anchor is the SAME expression rpc_bloom_order_recipe and
  -- refresh_order_budget_ledger_needs use, so the three objects cannot disagree.
  v_ws := p_delivery_date - ((EXTRACT(ISODOW FROM p_delivery_date)::int + 1) % 7);

  v_route := CASE WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
                  WHEN p_route LIKE 'DC\_%' ESCAPE '\'  THEN 'DC'
                  WHEN p_route = 'DIRECT_BEER'          THEN 'DIRECT_BEER'
                  ELSE 'DIRECT' END;

  SELECT l.budget_amount, COALESCE(l.budget_manual_override,false), l.source_note
    INTO v_budget, v_manual, v_note
  FROM order_budget_ledger l
  WHERE l.store_code=p_store_code AND l.route_key=v_route
    AND l.grain='weekly' AND l.year_month=v_ws;

  -- The route's own delivery days, then the actual dated drops inside this budget week.
  SELECT sc.delivery_dows INTO v_dows
  FROM supplier_calendar sc
  WHERE sc.store_code=p_store_code AND sc.route_key=p_route;

  SELECT array_agg(d ORDER BY d) INTO v_dates
  FROM generate_series(v_ws, v_ws + 6, INTERVAL '1 day') g(d)
  WHERE EXTRACT(ISODOW FROM g.d)::smallint = ANY(COALESCE(v_dows, ARRAY[]::smallint[]));

  v_idx := COALESCE(array_position(v_dates, p_delivery_date), 0);

  -- What this week has ALREADY consumed, on the SAME pool the budget is projected over.
  -- Receipts strictly BEFORE this delivery date: a drop does not consume its own budget.
  SELECT COALESCE(SUM(m.cost_value),0) INTO v_landed
  FROM sigma_movements m
  JOIN sigma_supplier_master sm ON sm.store_code=m.store_code AND sm.supplier_nr=m.supplier_nr
  WHERE m.store_code=p_store_code AND m.movement_type IN ('R','W')
    AND m.movement_date >= v_ws AND m.movement_date < p_delivery_date
    AND ( (v_route='DC' AND sm.supplier_type='Z'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_ambient_pool p
                          WHERE p.store_code=m.store_code AND p.product_code=m.product_code))
       OR (v_route='DC_FRESH' AND sm.supplier_type='Z'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_fresh_pool p
                          WHERE p.store_code=m.store_code AND p.product_code=m.product_code))
       OR (v_route NOT IN ('DC','DC_FRESH') AND m.supplier_nr IN (
              SELECT unnest(rc.direct_supplier_nrs) FROM bloom_route_config rc
               WHERE rc.store_code=p_store_code
                 AND ( (v_route='DIRECT_BEER' AND rc.route_key='DIRECT_BEER')
                    OR (v_route='DIRECT'      AND rc.route_key LIKE 'DIRECT\_%' ESCAPE '\'
                                              AND rc.route_key <> 'DIRECT_BEER') ) )) );

  SELECT COALESCE(SUM(o.on_order_cost),0) INTO v_transit
  FROM l2_on_order o
  WHERE o.store_code=p_store_code AND o.on_order_qty>0
    AND o.expected_landing_date IS NOT NULL
    AND array_length(o.route_keys,1)=1
    AND (o.expected_landing_date - ((EXTRACT(ISODOW FROM o.expected_landing_date)::int + 1) % 7)) = v_ws
    AND o.expected_landing_date < p_delivery_date
    AND ( (v_route='DC' AND o.route_keys[1]='DC'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_ambient_pool p
                          WHERE p.store_code=o.store_code AND p.product_code=o.product_code))
       OR (v_route='DC_FRESH' AND o.route_keys[1]='DC'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_fresh_pool p
                          WHERE p.store_code=o.store_code AND p.product_code=o.product_code))
       OR (v_route='DIRECT_BEER' AND o.route_keys[1]='DIRECT_BEER')
       OR (v_route='DIRECT'      AND o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\'
                                 AND o.route_keys[1] <> 'DIRECT_BEER') );

  RETURN QUERY SELECT
    v_ws,
    ROUND(COALESCE(v_budget,0),2),
    v_route,
    COALESCE(v_dates, ARRAY[]::date[]),
    v_idx,
    COALESCE(array_length(v_dates,1),0),
    ROUND(v_landed,2),
    ROUND(v_transit,2),
    ROUND(v_landed + v_transit,2),
    ROUND(GREATEST(COALESCE(v_budget,0) - v_landed - v_transit, 0),2),
    CASE WHEN v_budget IS NULL      THEN 'no_ledger_row'
         WHEN v_manual              THEN 'manual_override'
         WHEN v_note LIKE 'NEEDS%'  THEN 'needs'
         ELSE 'seeded' END,
    -- R29: the reason travels with the number.
    CASE
      WHEN v_budget IS NULL THEN
        format('No budget row for %s %s week of %s -- the balance cannot be stated, and a blank is not a zero.',
               p_store_code, v_route, v_ws)
      WHEN v_idx = 0 THEN
        format('%s is not a scheduled %s delivery day in the week of %s (scheduled: %s). Showing the full week envelope of %s; treat it as an off-calendar drop.',
               p_delivery_date, p_route, v_ws,
               COALESCE(array_to_string(v_dates,', '),'none'), to_char(COALESCE(v_budget,0),'FM999G999G990D00'))
      WHEN v_idx = 1 THEN
        format('First of %s %s drop(s) this week. Nothing has landed since the week opened on %s, so the full week envelope of R%s is available for this delivery.',
               COALESCE(array_length(v_dates,1),0), p_route, v_ws, to_char(COALESCE(v_budget,0),'FM999G999G990D00'))
      ELSE
        format('Drop %s of %s this week. R%s has already been consumed since %s (R%s landed, R%s in transit), leaving R%s of the R%s week envelope for this delivery.',
               v_idx, COALESCE(array_length(v_dates,1),0),
               to_char(v_landed + v_transit,'FM999G999G990D00'), v_ws,
               to_char(v_landed,'FM999G999G990D00'), to_char(v_transit,'FM999G999G990D00'),
               to_char(GREATEST(COALESCE(v_budget,0) - v_landed - v_transit,0),'FM999G999G990D00'),
               to_char(COALESCE(v_budget,0),'FM999G999G990D00'))
    END;
END $function$;
