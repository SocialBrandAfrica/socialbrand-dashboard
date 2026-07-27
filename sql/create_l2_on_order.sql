-- =====================================================================================
-- l2_on_order + refresh_l2_on_order  --  IN-TRANSIT STOCK (the pantry fact)
-- SB-CC-BLOOM-017 Wave 1 item 1.3 · CC · 2026-07-27
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
SET search_path = public
AS $fn$
DECLARE
  v_mult      numeric;
  v_window    integer;
  v_min_n     integer;
  v_fallback  integer;
  v_rows      integer;
  v_qty       numeric;
  v_cost      numeric;
  v_stale     integer;
  v_stalecost numeric;
BEGIN
  SELECT value_num INTO v_mult     FROM forge_config WHERE config_key='in_transit_lead_multiple'       AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_window   FROM forge_config WHERE config_key='in_transit_lead_window_days'    AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_min_n    FROM forge_config WHERE config_key='in_transit_min_received_orders' AND store_format='*' AND retired_on IS NULL;
  SELECT value_num INTO v_fallback FROM forge_config WHERE config_key='in_transit_lead_fallback_days'  AND store_format='*' AND retired_on IS NULL;

  IF v_mult IS NULL OR v_window IS NULL OR v_min_n IS NULL OR v_fallback IS NULL THEN
    RAISE EXCEPTION 'refresh_l2_on_order: config missing (mult=%, window=%, min_n=%, fallback=%)',
      v_mult, v_window, v_min_n, v_fallback;   -- no silent defaults (R25)
  END IF;

  DELETE FROM l2_on_order WHERE store_code = p_store;

  WITH route_of AS (
    -- route resolution: direct desk by its OWN supplier account, else supply class (never a name, R21/7d/7j)
    SELECT o.store_code, o.order_nr, o.order_date, o.grv_nr, o.grv_date, o.status_1,
           COALESCE(
             (SELECT rc.route_key FROM bloom_route_config rc
               WHERE rc.store_code = o.store_code AND o.supplier_nr = ANY(rc.direct_supplier_nrs) LIMIT 1),
             CASE WHEN sc.supplier_class = 'DC' THEN 'DC' ELSE 'OTHER_' || COALESCE(sc.supplier_class,'UNKNOWN') END
           ) AS route_key
    FROM sigma_orders o
    LEFT JOIN v_supplier_class sc ON sc.store_code = o.store_code AND sc.supplier_nr = o.supplier_nr
    WHERE o.store_code = p_store
  ),
  lead_route AS (   -- demonstrated placement->GRV lead, rpc_derive_supplier_cadence method (median)
    SELECT route_key,
           percentile_disc(0.5) WITHIN GROUP (ORDER BY (grv_date - order_date))::int AS med_lead,
           count(*) AS n
    FROM route_of
    WHERE order_date IS NOT NULL AND order_date <> DATE '1990-01-01'      -- sentinel law, s12e 5b
      AND grv_nr <> 0 AND grv_date IS NOT NULL AND grv_date <> DATE '1990-01-01'
      AND grv_date >= order_date
      AND order_date >= CURRENT_DATE - v_window
    GROUP BY 1
  ),
  lead_store AS (
    SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY med_lead)::int AS fb
    FROM lead_route WHERE n >= v_min_n
  ),
  open_orders AS (
    SELECT r.order_nr, r.order_date, r.route_key,
           (CURRENT_DATE - r.order_date) AS age_days,
           COALESCE(CASE WHEN lr.n >= v_min_n THEN lr.med_lead END, ls.fb, v_fallback) AS lead_days,
           CASE WHEN lr.n >= v_min_n THEN 'route_demonstrated'
                WHEN ls.fb IS NOT NULL THEN 'store_median_fallback'
                ELSE 'config_default' END AS lead_basis
    FROM route_of r
    LEFT JOIN lead_route lr ON lr.route_key = r.route_key
    CROSS JOIN lead_store ls
    WHERE r.order_date IS NOT NULL
      AND r.order_date <> DATE '1990-01-01'          -- sentinel-dated placements are not open orders
      AND r.grv_nr = 0                               -- THE open test: = 0, never IS NULL (s12e 5b)
      AND COALESCE(r.status_1,'') <> '7'             -- credit/void class. INERT: all 31 carry a GRV. Defensive only.
  ),
  judged AS (
    SELECT o.*, (o.age_days <= o.lead_days * v_mult) AS in_transit FROM open_orders o
  ),
  lines AS (
    SELECT j.route_key, j.order_date, j.age_days, j.lead_days, j.lead_basis, j.in_transit,
           l.product_code,
           SUM(l.ordered_qty)                                            AS qty,
           SUM(l.ordered_qty * l.cost / NULLIF(l.pack_size,0))           AS cost   -- pack bridge, s12e pt 4
    FROM judged j
    JOIN sigma_order_lines l ON l.store_code = p_store AND l.order_nr = j.order_nr
    WHERE l.ordered_qty > 0
    GROUP BY 1,2,3,4,5,6,7
  )
  INSERT INTO l2_on_order (
    client_id, store_code, product_code, on_order_qty, on_order_cost, open_order_count,
    earliest_order_date, expected_landing_date, route_keys, lead_days_used, lead_basis,
    stale_qty, stale_cost, stale_order_count, stale_oldest_age_days, stale_route_keys)
  SELECT 'socialbrand', p_store, product_code,
         COALESCE(SUM(qty)  FILTER (WHERE in_transit), 0),
         COALESCE(SUM(cost) FILTER (WHERE in_transit), 0),
         COALESCE(count(*)  FILTER (WHERE in_transit), 0),
         MIN(order_date) FILTER (WHERE in_transit),
         MIN(order_date + lead_days) FILTER (WHERE in_transit),
         ARRAY(SELECT DISTINCT unnest(array_agg(route_key) FILTER (WHERE in_transit))),
         MAX(lead_days)  FILTER (WHERE in_transit),
         MAX(lead_basis) FILTER (WHERE in_transit),
         COALESCE(SUM(qty)  FILTER (WHERE NOT in_transit), 0),
         COALESCE(SUM(cost) FILTER (WHERE NOT in_transit), 0),
         COALESCE(count(*)  FILTER (WHERE NOT in_transit), 0),
         MAX(age_days) FILTER (WHERE NOT in_transit),
         ARRAY(SELECT DISTINCT unnest(array_agg(route_key) FILTER (WHERE NOT in_transit)))
  FROM lines
  GROUP BY product_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  SELECT COALESCE(SUM(on_order_qty),0), COALESCE(SUM(on_order_cost),0),
         COALESCE(SUM(stale_order_count),0), COALESCE(SUM(stale_cost),0)
    INTO v_qty, v_cost, v_stale, v_stalecost
  FROM l2_on_order WHERE store_code = p_store;

  RETURN jsonb_build_object(
    'store_code', p_store, 'rows', v_rows,
    'on_order_qty', round(v_qty,2), 'on_order_cost', round(v_cost,2),
    'stale_order_lines', v_stale, 'stale_cost_refused', round(v_stalecost,2),
    'lead_multiple', v_mult, 'engine_version', 'l2_on_order v1.0',
    'computed_at', now());
END;
$fn$;

-- R30 addendum extension: the trap has fired 3x (SEC-002 / BLOOM-004 / ENG-031). All three legs.
-- Verified live 2026-07-27: anon EXECUTE = false, public EXECUTE = false, authenticated = true.
REVOKE EXECUTE ON FUNCTION public.refresh_l2_on_order(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_on_order(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_on_order(text) TO authenticated;

-- Wired into refresh_l2_pipeline immediately after the SB-CC-DEBT-001 creditor block and
-- BEFORE every consumer -- see sql/create_refresh_l2_pipeline.sql.
