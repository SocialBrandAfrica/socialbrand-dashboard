-- SB-CC / ENG-025 : writes the derived cadence into supplier_calendar WITH provenance (canon section
-- 14 v9 item 7h). Onboarding a new store becomes: SELECT refresh_supplier_calendar('<store>').
-- Applied 2026-07-18, migration cadence_law_04_refresh_supplier_calendar.
--
-- Zero-delta discipline (ENG-025 step 3): for a desk that ALREADY exists, delivery_dows is PRESERVED
-- verbatim -- a ruled dow is never silently overwritten; a divergence is SURFACED in source_note per
-- ENG-026 (canon 7f: "surfaced, never silently overridden"). Only the NEW cadence facts (cycle_weeks
-- + cycle_anchor_week_start) are stamped. A net-new desk is seeded from the derivation.
-- Scope: DIRECT_* desks carrying direct_supplier_nrs (the generator's scope).
CREATE OR REPLACE FUNCTION public.refresh_supplier_calendar(
  p_store_code text,
  p_route_key  text DEFAULT NULL
)
RETURNS TABLE (
  store_code text, route_key text, action text,
  cycle_weeks smallint, delivery_dows int[], cycle_anchor_week_start date,
  dow_matches_calendar boolean, note text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  d record;
  v_exists boolean;
  v_note text;
BEGIN
  FOR d IN
    SELECT * FROM public.rpc_derive_supplier_cadence(p_store_code, p_route_key)
  LOOP
    SELECT EXISTS(
      SELECT 1 FROM public.supplier_calendar sc
      WHERE sc.store_code=d.store_code AND sc.route_key=d.route_key
    ) INTO v_exists;

    v_note := format('derived %s (rpc_derive_supplier_cadence, window %sd)', d.evidence, d.window_days);

    IF v_exists THEN
      -- PRESERVE delivery_dows; stamp cadence only. Surface a dow divergence, never write it.
      IF NOT d.dow_matches_calendar THEN
        v_note := v_note || format(' | DOW DIVERGES: ledger proposes %s @ %s%% -- preserved stored dow, review (ENG-026)',
                                   d.proposed_delivery_dows::text, d.modal_dow_pct);
      END IF;
      UPDATE public.supplier_calendar sc
         SET cycle_weeks             = d.cycle_weeks,
             cycle_anchor_week_start = d.cycle_anchor_week_start,
             source_note             = v_note,
             updated_at              = now()
       WHERE sc.store_code=d.store_code AND sc.route_key=d.route_key
       RETURNING sc.delivery_dows INTO delivery_dows;
      action := 'updated_cadence';
    ELSE
      -- Net-new desk: seed dows from the derivation.
      INSERT INTO public.supplier_calendar
        (store_code, route_key, delivery_dows, scope, effective_from, source_note,
         order_cutoff_days, promo_buyin_lead_days, cycle_weeks, cycle_anchor_week_start)
      VALUES
        (d.store_code, d.route_key, d.proposed_delivery_dows, 'DEMO_CALIBRATION', CURRENT_DATE, v_note,
         2, 7, d.cycle_weeks, d.cycle_anchor_week_start);
      delivery_dows := d.proposed_delivery_dows;
      action := 'inserted';
    END IF;

    store_code := d.store_code; route_key := d.route_key;
    cycle_weeks := d.cycle_weeks; cycle_anchor_week_start := d.cycle_anchor_week_start;
    dow_matches_calendar := d.dow_matches_calendar; note := v_note;
    RETURN NEXT;
  END LOOP;
END $fn$;

REVOKE ALL ON FUNCTION public.refresh_supplier_calendar(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_supplier_calendar(text,text) TO authenticated;
