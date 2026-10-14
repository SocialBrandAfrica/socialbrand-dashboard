-- =============================================================================
-- create_refresh_order_budget_ledger_needs.sql
-- LEG D (Track A item 3, canon SS17 A3): "the current budget week exists in
-- order_budget_ledger, NEEDS refreshes it, and ENG-016's silent nearest-past-week
-- fallback becomes a surfaced warning."
-- Applied 2026-07-21, migrations legd_01..legd_04.
--
-- The weekly rail stopped being maintained after the WC-11-Jul hand seed, so every
-- auto-fitted DC and direct order fitted to a 3-week-stale number. Two defects sat
-- underneath that, both fixed in this pass:
--   1. `rpc_project_route_sales_budget` advanced its anchor to the NEXT Saturday, so
--      the current budget week was structurally unprojectable (see that file).
--   2. `order_budget_ledger`'s PRIMARY KEY ignored `grain` (see below).
--
-- ROUTE MAPPING (canon SS14 v7 item 7 / ENG-013): l2_sales_budget is keyed per DESK
-- (DC_AMBIENT / DC_TOPS / DIRECT_<brand> / DIRECT_BEER); order_budget_ledger is keyed
-- per LEDGER ROUTE, exactly as rpc_bloom_order_recipe's own v_ledger_route CASE
-- resolves it -- DC_* -> 'DC', DIRECT_BEER -> its own rail, every other DIRECT_* ->
-- the shared 'DIRECT' rail. Brand desks are SUMMED into DIRECT. One mapping, and it
-- is taken from the consumer rather than restated (R21).
--
-- MANUAL IS SOVEREIGN (canon v11 item 1): a row flagged `budget_manual_override` is
-- the CASHFLOW punch-in and NEEDS never overwrites it. Remove the punch-in and NEEDS
-- governs again on the next refresh. Monthly rows are never touched -- the SAB Jul-Dec
-- rail from SB-AP-REPAY-001 is a management plan at a different grain, not a projection.
--
-- ⚠️ THE CONVERSION FACTOR -- stated in one line and surfaced, never buried (R27 SS7).
-- Canon v11 item 3 reads needs = projected_sales x purchases_to_sales_ratio (0.82).
-- That 0.82 converts RETAIL sales to cost-of-purchases. `projected_sales_cost` is
-- ALREADY at cost, so applying 0.82 again double-discounts and under-funds the rail by
-- ~18%. Measured to source, trailing 91 days, all five stores:
--     purchases / sales-at-cost   0.984 (10116) 1.027 (80175) 0.954 (80176) 0.735 (21355) 0.581 (80579)
--     purchases / sales-ex-VAT    0.807        0.836        0.802        0.787        0.508
-- The 0.82 law reproduces exactly on the ex-VAT basis; on the cost basis the ratio is
-- ~1.0. Default is therefore 1.00, held in config (`purchases_to_sales_ratio_cost_basis`,
-- DEMO_CALIBRATION) -- one row to change if PM rules otherwise.
-- The per-store DEMONSTRATED ratio is computed and written into source_note but NOT
-- applied: 21355 at 0.735 and 80579 at 0.581 are stores that have been UNDER-buying
-- (80579 is IBT-fed and its SAB door has been shut since 2026-03-27), and applying a
-- demonstrated ratio there would bake a starved store's starvation into next week's
-- budget -- the same reason DF-2's stockout correction is reported and not applied
-- (canon SS14 v2 addendum). CC's reading, offered to PM as a CANDIDATE, not canon.
-- =============================================================================

