-- refresh_l2_on_order_794ec5d2_pre_eng188.sql
--
-- ROLLBACK SOURCE. Lives in sql/_archive/, so nothing runs it on deploy. The live body of
-- public.refresh_l2_on_order immediately before ENG-188 applied on 2026-09-15, read with
-- pg_get_functiondef at 12:3x SAST the same day and md5-proven: 794ec5d27655445cd492abf9535ec2b8
-- / 9,177. To roll ENG-188 back: run this file, then refresh_l2_on_order for each store, then
-- rebuild the DC order caches. sql/create_refresh_l2_on_order.sql at d2d7307 is NOT this body:
-- it had drifted from live (body md5 f18ed7c194db06fea175da266d9651be).
--
CREATE OR REPLACE FUNCTION public.refresh_l2_on_order(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mult numeric; v_window integer; v_min_n integer; v_fallback integer;
  v_rows integer; v_recv_in_open integer; v_qty numeric; v_cost numeric;
  v_exc_n integer; v_exc_cost numeric; v_watermark date; v_est_past integer;
BEGIN
  SELECT value_num INTO v_mult     FROM forge_config WHERE config_key='in_transit_lead_multiple'       AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_window   FROM forge_config WHERE config_key='in_transit_lead_window_days'    AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_min_n    FROM forge_config WHERE config_key='in_transit_min_received_orders' AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_fallback FROM forge_config WHERE config_key='in_transit_lead_fallback_days'  AND store_format='*' AND retired_on IS NULL;
  IF v_mult IS NULL OR v_window IS NULL OR v_min_n IS NULL OR v_fallback IS NULL THEN
    RAISE EXCEPTION 'refresh_l2_on_order: config missing'; END IF;

  -- RULE 5a: the ledger says whether the truck came (s6, 7f). No calendar anywhere in the passed test.
  SELECT max(movement_date) INTO v_watermark FROM sigma_movements WHERE store_code = p_store;
  IF v_watermark IS NULL THEN
    RAISE EXCEPTION 'refresh_l2_on_order(%): no ledger watermark, refusing to judge a promise on a calendar', p_store;
  END IF;

  SELECT count(*) INTO v_recv_in_open
  FROM sigma_orders WHERE store_code=p_store AND order_type IN ('0','1','2') AND grv_nr <> 0;
  IF v_recv_in_open > 0 THEN
    RAISE WARNING 'refresh_l2_on_order(%): % received order(s) inside the 0/1/2 filter, rule 3 assumption moved', p_store, v_recv_in_open;
  END IF;

  DELETE FROM l2_on_order WHERE store_code = p_store;

  WITH route_of AS (
    SELECT o.*, COALESCE(
             (SELECT rc.route_key FROM bloom_route_config rc
               WHERE rc.store_code=o.store_code AND o.supplier_nr = ANY(rc.direct_supplier_nrs) LIMIT 1),
             CASE WHEN sc.supplier_class='DC' THEN 'DC' ELSE 'OTHER_'||COALESCE(sc.supplier_class,'UNKNOWN') END) AS route_key
    FROM sigma_orders o
    LEFT JOIN v_supplier_class sc ON sc.store_code=o.store_code AND sc.supplier_nr=o.supplier_nr
    WHERE o.store_code = p_store
  ),
  line_pop AS (
    SELECT l.order_nr, l.product_code, l.ordered_qty, l.cost, l.pack_size,
           CASE WHEN a.department_nr IS NULL THEN 'UNKNOWN'
                WHEN a.department_nr = ANY(cfg.dc_cycle_dept_nrs) THEN 'DC_AMBIENT'
                ELSE 'DC_OTHER' END AS delivery_population
    FROM sigma_order_lines l
    LEFT JOIN sigma_articles a  ON a.store_code=l.store_code AND a.product_code=l.product_code
    LEFT JOIN bloom_dc_config cfg ON cfg.store_code=l.store_code
    WHERE l.store_code=p_store AND l.ordered_qty > 0
  ),
  order_pop AS (SELECT DISTINCT order_nr, delivery_population FROM line_pop),
  ranked AS (   -- rule 2 partition, rule 4 recency, ranked over ALL types so rule 1 holds in both branches
    SELECT r.*, DENSE_RANK() OVER (PARTITION BY r.store_code, r.supplier_nr, op.delivery_population
                                   ORDER BY r.order_date DESC) AS rn, op.delivery_population FROM route_of r JOIN order_pop op ON op.order_nr = r.order_nr
  ),
  lead_route AS (
    SELECT route_key, percentile_disc(0.5) WITHIN GROUP (ORDER BY (grv_date-order_date))::int AS med_lead, count(*) AS n
    FROM route_of
    WHERE order_date IS NOT NULL AND order_date <> DATE '1990-01-01'
      AND grv_nr <> 0 AND grv_date IS NOT NULL AND grv_date <> DATE '1990-01-01'
      AND grv_date >= order_date AND order_date >= CURRENT_DATE - v_window
    GROUP BY 1
  ),
  lead_store AS (SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY med_lead)::int AS fb FROM lead_route WHERE n >= v_min_n),
  open_pool AS (   -- rule 3: order_type 0/1/2, never a date test
    SELECT k.*, (k.rn <= CASE WHEN k.route_key = 'DC' AND k.delivery_population = 'DC_AMBIENT' THEN 2 ELSE 1 END) AS is_latest_of_kind, (CURRENT_DATE - k.order_date) AS age_days,
           COALESCE(CASE WHEN lr.n >= v_min_n THEN lr.med_lead END, ls.fb, v_fallback) AS lead_days,
           CASE WHEN lr.n >= v_min_n THEN 'route_demonstrated'
                WHEN ls.fb IS NOT NULL THEN 'store_median_fallback' ELSE 'config_default' END AS lead_basis
    FROM ranked k LEFT JOIN lead_route lr ON lr.route_key=k.route_key CROSS JOIN lead_store ls
    WHERE k.order_type IN ('0','1','2')
  ),
  judged AS (
    SELECT p.*,
      -- rule 5a: promise judged against the ledger watermark. Informative, never constant.
      CASE WHEN p.expected_grv_date <  p.order_date  THEN 'promise_before_own_order_date'
           WHEN p.expected_grv_date <  v_watermark   THEN 'promise_passed_ledger_observed'
           WHEN p.expected_grv_date =  v_watermark   THEN 'promise_due_on_watermark_not_received'
           ELSE 'promise_ahead_of_ledger' END AS promise_basis,
      -- rule 5a: the ESTIMATE is a label, never a gate. Surfaced on counted rows.
      CASE WHEN (p.order_date + p.lead_days) <  v_watermark THEN 'estimate_elapsed'
           WHEN (p.order_date + p.lead_days) =  v_watermark THEN 'estimate_due_now'
           ELSE 'estimate_ahead' END AS landing_estimate_state,
      CASE
        WHEN NOT p.is_latest_of_kind THEN 'superseded_older_delivery'
        WHEN p.expected_grv_date IS NULL OR p.expected_grv_date = DATE '1990-01-01'
             OR p.expected_grv_date < p.order_date
          THEN CASE WHEN p.age_days > p.lead_days * v_mult THEN 'stale_beyond_lead' ELSE NULL END
        WHEN p.expected_grv_date <= v_watermark THEN 'promise_passed_ledger_observed'
        ELSE NULL END AS exclusion_reason
    FROM open_pool p
  ),
  lines AS (
    SELECT j.route_key, j.delivery_population, j.order_date, j.age_days, j.lead_days, j.lead_basis, j.promise_basis,
           j.landing_estimate_state, j.exclusion_reason, l.product_code,
           SUM(l.ordered_qty) AS qty,
           SUM(l.ordered_qty * l.cost / NULLIF(l.pack_size,0)) AS cost
    FROM judged j JOIN line_pop l ON l.order_nr=j.order_nr AND l.delivery_population=j.delivery_population
    WHERE l.ordered_qty > 0 GROUP BY 1,2,3,4,5,6,7,8,9,10
  )
  INSERT INTO l2_on_order (
    client_id, store_code, product_code, on_order_qty, on_order_cost, open_order_count,
    earliest_order_date, expected_landing_date, route_keys, lead_days_used, lead_basis, promise_basis,
    landing_estimate_state, stale_qty, stale_cost, stale_order_count, stale_oldest_age_days,
    stale_route_keys, excluded_reasons, engine_version, delivery_populations)
  SELECT 'socialbrand', p_store, product_code,
         COALESCE(SUM(qty)  FILTER (WHERE exclusion_reason IS NULL),0),
         COALESCE(SUM(cost) FILTER (WHERE exclusion_reason IS NULL),0),
         COALESCE(count(*)  FILTER (WHERE exclusion_reason IS NULL),0),
         MIN(order_date)             FILTER (WHERE exclusion_reason IS NULL),
         MIN(order_date + lead_days) FILTER (WHERE exclusion_reason IS NULL),
         ARRAY(SELECT DISTINCT unnest(array_agg(route_key) FILTER (WHERE exclusion_reason IS NULL))),
         MAX(lead_days)  FILTER (WHERE exclusion_reason IS NULL),
         MAX(lead_basis) FILTER (WHERE exclusion_reason IS NULL),
         (array_agg(DISTINCT promise_basis)           FILTER (WHERE exclusion_reason IS NULL))[1],
         (array_agg(DISTINCT landing_estimate_state)  FILTER (WHERE exclusion_reason IS NULL))[1],
         COALESCE(SUM(qty)  FILTER (WHERE exclusion_reason IS NOT NULL),0),
         COALESCE(SUM(cost) FILTER (WHERE exclusion_reason IS NOT NULL),0),
         COALESCE(count(*)  FILTER (WHERE exclusion_reason IS NOT NULL),0),
         MAX(age_days)      FILTER (WHERE exclusion_reason IS NOT NULL),
         ARRAY(SELECT DISTINCT unnest(array_agg(route_key)        FILTER (WHERE exclusion_reason IS NOT NULL))),
         ARRAY(SELECT DISTINCT unnest(array_agg(exclusion_reason) FILTER (WHERE exclusion_reason IS NOT NULL))),
         'l2_on_order v16 E2.1 population-partition'
