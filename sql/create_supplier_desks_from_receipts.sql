-- =============================================================================
-- DESKS FROM THE RECEIPTS -- SB-CC-BLOOM-035 item 1 (R7, Pieter 13-10-2026 15:05)
--   "all desks must be available for ordering if we received from a supplier in 6 months
--    it must be there. all products in their right suppliers as per grv evidence (latest)"
--
-- Three objects, all derived, none typed (R21, R25 section 6, ENG-203):
--   1. forge_config prod_input_min_recv_dates / prod_input_min_span_days  (SEED, UNDERIVED)
--      ORDERING-CANON-REGISTERS G2 names both and neither existed.
--   2. l2_world_assignment + refresh_l2_world_assignment(store)
--      The ENG-020 discriminator, once, for everyone (R32). A line bought repeatedly, never
--      sold at the till and with no selling family member reads as a World 2 input. World 2
--      suppliers do not go on a Bloom desk (Pieter 13-10 15:26): they get their own desk
--      (item 7). GRADE: VERDICT (rule, evidence, confidence, falsifier on every row).
--   3. refresh_supplier_desks(store)
--      Every supplier that delivered a non-World-2 product in the last desk_receipt_window_days
--      (182) and has no desk gets one: a bloom_route_config row (DIRECT_S<supplier_nr>, the key is
--      opaque, the label is the supplier's own name) and a supplier_calendar row seeded from
--      rpc_derive_supplier_cadence, or, where the ledger shows too few drops to derive a
--      cadence, from the weekdays the supplier actually delivered on, flagged VERIFY.
--      Never deletes a desk (R28). DC suppliers (type Z) already have their desk.
--
-- Pool membership needs no recipe change: a desk's pool is the active links of its supplier
-- (refresh_l2_population_verdict, rpc_bloom_order_recipe). Of the 3,336 products whose latest
-- GRV supplier had no desk on 13-10, 3,259 (97.7%) carry an active link to that supplier.
--
-- v1.0, APPLIED 13-10-2026 (migration supplier_desks_from_receipts_bloom035_item1). Run once, at 80579, it wrote a
-- 13-week and a 20-week cycle from two receipts each. One gap is not a cycle. Those two test desks were removed.
-- The fix, v1.1, is sql/pending_supplier_desks_min_cadence_gaps.sql, NOT APPLIED: waiting on Pieter's permission.
-- Do not run refresh_supplier_desks until v1.1 is live (BUG-LOG ENG-234).
--
-- Rollback: DROP FUNCTION refresh_supplier_desks(text), refresh_l2_world_assignment(text);
--   DROP TABLE l2_world_assignment; DELETE the desks this wrote (bloom_route_config /
--   supplier_calendar rows whose notes start 'DERIVED FROM RECEIPTS').
-- =============================================================================

-- 1. The two config keys the canon names ---------------------------------------------------------
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('prod_input_min_recv_dates', '*', 3, 'DEMO_CALIBRATION', DATE '2026-10-13',
  'SEED, UNDERIVED. ENG-020 repeat-receipts leg: distinct R/W receipt dates a never-sold line needs before it reads as a World 2 input. Named in ORDERING-CANON-REGISTERS G2, created 13-10-2026 (BLOOM-035 item 1). Derivation owed.'),
 ('prod_input_min_span_days', '*', 60, 'DEMO_CALIBRATION', DATE '2026-10-13',
  'SEED, UNDERIVED. ENG-020 repeat-receipts leg: days between the first and the last receipt. Named in ORDERING-CANON-REGISTERS G2, created 13-10-2026 (BLOOM-035 item 1). Derivation owed.')
ON CONFLICT (config_key, store_format) DO NOTHING;

-- 2. The ENG-020 discriminator ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.l2_world_assignment (
  client_id         text        NOT NULL DEFAULT 'socialbrand',
  store_code        text        NOT NULL,
  product_code      bigint      NOT NULL,
  world             text        NOT NULL CHECK (world IN ('WORLD_1', 'WORLD_2')),
  sub_class         text,
  recv_dates        integer     NOT NULL,
  recv_span_days    integer     NOT NULL,
  first_receipt_date date,
  last_receipt_date  date,
  till_sales_ever   boolean     NOT NULL,
  family_sells      boolean     NOT NULL,
  rule              text        NOT NULL,
  reason            text        NOT NULL,
  confidence        numeric(4,2),
  falsifier         text        NOT NULL,
  engine_version    text        NOT NULL,
  computed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, store_code, product_code)
);
CREATE INDEX IF NOT EXISTS idx_l2_world_assignment_store_product ON public.l2_world_assignment (store_code, product_code);
ALTER TABLE public.l2_world_assignment ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.l2_world_assignment FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.l2_world_assignment TO service_role;