-- REAL SCHEMA DEFECT CAUGHT BY THE BUILD, not designed for. order_budget_ledger carries
-- a `grain` column but its PRIMARY KEY was (store_code, route_key, year_month) and
-- IGNORED it -- so a WEEKLY row whose Saturday budget-week start lands on a month start
-- could never coexist with the MONTHLY row for the same store and route. Not
-- hypothetical: 2026-08-01 IS a Saturday, and the first NEEDS run at a TOPS store hit
-- `duplicate key (21355, DIRECT_BEER, 2026-08-01)` against the SAB monthly rail. Grain
-- is part of the row's identity. No FK references this table (verified via pg_constraint
-- before altering) and every reader already filters on grain, so this is additive.
ALTER TABLE public.order_budget_ledger DROP CONSTRAINT IF EXISTS order_budget_ledger_pkey;
ALTER TABLE public.order_budget_ledger
  ADD CONSTRAINT order_budget_ledger_pkey PRIMARY KEY (store_code, route_key, grain, year_month);

INSERT INTO forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES ('purchases_to_sales_ratio_cost_basis', '*', 1.00, 'DEMO_CALIBRATION', '2026-07-21',
        'Leg d. Multiplier from l2_sales_budget.projected_sales_cost (already at cost) to the weekly NEEDS rail. 1.00 = buy what you sell, at cost. Canon v11''s 0.82 is the RETAIL->cost conversion and must not be applied on top of a cost figure. Demonstrated per-store ratio is SURFACED in order_budget_ledger.source_note, never applied.')
ON CONFLICT (config_key, store_format) DO NOTHING;

