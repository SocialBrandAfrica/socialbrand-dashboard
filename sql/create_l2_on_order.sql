-- =====================================================================================
-- l2_on_order + refresh_l2_on_order  --  IN-TRANSIT STOCK (the pantry fact)
-- SB-CC-BLOOM-017 Wave 1 item 1.3 Â· CC Â· 2026-07-27
--
-- CANON: CLEANUP-ENGINE-CANON s14 ADDENDUM v14 rule 3 --
--   "Expectation is proven by the route's demonstrated fulfilment, never by a document."
--   CONTROLLED, n = 5,755 orders placed / 1,863 received, 5 stores, 7 months.
-- BRIEF: Bloom/PM-BRIEF-SB-CC-BLOOM-017-ordering-rebuild.md ADDENDUM v1.3 CORRECTION 2.
-- R28: effective_from 2026-07-27. Formula GENERAL, constants DEMO_CALIBRATION.
--
-- THE RETIRED SEED. The brief's original `outstanding_order_window_days = 30` is WITHDRAWN
-- (retired_on 2026-07-26, superseded_by ADDENDUM v1.3). It was NEVER CREATED as a config
-- row, so there is nothing to retire in forge_config and no lineage row is manufactured
-- for a key that never existed. Measured 2026-07-27: the 30-day seed would have booked
-- R11,113,791.84 of "in transit" against R886,144.56 under the route-derived window --
-- R10.23M of phantom stock, in the worst direction, because phantom in-transit SUPPRESSES
-- an order on a line that is genuinely empty.
--
-- THREE TRAPS THIS FILE ENCODES (each measured, not assumed):
--  1. UNITS. `ordered_qty` is SINGLES, the same basis as the R/W movement qty and as SOH.
--     Proven: 8,723 of 13,430 matched receipt lines equal it exactly, and the multipack
--     ratio is 1.0298 where mean pack_size is 18.38. NO pack bridge on the quantity leg.
--  2. COST. `cost` is the CASE cost. `ordered_qty * cost` runs 11.94x the invoiced total
--     (canon s12e point 4's trap, which inflated July 15.7x). The line value is
--     `ordered_qty * cost / pack_size`, which lands at 0.942 of invoiced -- residual is
--     ordered-vs-invoiced difference, not a basis error.
--  3. SENTINELS (canon s12e 5b). `grv_nr = 0` IS the no-GRV marker and is NULL on ZERO
--     rows, so `IS NOT NULL` reports zero no-GRV cases and hides the whole population.
--     `order_date = 1990-01-01` is a sentinel on 41,927 of 55,002 rows.
--
-- NAMED INERT GUARD. `status_1 <> '7'` is the credit/void class (ENG-042). All 31 real-dated
-- status-7 rows carry a GRV, so this test CANNOT remove an open order. It is kept as a
-- defensive guard and is named inert rather than claimed as working (R28 s5: a gate that
-- cannot fail is not proof).
--
-- NAMED GAP. DIRECT_BEER (SAB) cannot derive a lead here: its `order_date` is the sentinel
-- on essentially every row (21355/555 = 1 real of 58; 80176/590 = 3 of 148). A lead from
-- n=1 is a swallow (R28 s5) and canon 7b forbids seeding a desk at a known-wrong number.
-- SAB therefore carries no in-transit and no derived cutoff. Named, not faked.
-- =====================================================================================

CREATE TABLE IF NOT EXISTS public.l2_on_order (
  client_id              text        NOT NULL DEFAULT 'socialbrand',
  store_code             text        NOT NULL,
  product_code           bigint      NOT NULL,
  -- the in-transit term that enters projected_soh (SINGLES, same basis as SOH)
  on_order_qty           numeric(14,4) NOT NULL DEFAULT 0,
  on_order_cost          numeric(14,4) NOT NULL DEFAULT 0,
  open_order_count       integer     NOT NULL DEFAULT 0,
  earliest_order_date    date,
  expected_landing_date  date,
  route_keys             text[],
  lead_days_used         integer,
  lead_basis             text,       -- route_demonstrated | store_median_fallback | config_default
  -- the stale-document leg: EXCLUDED from on_order_qty, carried for the worklist (R29)
  stale_qty              numeric(14,4) NOT NULL DEFAULT 0,
  stale_cost             numeric(14,4) NOT NULL DEFAULT 0,
  stale_order_count      integer     NOT NULL DEFAULT 0,
  stale_oldest_age_days  integer,
  stale_route_keys       text[],
  engine_version         text        NOT NULL DEFAULT 'l2_on_order v1.0',
  computed_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT l2_on_order_pkey PRIMARY KEY (client_id, store_code, product_code)
);

-- Consumers join on (store_code, product_code) WITHOUT client_id. A PK leading with
-- client_id cannot serve them and degrades to a scan -- the standing trap named in
-- CLEANUP-ENGINE-CANON s17 for l2_stock_position / l2_rate_of_sale.
CREATE INDEX IF NOT EXISTS l2_on_order_store_product_idx
  ON public.l2_on_order (store_code, product_code);
CREATE INDEX IF NOT EXISTS l2_on_order_stale_idx
  ON public.l2_on_order (store_code) WHERE stale_order_count > 0;

ALTER TABLE public.l2_on_order ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_on_order_read ON public.l2_on_order;
CREATE POLICY l2_on_order_read ON public.l2_on_order FOR SELECT USING (true);
GRANT SELECT ON public.l2_on_order TO anon, authenticated;

COMMENT ON TABLE public.l2_on_order IS
'In-transit stock per (store_code, product_code). SB-CC-BLOOM-017 Wave 1 item 1.3, R28 effective 2026-07-27.
An order is IN TRANSIT only inside its own ROUTE''s demonstrated placement->GRV lead x in_transit_lead_multiple.
Beyond that it is a stale document: EXCLUDED from on_order_qty and carried on the stale_* leg for the worklist.
Canon s14 ADDENDUM v14 rule 3. The withdrawn outstanding_order_window_days=30 seed is NOT used and was never created.
UNITS: on_order_qty is SINGLES (sigma_order_lines.ordered_qty, proven equal to the R/W movement qty).
COST uses the pack bridge ordered_qty*cost/pack_size -- cost is the CASE cost (canon s12e point 4, the 11.94x trap).';

-- Config (DEMO_CALIBRATION, R25: config keys, never literals)
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('in_transit_lead_multiple',        '*', 2,   'DEMO_CALIBRATION', DATE '2026-07-27',
  'Multiple of the route demonstrated median placement->GRV lead beyond which an open order is a stale document, not in transit. Canon s14 v14 rule 3.'),
 ('in_transit_lead_window_days',     '*', 182, 'DEMO_CALIBRATION', DATE '2026-07-27',
  'History window for deriving each route demonstrated lead. Matches cadence_window_days (canon 7d: a window long enough to observe).'),
 ('in_transit_min_received_orders',  '*', 5,   'DEMO_CALIBRATION', DATE '2026-07-27',
  'Minimum received orders before a route own lead is trusted. Below it the store median is used. Prevents a lead derived from n=1 (R28 s5, a swallow).'),
 ('in_transit_lead_fallback_days',   '*', 7,   'DEMO_CALIBRATION', DATE '2026-07-27',
  'Last-resort belt when neither the route nor the store has enough received orders. Named, never silent.')
ON CONFLICT (config_key, store_format) DO NOTHING;

-- =====================================================================================

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
  ranked AS (   -- rule 2 partition, rule 4 recency, ranked over ALL types so rule 1 holds in both branches
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.store_code, r.supplier_nr, r.status_2
                                   ORDER BY r.order_nr DESC) AS rn FROM route_of r
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
    SELECT k.*, (k.rn=1) AS is_latest_of_kind, (CURRENT_DATE - k.order_date) AS age_days,
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
        WHEN NOT p.is_latest_of_kind                THEN 'cancelled_superseded'            -- rule 1
        WHEN p.expected_grv_date < p.order_date     THEN 'promise_before_own_order_date'   -- rule 5a pathology
        WHEN p.expected_grv_date <= v_watermark     THEN 'promise_passed_ledger_observed'  -- rule 5a boundary
        WHEN p.age_days > p.lead_days * v_mult      THEN 'stale_beyond_lead'               -- v14 rule 3 multiple
        ELSE NULL END AS exclusion_reason
    FROM open_pool p
  ),
  lines AS (
    SELECT j.route_key, j.order_date, j.age_days, j.lead_days, j.lead_basis, j.promise_basis,
           j.landing_estimate_state, j.exclusion_reason, l.product_code,
           SUM(l.ordered_qty) AS qty,
           SUM(l.ordered_qty * l.cost / NULLIF(l.pack_size,0)) AS cost
    FROM judged j JOIN sigma_order_lines l ON l.store_code=p_store AND l.order_nr=j.order_nr
    WHERE l.ordered_qty > 0 GROUP BY 1,2,3,4,5,6,7,8,9
  )
  INSERT INTO l2_on_order (
    client_id, store_code, product_code, on_order_qty, on_order_cost, open_order_count,
    earliest_order_date, expected_landing_date, route_keys, lead_days_used, lead_basis, promise_basis,
    landing_estimate_state, stale_qty, stale_cost, stale_order_count, stale_oldest_age_days,
    stale_route_keys, excluded_reasons, engine_version)
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
         'l2_on_order v15 rules1-5a'
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
    'engine_version', 'l2_on_order v15 rules1-5a', 'computed_at', now());
END;
$function$;

-- R30 addendum extension: the trap has fired 3x (SEC-002 / BLOOM-004 / ENG-031). All three legs.
-- Verified live 2026-07-27: anon EXECUTE = false, public EXECUTE = false, authenticated = true.
REVOKE EXECUTE ON FUNCTION public.refresh_l2_on_order(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_on_order(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_on_order(text) TO authenticated;

-- Wired into refresh_l2_pipeline immediately after the SB-CC-DEBT-001 creditor block and
-- BEFORE every consumer -- see sql/create_refresh_l2_pipeline.sql.