,
         ARRAY(SELECT DISTINCT unnest(array_agg(delivery_population) FILTER (WHERE exclusion_reason IS NULL)))
  FROM lines GROUP BY product_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT COALESCE(SUM(on_order_qty),0), COALESCE(SUM(on_order_cost),0),
         COALESCE(SUM(stale_order_count),0), COALESCE(SUM(stale_cost),0)
    INTO v_qty, v_cost, v_exc_n, v_exc_cost FROM l2_on_order WHERE store_code=p_store;
  SELECT count(*) INTO v_est_past FROM l2_on_order
   WHERE store_code=p_store AND on_order_qty>0 AND landing_estimate_state <> 'estimate_ahead';

  RETURN jsonb_build_object(
    'store_code', p_store, 'rows', v_rows, 'ledger_watermark', v_watermark,
    'received_orders_inside_open_filter', v_recv_in_open,
    'on_order_qty', round(v_qty,2), 'on_order_cost', round(v_cost,2),
    'counted_rows_past_landing_estimate', v_est_past,   -- surfaced diagnostic, NOT an exclusion
    'excluded_order_lines', v_exc_n, 'excluded_cost_refused', round(v_exc_cost,2),
    'engine_version', 'l2_on_order v16 E2.1 population-partition', 'computed_at', now());
END;
$function$;