-- Re-synced from the live definition 2026-10-14 (after bloom035_1b_dc_fresh_phase0, ENG-204).
CREATE OR REPLACE FUNCTION public.refresh_order_budget_ledger_needs(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ratio numeric;
  v_demo numeric;
  v_ins int; v_upd int; v_held int;
  v_cm_rows int; v_cm_total numeric; v_ld_total numeric;
  v_unrouted_landed numeric; v_unrouted_transit numeric; v_multi_route int;
  v_strip_dept numeric; v_strip_w1 numeric; v_strip_lines int;
  v_floor date;
BEGIN
  SELECT value_num INTO v_ratio FROM forge_config
   WHERE config_key='purchases_to_sales_ratio_cost_basis' AND store_format='*' AND retired_on IS NULL;
  v_ratio := COALESCE(v_ratio, 1.00);

  SELECT ROUND(
           (SELECT COALESCE(SUM(m.cost_value),0) FROM sigma_movements m
             WHERE m.store_code=p_store AND m.movement_type='R' AND m.movement_process='W'
               AND m.movement_date >= CURRENT_DATE - 91 AND m.movement_date < CURRENT_DATE)
         / NULLIF((SELECT SUM(s.cost_value) FROM sigma_sales s
                    WHERE s.store_code=p_store AND s.period_kind='T' AND s.txn_kind=1
                      AND s.sale_date >= CURRENT_DATE - 91 AND s.sale_date < CURRENT_DATE),0), 3)
    INTO v_demo;

  WITH needs AS (
    SELECT sb.store_code,
           CASE WHEN sb.route_key = 'DC_FRESH' THEN 'DC_FRESH'
                WHEN sb.route_key LIKE 'DC\_%' ESCAPE '\' THEN 'DC'
                WHEN sb.route_key = 'DIRECT_BEER'         THEN 'DIRECT_BEER'
                ELSE 'DIRECT' END AS ledger_route,
           sb.budget_week_start AS year_month,
           ROUND(SUM(sb.projected_sales_cost) * v_ratio, 2) AS needs_amount,
           string_agg(DISTINCT sb.route_key, '+' ORDER BY sb.route_key) AS desks
    FROM l2_sales_budget sb
    WHERE sb.store_code = p_store
    GROUP BY 1,2,3
  ),
  upd AS (
    UPDATE order_budget_ledger l
       SET budget_amount = n.needs_amount,
           source_note = format('NEEDS auto-refreshed %s from l2_sales_budget (%s) x ratio %s on the cost basis. Demonstrated purchases/sales-at-cost trailing 91d = %s (surfaced, NOT applied -- leg d).',
                                to_char(now(),'YYYY-MM-DD HH24:MI'), n.desks, v_ratio, COALESCE(v_demo::text,'n/a')),
           updated_at = now()
      FROM needs n
     WHERE l.store_code = n.store_code AND l.route_key = n.ledger_route
       AND l.grain = 'weekly' AND l.year_month = n.year_month
       AND COALESCE(l.budget_manual_override,false) = false
    RETURNING 1
  ),
  ins AS (
    INSERT INTO order_budget_ledger (store_code, route_key, grain, year_month, budget_amount, committed_amount, cash_constrained, source_note)
    SELECT n.store_code, n.ledger_route, 'weekly', n.year_month, n.needs_amount, 0, false,
           format('NEEDS auto-created %s from l2_sales_budget (%s) x ratio %s on the cost basis. Demonstrated purchases/sales-at-cost trailing 91d = %s (surfaced, NOT applied -- leg d).',
                  to_char(now(),'YYYY-MM-DD HH24:MI'), n.desks, v_ratio, COALESCE(v_demo::text,'n/a'))
    FROM needs n
    WHERE NOT EXISTS (
      SELECT 1 FROM order_budget_ledger l
       WHERE l.store_code=n.store_code AND l.route_key=n.ledger_route AND l.grain='weekly' AND l.year_month=n.year_month)
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM upd) INTO v_ins, v_upd;

  SELECT count(*) INTO v_held
  FROM order_budget_ledger l JOIN l2_sales_budget sb
    ON sb.store_code=l.store_code AND sb.budget_week_start=l.year_month
  WHERE l.store_code=p_store AND l.grain='weekly' AND COALESCE(l.budget_manual_override,false);

  -- ==================== ENG-061, THE MONEY BOOK -- SCOPED (SB-CC-DCBUDGET-001) ====================
  -- committed_amount = what this budget week has ALREADY consumed:
  --   (a) receipts that have LANDED inside the week   (sigma_movements R/W, cost ex-VAT)
  -- + (b) in-transit expected to LAND inside the week (l2_on_order, line basis)
  -- landed_amount = leg (a) alone. ONE landed computation lives here; refresh_order_budget_ledger()
  -- keeps sales_actual only (its landed leg is retired with lineage, R28 -- see COMMENT).
  -- THE DC ROUTE IS SCOPED TO THE SAME POOL AS ITS BUDGET: ambient departments
  -- (bloom_dc_config.dc_cycle_dept_nrs) x World-1 (l2_item_classification NORMAL). DC fresh,
  -- production, non-stock and unclassified receipts are EXCLUDED and SURFACED, never netted
  -- against a buy-and-sell budget that was never sized to include them.
  SELECT MIN(year_month) INTO v_floor FROM order_budget_ledger
   WHERE store_code=p_store AND grain='weekly';

  WITH beer AS (
    SELECT unnest(direct_supplier_nrs) AS supplier_nr FROM bloom_route_config
     WHERE store_code=p_store AND route_key='DIRECT_BEER'),
  direct AS (
    SELECT unnest(direct_supplier_nrs) AS supplier_nr FROM bloom_route_config
     WHERE store_code=p_store AND route_key LIKE 'DIRECT\_%' ESCAPE '\' AND route_key <> 'DIRECT_BEER'),
  -- ONE HOME (FILE-GOVERNANCE §0g write-forward): the pool definition lives in
  -- v_bloom_dc_ambient_pool and is read, never restated. A second copy would be drift.
  dcpool AS (
    SELECT p.product_code FROM v_bloom_dc_ambient_pool p WHERE p.store_code = p_store),
  fpool AS (
    SELECT p.product_code FROM v_bloom_dc_fresh_pool p WHERE p.store_code = p_store),
  landed AS (
    SELECT CASE
             WHEN m.supplier_nr IN (SELECT supplier_nr FROM beer)   THEN 'DIRECT_BEER'
             WHEN m.supplier_nr IN (SELECT supplier_nr FROM direct) THEN 'DIRECT'
             WHEN sm.supplier_type = 'Z'
              AND m.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'
             WHEN sm.supplier_type = 'Z'
              AND m.product_code IN (SELECT product_code FROM fpool) THEN 'DC_FRESH'
           END AS ledger_route,
           (m.movement_date - ((EXTRACT(ISODOW FROM m.movement_date)::int + 1) % 7)) AS week_start,
           SUM(m.cost_value) AS amt
    FROM sigma_movements m
    LEFT JOIN sigma_supplier_master sm
      ON sm.store_code=m.store_code AND sm.supplier_nr=m.supplier_nr
    WHERE m.store_code=p_store AND m.movement_type IN ('R','W')
      AND m.movement_date >= v_floor
    GROUP BY 1,2),
  transit AS (
    SELECT CASE
             WHEN o.route_keys[1] = 'DIRECT_BEER'             THEN 'DIRECT_BEER'
             WHEN o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'
             WHEN o.route_keys[1] = 'DC'
              AND o.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'
             WHEN o.route_keys[1] = 'DC'
              AND o.product_code IN (SELECT product_code FROM fpool) THEN 'DC_FRESH'
           END AS ledger_route,
           (o.expected_landing_date - ((EXTRACT(ISODOW FROM o.expected_landing_date)::int + 1) % 7)) AS week_start,
           SUM(o.on_order_cost) AS amt
    FROM l2_on_order o
    WHERE o.store_code=p_store AND o.on_order_qty > 0
      AND o.expected_landing_date IS NOT NULL
      AND array_length(o.route_keys,1) = 1
    GROUP BY 1,2),
  agg AS (
    SELECT COALESCE(l.ledger_route, t.ledger_route) AS ledger_route,
           COALESCE(l.week_start,   t.week_start)   AS week_start,
           COALESCE(l.amt,0) AS landed_amt,
           COALESCE(t.amt,0) AS transit_amt
    FROM      (SELECT * FROM landed  WHERE ledger_route IS NOT NULL) l
    FULL JOIN (SELECT * FROM transit WHERE ledger_route IS NOT NULL) t
           ON t.ledger_route = l.ledger_route AND t.week_start = l.week_start
  ),
  cm AS (
    UPDATE order_budget_ledger l
       SET committed_amount = ROUND(a.landed_amt + a.transit_amt, 2),
           landed_amount    = ROUND(a.landed_amt, 2),
           updated_at = now()
      FROM agg a
     WHERE l.store_code=p_store AND l.grain='weekly'
       AND l.route_key = a.ledger_route AND l.year_month = a.week_start
    RETURNING l.committed_amount, l.landed_amount
  )
  SELECT count(*), COALESCE(SUM(committed_amount),0), COALESCE(SUM(landed_amount),0)
    INTO v_cm_rows, v_cm_total, v_ld_total FROM cm;

  -- THE DC STRIP, surfaced with its two reasons (R29). These are type-Z receipts that are NOT
  -- part of the DC-ambient buy-and-sell stream and therefore never touch its budget.
  SELECT COALESCE(SUM(m.cost_value) FILTER (WHERE sp.product_code IS NULL
                                              OR NOT (sp.department_nr = ANY(dc.dc_cycle_dept_nrs) OR sp.department_nr = ANY(COALESCE(dc.dc_fresh_dept_nrs, ARRAY[]::smallint[])))),0),
         COALESCE(SUM(m.cost_value) FILTER (WHERE sp.department_nr = ANY(dc.dc_cycle_dept_nrs)
                                              AND sp.class <> 'NORMAL'),0),
         count(*) FILTER (WHERE sp.product_code IS NULL
                            OR NOT (sp.department_nr = ANY(dc.dc_cycle_dept_nrs) OR sp.department_nr = ANY(COALESCE(dc.dc_fresh_dept_nrs, ARRAY[]::smallint[])))
                            OR sp.class <> 'NORMAL')
    INTO v_strip_dept, v_strip_w1, v_strip_lines
  FROM sigma_movements m
  JOIN sigma_supplier_master sm ON sm.store_code=m.store_code AND sm.supplier_nr=m.supplier_nr
  JOIN bloom_dc_config dc       ON dc.store_code=m.store_code AND dc.status='RULED'
  LEFT JOIN l2_stock_position sp ON sp.store_code=m.store_code AND sp.product_code=m.product_code
  WHERE m.store_code=p_store AND m.movement_type IN ('R','W') AND sm.supplier_type='Z'
    AND m.movement_date >= v_floor;

  SELECT COALESCE(SUM(m.cost_value),0) INTO v_unrouted_landed
  FROM sigma_movements m
  LEFT JOIN sigma_supplier_master sm ON sm.store_code=m.store_code AND sm.supplier_nr=m.supplier_nr
  WHERE m.store_code=p_store AND m.movement_type IN ('R','W') AND m.movement_date >= v_floor
    AND COALESCE(sm.supplier_type,'') <> 'Z'
    AND NOT EXISTS (SELECT 1 FROM bloom_route_config rc
                     WHERE rc.store_code=p_store AND m.supplier_nr = ANY(rc.direct_supplier_nrs));

  SELECT COALESCE(SUM(o.on_order_cost),0), COUNT(*) FILTER (WHERE array_length(o.route_keys,1) > 1)
    INTO v_unrouted_transit, v_multi_route
  FROM l2_on_order o
  WHERE o.store_code=p_store AND o.on_order_qty > 0
    AND (array_length(o.route_keys,1) <> 1 OR o.route_keys[1] LIKE 'OTHER\_%' ESCAPE '\');

  IF v_ins + v_upd = 0 AND EXISTS (SELECT 1 FROM l2_sales_budget WHERE store_code=p_store) THEN
    RAISE EXCEPTION 'refresh_order_budget_ledger_needs(%): projection has rows but no ledger row was written or updated -- refusing a false green', p_store;
  END IF;

  RETURN jsonb_build_object('store_code', p_store, 'inserted', v_ins, 'updated', v_upd,
                            'held_manual', v_held, 'ratio_applied', v_ratio,
                            'ratio_demonstrated', v_demo,
                            'committed_rows_written', v_cm_rows,
                            'committed_total', ROUND(v_cm_total,2),
                            'landed_total', ROUND(v_ld_total,2),
                            'excluded_dc_non_ambient_dept_landed', ROUND(v_strip_dept,2),
                            'excluded_dc_ambient_non_w1_landed',   ROUND(v_strip_w1,2),
                            'excluded_dc_strip_lines',             v_strip_lines,
                            'excluded_unrouted_landed', ROUND(v_unrouted_landed,2),
                            'excluded_unrouted_transit', ROUND(v_unrouted_transit,2),
                            'excluded_multi_route_products', v_multi_route,
                            'refreshed_at', now());
END $function$;

REVOKE ALL ON FUNCTION public.refresh_order_budget_ledger_needs(text) FROM PUBLIC;
-- anon revoked BY NAME (RULE-BOOK v2.10 SS22 R30 addendum extension, canonised 2026-07-21):
-- a mutating function ships REVOKE FROM PUBLIC + REVOKE FROM anon + GRANT TO authenticated.
REVOKE EXECUTE ON FUNCTION public.refresh_order_budget_ledger_needs(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.refresh_order_budget_ledger_needs(text) TO authenticated;

-- Wired into refresh_l2_pipeline immediately after refresh_l2_sales_budget.
-- Live at build (2026-07-21): 10116 +52 rows, 80175 +52, 21355 +78, 80176 +52, 80579 +52;
-- 0 manual rows overwritten; every desk's recipe now reports budget_week_source =
-- 'delivery_week_exact' (was 'nearest_past_week_fallback' on every route).
