-- =============================================================================
-- BLOOM-035 item 1b -- THE DC FRESH DESK (ENG-204). PHASE 1: the derivation, and the switch.
-- Apply AFTER sql/bloom035_1b_dc_fresh_phase0.sql (every reader already knows the route 'DC_FRESH').
--
--   refresh_dc_fresh_desk(store) derives, per store where bloom_dc_config.fresh_cycle_applicable is true:
--     (1) the DEPARTMENTS: the departments of the World 1 NORMAL products the DC (type-Z suppliers) delivered in
--         desk_receipt_window_days to the store's ledger watermark, that are not in dc_cycle_dept_nrs (PM ruling B3, R21,
--         never typed). Written to bloom_dc_config.dc_fresh_dept_nrs.
--     (2) the DELIVERY WEEKDAYS, from the same receipts: a weekday is a delivery day when its count of distinct
--         receipt days in the window reaches desk_dow_min_modal_share of the modal weekday's. The adjacency clustering of
--         rpc_derive_supplier_cadence is NOT used: fresh delivery weekdays sit next to each other and noise days (a Friday
--         with one receipt day) would chain the whole week into one cluster (measured on 80175: Mon 20, Tue 2, Wed 25, Thu 4,
--         Fri 2, Sat 26, Sun 3 receipt days over 26 weeks).
--     (3) the supplier_calendar row 'DC_FRESH', written LAST and in the same call as (1), so the desk never exists half-built:
--         label '<format> DC Fresh', desk_sort 1 (the second tab, after the ambient DC at 0), cycle weekly (doubt resolves
--         weekly, ORDERING-CANON A5), cutoff the general rule (min 2 days), re-derived by the weekly cutoff job.
--   Idempotent. A re-run re-derives the departments and weekdays and keeps the cutoff provenance tail of the note.
--   A store with fresh_cycle_applicable and no qualifying receipts keeps its row untouched and reports no_fresh_departments.
--   Internal: service_role only. Nightly: cron job 54, after refresh_supplier_desks (which rebuilds l2_world_assignment first).
--   forge_config desk_dow_min_modal_share 0.5: SEED, UNDERIVED. It is the cluster_keep rule already literal in
--   rpc_derive_supplier_cadence, made config here (R25). Derivation owed: test it on the five DC desks and the direct desks
--   whose typed weekdays are known (a store #6 inherits this seed, so the stamp is on the key).
-- REVERSE: DELETE FROM supplier_calendar WHERE route_key='DC_FRESH'; UPDATE bloom_dc_config SET dc_fresh_dept_nrs=NULL;
--   cron.alter_job 54 back to 'SELECT refresh_supplier_desks(); SELECT refresh_l2_received_placement();'.
--   Each reader goes dormant again the moment the departments are NULL.
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('desk_dow_min_modal_share', '*', 0.5, 'DEMO_CALIBRATION', DATE '2026-10-14',
  'SEED, UNDERIVED. ENG-204 / BLOOM-035 item 1b: a weekday is a delivery day of a DC desk derived from receipts (refresh_dc_fresh_desk) when its count of distinct receipt days in desk_receipt_window_days reaches this share of the modal weekday''s count. 0.5 is the cluster_keep rule already literal in rpc_derive_supplier_cadence, made config here. Chosen, not derived. Derivation owed: run it on the desks whose typed delivery weekdays are known and report where it disagrees.')
ON CONFLICT (config_key, store_format) DO NOTHING;

CREATE OR REPLACE FUNCTION public.refresh_dc_fresh_desk(p_store_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_store   text;
  v_wm      date;
  v_win     int;
  v_share   numeric;
  v_depts   smallint[];
  v_dows    smallint[];
  v_lines   int;
  v_fmt     text;
  v_note    text;
  v_changed boolean;
  v_out     jsonb := '[]'::jsonb;
BEGIN
  SELECT fc.value_num::int INTO v_win FROM forge_config fc
   WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_win IS NULL THEN RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing -- the DC fresh desk cannot be derived without the receipt window'; END IF;
  SELECT fc.value_num INTO v_share FROM forge_config fc
   WHERE fc.config_key = 'desk_dow_min_modal_share' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_share IS NULL THEN RAISE EXCEPTION 'forge_config desk_dow_min_modal_share is missing'; END IF;

  FOR v_store, v_fmt IN
    SELECT dc.store_code, dc.format_group FROM bloom_dc_config dc
      JOIN stores s ON s.store_code = dc.store_code AND s.is_active
     WHERE dc.status = 'RULED' AND dc.fresh_cycle_applicable AND (p_store_code IS NULL OR dc.store_code = p_store_code)
     ORDER BY 1
  LOOP
    SELECT max(movement_date) INTO v_wm FROM sigma_movements WHERE store_code = v_store;

    DROP TABLE IF EXISTS _fd_rec;
    CREATE TEMP TABLE _fd_rec AS
      SELECT m.product_code, m.movement_date, sp.department_nr
        FROM sigma_movements m
        JOIN l2_stock_position sp ON sp.store_code = m.store_code AND sp.product_code = m.product_code AND sp.class = 'NORMAL'
       WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
         AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm
         AND EXISTS (SELECT 1 FROM sigma_supplier_master sm
                      WHERE sm.store_code = m.store_code AND sm.supplier_nr = m.supplier_nr AND sm.supplier_type = 'Z')
         AND NOT EXISTS (SELECT 1 FROM l2_world_assignment w
                          WHERE w.store_code = m.store_code AND w.product_code = m.product_code AND w.world = 'WORLD_2');

    SELECT array_agg(DISTINCT r.department_nr ORDER BY r.department_nr) INTO v_depts
      FROM _fd_rec r JOIN bloom_dc_config dc ON dc.store_code = v_store
     WHERE NOT (r.department_nr = ANY (dc.dc_cycle_dept_nrs));

    IF v_depts IS NULL THEN
      UPDATE bloom_dc_config SET dc_fresh_dept_nrs = NULL, updated_at = now()
       WHERE store_code = v_store AND dc_fresh_dept_nrs IS NOT NULL;
      v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'status', 'no_fresh_departments', 'watermark', v_wm));
      CONTINUE;
    END IF;

    SELECT count(DISTINCT r.product_code)::int INTO v_lines FROM _fd_rec r WHERE r.department_nr = ANY (v_depts);

    SELECT array_agg(u.dw ORDER BY u.dw)::smallint[] INTO v_dows
      FROM (SELECT t.dw, t.days, max(t.days) OVER () AS mx
              FROM (SELECT EXTRACT(ISODOW FROM r.movement_date)::int AS dw, count(DISTINCT r.movement_date)::int AS days
                      FROM _fd_rec r WHERE r.department_nr = ANY (v_depts) GROUP BY 1) t) u
     WHERE u.days >= v_share * u.mx;

    v_note := format('DERIVED FROM RECEIPTS (BLOOM-035 item 1b, ENG-204, R21). Departments %s: the %s World 1 NORMAL product(s) the DC delivered in the %s days to %s that are outside the ambient cycle. Delivery weekdays %s: a weekday counts when its receipt days reach %s of the modal weekday''s (forge_config desk_dow_min_modal_share, SEED UNDERIVED). Cycle weekly, doubt resolves weekly (ORDERING-CANON A5). Cutoff: the general rule, minimum 2 days, re-derived weekly.',
                     v_depts::text, v_lines, v_win, v_wm, v_dows::text, v_share);

    -- (1) the departments, then (3) the desk row, in this one call.
    UPDATE bloom_dc_config SET dc_fresh_dept_nrs = v_depts, updated_at = now()
     WHERE store_code = v_store AND dc_fresh_dept_nrs IS DISTINCT FROM v_depts;
    GET DIAGNOSTICS v_lines = ROW_COUNT;
    v_changed := v_lines > 0;

    INSERT INTO supplier_calendar
      (store_code, route_key, delivery_dows, scope, effective_from, source_note, order_cutoff_days, promo_buyin_lead_days,
       cycle_weeks, cycle_anchor_week_start, display_label, desk_sort)
    VALUES (v_store, 'DC_FRESH', v_dows, 'GENERAL', CURRENT_DATE, v_note, 2, 7, 1, NULL, v_fmt || ' DC Fresh', 1)
    ON CONFLICT (store_code, route_key) DO UPDATE
      SET delivery_dows = EXCLUDED.delivery_dows,
          source_note = EXCLUDED.source_note
                        || COALESCE(CASE WHEN position(' | cutoff derived' IN supplier_calendar.source_note) > 0
                                         THEN substring(supplier_calendar.source_note FROM position(' | cutoff derived' IN supplier_calendar.source_note)) END, ''),
          updated_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'status', 'ok', 'departments', v_depts,
              'delivery_dows', v_dows, 'departments_changed', v_changed, 'watermark', v_wm));
  END LOOP;

  DROP TABLE IF EXISTS _fd_rec;
  RETURN jsonb_build_object('stores', v_out);
END
$function$;

REVOKE EXECUTE ON FUNCTION public.refresh_dc_fresh_desk(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_dc_fresh_desk(text) TO service_role;
COMMENT ON FUNCTION public.refresh_dc_fresh_desk(text) IS 'GRADE: RECOMMENDED. ENG-204 / BLOOM-035 item 1b. Derives the DC fresh desk per store (departments and delivery weekdays from the DC''s own World 1 receipts, R21) and writes bloom_dc_config.dc_fresh_dept_nrs plus the supplier_calendar row DC_FRESH in one call. Idempotent, nightly (cron job 54). Internal, service_role only.';

SELECT pg_notify('pgrst', 'reload schema');
