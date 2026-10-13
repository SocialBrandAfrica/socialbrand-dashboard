-- =============================================================================
-- PENDING, NOT APPLIED -- 13-10-2026 (BLOOM-035 item 1, BUG-LOG ENG-234)
-- v1.1 of refresh_supplier_desks. The auto-mode classifier denied this migration on 13-10-2026,
-- so it waits for Pieter's permission. sql/create_supplier_desks_from_receipts.sql is what is live.
--
-- The change: a cadence is derived only when rpc_derive_supplier_cadence holds at least
-- desk_min_cadence_gaps (3, SEED, UNDERIVED) usable gaps. Below that the desk carries the weekdays
-- the supplier delivered on, weekly, flagged VERIFY (ORDERING-CANON A5: doubt resolves weekly).
-- v1.0 wrote a 13-week and a 20-week cycle from two receipts each, which is a guess.
--
-- Apply as migration name: supplier_desks_min_cadence_gaps_bloom035_item1
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('desk_min_cadence_gaps', '*', 3, 'DEMO_CALIBRATION', DATE '2026-10-13',
  'SEED, UNDERIVED. Usable receipt gaps rpc_derive_supplier_cadence needs before a derived cycle is written to a desk made by refresh_supplier_desks. Two receipts give one gap and a 13-week cycle, which is a guess. Created 13-10-2026 (BLOOM-035 item 1). Derivation owed.')
ON CONFLICT (config_key, store_format) DO NOTHING;

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
  v_min_gaps  int;
  v_gaps      int;
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
  SELECT fc.value_num::int INTO v_min_gaps FROM forge_config fc
   WHERE fc.config_key = 'desk_min_cadence_gaps' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_min_gaps IS NULL THEN RAISE EXCEPTION 'forge_config desk_min_cadence_gaps is missing'; END IF;

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

      -- the ledger's own cadence where it holds enough drops to state one
      SELECT d.gaps_used INTO v_gaps FROM public.rpc_derive_supplier_cadence(v_store, v_key) d LIMIT 1;
      IF COALESCE(v_gaps, 0) >= v_min_gaps THEN
        PERFORM 1 FROM refresh_supplier_calendar(v_store, v_key);
        v_derived := v_derived + 1;
      ELSE
        -- too few drops to derive a cadence: the weekdays the supplier actually delivered on, weekly, VERIFY
        SELECT array_agg(DISTINCT EXTRACT(ISODOW FROM m.movement_date)::int ORDER BY EXTRACT(ISODOW FROM m.movement_date)::int)
          INTO v_dows
          FROM sigma_movements m
         WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
           AND m.supplier_nr = r.supplier_nr AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm;
        v_note := format('VERIFY, derived from receipts: %s usable receipt gap(s) in the %s days to %s, the rule needs %s before a cadence is stated. Delivery days are the weekdays this supplier delivered on, cycle assumed weekly (doubt resolves weekly, ORDERING-CANON A5). The ledger replaces this as drops accrue.',
                         COALESCE(v_gaps, 0), v_win, v_wm, v_min_gaps);
        INSERT INTO supplier_calendar
          (store_code, route_key, delivery_dows, scope, effective_from, source_note, order_cutoff_days, promo_buyin_lead_days, cycle_weeks, cycle_anchor_week_start)
        VALUES (v_store, v_key, COALESCE(v_dows, ARRAY[]::int[])::smallint[], 'GENERAL', CURRENT_DATE, v_note, 2, 7, 1, NULL)
        ON CONFLICT (store_code, route_key) DO UPDATE
          SET delivery_dows = EXCLUDED.delivery_dows, source_note = EXCLUDED.source_note,
              cycle_weeks = 1, cycle_anchor_week_start = NULL, updated_at = now();
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
