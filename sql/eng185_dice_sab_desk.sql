-- ENG-185 -- SAB gets its own desk, always (Pieter 2026-09-10: 'then sab gets it's own desk always').
-- ORDERING-CANON SSA1 still reads '80579 receives by IBT and gets no SAB desk'; this ruling retires that line
-- (PM to churn, R28). TOPS Dice (80579) is the one store where SAB (account 555, type F) delivers and no SAB desk
-- exists: bloom_route_config carries a RULED DIRECT_BEER row, but supplier_calendar has no row, and
-- rpc_bloom_desks builds desks from calendar rows only.
-- Delivery day DERIVED from the store's own receipts: Friday on 22 of 28 SAB receipt days in 365 d (79%, above
-- dow_confidence_min 60), 2025-09-12 to 2026-03-27, weekly. SAB has not delivered to Dice since 2026-03-27.
-- Order day RULING, Pieter 2026-09-10: 'dice and delareyville tops order thursdays. roosville orders mondays'.
-- Thursday for Friday = 1 day. order_cutoff_basis is floor_attested, so refresh_supplier_calendar_cutoff
-- (weekly, Sunday 19:45 UTC) leaves the row alone.
-- APPLY WITH ENG-183 AND BEFORE ITS (A). Opened alone, the next cache build puts the SAB lines on both the
-- DC_TOPS and the DIRECT_BEER sheets, the defect ENG-183 closes. Never on an order morning.
-- Budget: 80579 holds no DIRECT or DIRECT_BEER ledger row, so the desk screen reads 'No budget row found'
-- until ENG-176 (ledger grain = route) lands.

DO $eng185$
DECLARE
  n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.bloom_route_config
                  WHERE store_code = '80579' AND route_key = 'DIRECT_BEER' AND status = 'RULED' AND 555 = ANY(direct_supplier_nrs)) THEN
    RAISE EXCEPTION 'ENG-185: no RULED 80579 DIRECT_BEER route row on account 555';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supplier_calendar WHERE store_code = '80579' AND route_key = 'DIRECT_BEER') THEN
    RAISE EXCEPTION 'ENG-185: 80579 DIRECT_BEER already has a calendar row';
  END IF;

  INSERT INTO public.supplier_calendar
    (store_code, route_key, delivery_dows, order_cutoff_days, cycle_weeks, desk_sort, display_label, scope,
     effective_from, promo_buyin_lead_days, order_cutoff_seeded_prior, order_cutoff_basis, source_note, updated_at)
  VALUES
    ('80579', 'DIRECT_BEER', ARRAY[5]::smallint[], 1, 1, 1, 'SAB Direct', 'DEMO_CALIBRATION',
     (now() AT TIME ZONE 'Africa/Johannesburg')::date, 7, 2,
     'floor_attested (Pieter 2026-09-10: dice and delareyville tops order thursdays; SAB delivers Dice on Friday). RULING, not derived. The ledger holds 1 SAB placement at 80579 (Thursday 2026-03-12), below the 5-order evidence bar, so no derivation reaches this and none should overwrite it.',
     'ENG-185 2026-09-10: SAB gets its own desk always (Pieter). delivery_dows DERIVED from sigma_movements R/W DIWAREPR, supplier 555, 365 d: Friday 22, Saturday 3, Monday 2, Sunday 1 of 28 receipt days (79% Friday), 2025-09-12 to 2026-03-27, weekly. Last SAB delivery 2026-03-27.',
     now());

  UPDATE public.bloom_route_config
     SET notes = notes || ' | ENG-185 2026-09-10 (Pieter ruling: sab gets it''s own desk always): supplier_calendar row added, Friday delivery (derived, 22 of 28 receipt days), Thursday order (ruling), 1-day cutoff. The named gap above is closed.',
         updated_at = now()
   WHERE store_code = '80579' AND route_key = 'DIRECT_BEER';

  SELECT count(*) INTO n FROM public.rpc_bloom_desks('80579') d WHERE d.route_key = 'DIRECT_BEER';
  IF n <> 1 THEN RAISE EXCEPTION 'ENG-185: rpc_bloom_desks(80579) does not return DIRECT_BEER'; END IF;
END $eng185$;