COMMENT ON TABLE public.l2_world_assignment IS
'GRADE: VERDICT. ENG-020 PROD_INPUT discriminator, one row per product received at the store and never sold at the till (a product that sold is World 1 by definition and carries no row). WORLD_2 = at least prod_input_min_recv_dates distinct receipt dates over at least prod_input_min_span_days AND no till (K) sale in the ledger AND no selling family member (l2_family_ros). WORLD_1 rows are the not-yet-proven ones, with the leg that failed. Ledger horizon is 2025-02: "never sold" is never sold since then. Falsifier: any till sale of the product or of a family member moves it to World 1 on the next refresh. No client read, service_role only (R30: published readers come later).';

CREATE OR REPLACE FUNCTION public.refresh_l2_world_assignment(p_store_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_engine constant text := 'ENG-020 world assignment v1.0 (BLOOM-035 item 1)';
  v_min_dates int;
  v_min_span  int;
  v_w2 int; v_w1 int;
BEGIN
  IF p_store_code IS NULL THEN RAISE EXCEPTION 'p_store_code is required'; END IF;
  SELECT fc.value_num::int INTO v_min_dates FROM forge_config fc WHERE fc.config_key = 'prod_input_min_recv_dates' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  SELECT fc.value_num::int INTO v_min_span  FROM forge_config fc WHERE fc.config_key = 'prod_input_min_span_days'  AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_min_dates IS NULL OR v_min_span IS NULL THEN
    RAISE EXCEPTION 'forge_config prod_input_min_recv_dates / prod_input_min_span_days missing -- the ENG-020 legs cannot be read';
  END IF;

  DELETE FROM l2_world_assignment WHERE store_code = p_store_code;

  INSERT INTO l2_world_assignment
    (store_code, product_code, world, sub_class, recv_dates, recv_span_days, first_receipt_date, last_receipt_date,
     till_sales_ever, family_sells, rule, reason, confidence, falsifier, engine_version)
  WITH k AS (
    SELECT DISTINCT m.product_code FROM sigma_movements m
     WHERE m.store_code = p_store_code AND m.movement_type = 'K'
  ),
  rec AS (
    SELECT m.product_code, count(DISTINCT m.movement_date)::int AS recv_dates,
           (max(m.movement_date) - min(m.movement_date))::int AS span_days,
           min(m.movement_date) AS first_d, max(m.movement_date) AS last_d
      FROM sigma_movements m
     WHERE m.store_code = p_store_code AND m.movement_type IN ('R','W') AND m.qty > 0
     GROUP BY 1
  ),
  cand AS (SELECT r.* FROM rec r WHERE NOT EXISTS (SELECT 1 FROM k WHERE k.product_code = r.product_code)),
  fam AS (
    SELECT DISTINCT f1.product_code
      FROM l2_family_ros f1
      JOIN l2_family_ros f2 ON f2.store_code = f1.store_code AND f2.family_key = f1.family_key AND f2.product_code <> f1.product_code
      JOIN k ON k.product_code = f2.product_code
     WHERE f1.store_code = p_store_code
  )
  SELECT p_store_code, c.product_code,
         CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL THEN 'WORLD_2' ELSE 'WORLD_1' END,
         CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL THEN 'PROD_INPUT' END,
         c.recv_dates, c.span_days, c.first_d, c.last_d,
         false, (f.product_code IS NOT NULL),
         format('ENG-020: received on at least %s distinct dates over at least %s days, never sold at the till, no selling family member.', v_min_dates, v_min_span),
         CASE WHEN f.product_code IS NOT NULL THEN
                'World 1, not a World 2 input: a family member sells at the till, so this code is part of a buy-and-sell family.'
              WHEN c.recv_dates < v_min_dates OR c.span_days < v_min_span THEN
                format('World 1, not yet proven a World 2 input: %s receipt date(s) over %s day(s), the rule needs %s over %s. Never sold at the till.', c.recv_dates, c.span_days, v_min_dates, v_min_span)
              ELSE
                format('World 2 input: %s receipt dates over %s days (%s to %s), never sold at the till, no selling family member. A real EAN proves bought, not sold.', c.recv_dates, c.span_days, c.first_d, c.last_d) END,
         CASE WHEN c.recv_dates >= v_min_dates AND c.span_days >= v_min_span AND f.product_code IS NULL
              THEN LEAST(1.00, round(c.recv_dates::numeric / (2 * v_min_dates), 2)) END,
         'Any till (K) sale of this product or of a family member in the ledger moves it to World 1 at the next refresh. The ledger starts 2025-02, so "never sold" means since then.',
         v_engine
    FROM cand c LEFT JOIN fam f ON f.product_code = c.product_code;

  SELECT count(*) FILTER (WHERE world = 'WORLD_2'), count(*) FILTER (WHERE world = 'WORLD_1')
    INTO v_w2, v_w1 FROM l2_world_assignment WHERE store_code = p_store_code;
  RETURN jsonb_build_object('store_code', p_store_code, 'world_2', v_w2, 'world_1_unproven', v_w1, 'engine', v_engine);
END
$fn$;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_world_assignment(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_world_assignment(text) TO authenticated, service_role;

-- 3. Desks from the receipts ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_supplier_desks(p_store_code text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_store     text;
  v_wm        date;
  v_win       int;
  r           record;
  v_key       text;
  v_created   int;
  v_derived   int;
  v_fallback  int;
  v_rank      int;
  v_dows      int[];
  v_note      text;
  v_out       jsonb := '[]'::jsonb;
  v_tot       int := 0;
BEGIN
  SELECT fc.value_num::int INTO v_win FROM forge_config fc
   WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_win IS NULL THEN RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing -- a desk cannot be derived without the receipt window'; END IF;

  FOR v_store IN SELECT s.store_code FROM stores s WHERE s.is_active AND (p_store_code IS NULL OR s.store_code = p_store_code) ORDER BY 1 LOOP
    PERFORM public.refresh_l2_world_assignment(v_store);
    SELECT max(movement_date) INTO v_wm FROM sigma_movements WHERE store_code = v_store;
    v_created := 0; v_derived := 0; v_fallback := 0; v_rank := 0;

    FOR r IN
      WITH rec AS (
        SELECT m.product_code, m.supplier_nr, m.movement_date, m.movement_time, m.movement_id, m.cost_value
          FROM sigma_movements m
         WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
           AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm
           AND m.supplier_nr IS NOT NULL AND m.supplier_nr <> 0
      ),
      latest AS (
        SELECT DISTINCT ON (product_code) product_code, supplier_nr
          FROM rec ORDER BY product_code, movement_date DESC, movement_time DESC NULLS LAST, movement_id DESC
      ),
      cost AS (SELECT supplier_nr, sum(cost_value) AS recv_cost FROM rec GROUP BY 1),
      typ AS (
        SELECT DISTINCT ON (sm.supplier_nr) sm.supplier_nr, sm.supplier_type, COALESCE(NULLIF(trim(sm.name), ''), NULLIF(trim(sm.short_name), ''), 'Supplier ' || sm.supplier_nr) AS nm
          FROM sigma_supplier_master sm WHERE sm.store_code = v_store ORDER BY sm.supplier_nr, sm.id DESC
      )
      SELECT l.supplier_nr, t.nm, t.supplier_type, count(*)::int AS w1_products, c.recv_cost
        FROM latest l
        JOIN typ t  ON t.supplier_nr = l.supplier_nr
        JOIN cost c ON c.supplier_nr = l.supplier_nr
        LEFT JOIN l2_world_assignment w ON w.store_code = v_store AND w.product_code = l.product_code AND w.world = 'WORLD_2'
       WHERE t.supplier_type IS DISTINCT FROM 'Z'
         AND w.product_code IS NULL
         AND NOT EXISTS (SELECT 1 FROM bloom_route_config rc WHERE rc.store_code = v_store AND l.supplier_nr = ANY (rc.direct_supplier_nrs))
       GROUP BY l.supplier_nr, t.nm, t.supplier_type, c.recv_cost
       ORDER BY c.recv_cost DESC, l.supplier_nr
    LOOP
      v_key := 'DIRECT_S' || r.supplier_nr;
      v_rank := v_rank + 1;

      INSERT INTO bloom_route_config
        (store_code, route_key, merch_group_nrs, excluded_supplier_types, status, scope, effective_from, notes,
         direct_supplier_nrs, direct_cycle_weeks, direct_min_order_value)
      VALUES
        (v_store, v_key, NULL, ARRAY['Z'], 'RULED', 'GENERAL', CURRENT_DATE,
         format('DERIVED FROM RECEIPTS (BLOOM-035 item 1, R7). Supplier %s %s, Sigma type %s: %s non-World-2 product(s) last received from it in the %s days to %s, R%s received. Receipt-proven, never typed. Its World 2 inputs, if any, go to the production desk.',
                r.supplier_nr, r.nm, r.supplier_type, r.w1_products, v_win, v_wm, round(r.recv_cost)),
         ARRAY[r.supplier_nr], 1, NULL)
      ON CONFLICT (store_code, route_key) DO NOTHING;
      IF NOT FOUND THEN CONTINUE; END IF;
      v_created := v_created + 1;

      -- cadence from the ledger where it can be derived (two or more drops)
      PERFORM 1 FROM refresh_supplier_calendar(v_store, v_key);
      IF EXISTS (SELECT 1 FROM supplier_calendar sc WHERE sc.store_code = v_store AND sc.route_key = v_key) THEN
        v_derived := v_derived + 1;
      ELSE
        -- too few drops to derive a cadence: the weekdays the supplier actually delivered on, flagged VERIFY
        SELECT array_agg(DISTINCT EXTRACT(ISODOW FROM m.movement_date)::int ORDER BY EXTRACT(ISODOW FROM m.movement_date)::int)
          INTO v_dows
          FROM sigma_movements m
         WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
           AND m.supplier_nr = r.supplier_nr AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm;
        v_note := format('VERIFY, derived from receipts: %s distinct receipt weekday(s) in the %s days to %s, too few drops to derive a cadence. Delivery days are the weekdays this supplier delivered on, cycle assumed weekly. The ledger replaces this as drops accrue (rpc_derive_supplier_cadence, ORDERING-CANON A5).',
                         COALESCE(array_length(v_dows, 1), 0), v_win, v_wm);
        INSERT INTO supplier_calendar
          (store_code, route_key, delivery_dows, scope, effective_from, source_note, order_cutoff_days, promo_buyin_lead_days, cycle_weeks, cycle_anchor_week_start)
        VALUES (v_store, v_key, COALESCE(v_dows, ARRAY[]::int[])::smallint[], 'GENERAL', CURRENT_DATE, v_note, 2, 7, 1, NULL);
        v_fallback := v_fallback + 1;
      END IF;

      UPDATE supplier_calendar sc
         SET display_label = initcap(lower(r.nm)), desk_sort = LEAST(1000 + v_rank, 32000)::smallint
       WHERE sc.store_code = v_store AND sc.route_key = v_key;
    END LOOP;

    v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'desks_created', v_created,
              'cadence_derived', v_derived, 'cadence_verify', v_fallback, 'watermark', v_wm));
    v_tot := v_tot + v_created;
  END LOOP;

  RETURN jsonb_build_object('desks_created', v_tot, 'stores', v_out);
END
$fn$;
REVOKE EXECUTE ON FUNCTION public.refresh_supplier_desks(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_desks(text) TO authenticated, service_role;

COMMENT ON FUNCTION public.refresh_supplier_desks(text) IS
'GRADE: RECOMMENDED. BLOOM-035 item 1 (R7). A desk for every supplier that delivered a non-World-2 product in the desk_receipt_window_days, derived from the receipt ledger, never typed: bloom_route_config DIRECT_S<supplier_nr> + supplier_calendar (cadence derived, or VERIFY weekdays where the ledger has too few drops). Never deletes a desk. DC suppliers already have theirs. World 2 inputs (l2_world_assignment, ENG-020) go to the production desk.';

SELECT pg_notify('pgrst', 'reload schema');
