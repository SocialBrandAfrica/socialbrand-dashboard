-- ENG-185 -- SAB gets its own desk, always (Pieter 2026-09-10: 'then sab gets it's own desk always').
-- ORDERING-CANON v1.23 SSA1 names Coca-Cola and SAB at all five stores (ENG-110 add.1). This is the SAB instance at
-- TOPS Dice (80579): bloom_route_config carries a RULED DIRECT_BEER row (account 555, type F), but supplier_calendar
-- had no row, and rpc_bloom_desks builds desks from calendar rows only.
-- Delivery day DERIVED from the store's own receipts: Friday on 22 of 28 SAB receipt days in 365 d (79%, above
-- dow_confidence_min 60), 2025-09-12 to 2026-03-27, weekly. SAB has not delivered to Dice since 2026-03-27.
-- RE-CUT 2026-09-11 (ENG-110 add.2, Pieter 11-09: 'ledger or raw data must prove the descision automatically'): the
-- 1-day floor_attested cutoff of the 2026-09-10 build is retired, R28 (it was never applied). The ledger holds no SAB
-- placement date (BEES app, order_date 1990-01-01), so the row takes the platform default order_cutoff_floor_days
-- with VERIFY, read from config, never a literal. The basis does not start floor_attested, so the weekly
-- refresh_supplier_calendar_cutoff re-derives it like any other row. Rolled-back run 2026-09-11: it returns 2 days,
-- 'placement_dow_below_floor (VERIFY, not enacted)', the same answer. Pieter's Thursday order day stays in the note.
-- APPLY WITH ENG-183 AND BEFORE ITS (A). Opened alone, the next cache build puts the SAB lines on both the
-- DC_TOPS and the DIRECT_BEER sheets, the defect ENG-183 closes. Never on an order morning.
-- Budget: 80579 holds no DIRECT or DIRECT_BEER ledger row, so the desk screen reads 'No budget row found'
-- until ENG-176 (ledger grain = route) lands.

DO $eng185$
DECLARE
  n int;
  f int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.bloom_route_config
                  WHERE store_code = '80579' AND route_key = 'DIRECT_BEER' AND status = 'RULED' AND 555 = ANY(direct_supplier_nrs)) THEN
    RAISE EXCEPTION 'ENG-185: no RULED 80579 DIRECT_BEER route row on account 555';
  END IF;
  IF EXISTS (SELECT 1 FROM public.supplier_calendar WHERE store_code = '80579' AND route_key = 'DIRECT_BEER') THEN
    RAISE EXCEPTION 'ENG-185: 80579 DIRECT_BEER already has a calendar row';
  END IF;
  SELECT fc.value_num::int INTO f FROM public.forge_config fc
   WHERE fc.config_key = 'order_cutoff_floor_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF f IS NULL THEN RAISE EXCEPTION 'ENG-185: forge_config order_cutoff_floor_days is missing'; END IF;

  INSERT INTO public.supplier_calendar
    (store_code, route_key, delivery_dows, order_cutoff_days, cycle_weeks, desk_sort, display_label, scope,
     effective_from, promo_buyin_lead_days, order_cutoff_seeded_prior, order_cutoff_basis, source_note, updated_at)
  VALUES
    ('80579', 'DIRECT_BEER', ARRAY[5]::smallint[], f, 1, 1, 'SAB Direct', 'DEMO_CALIBRATION',
     (now() AT TIME ZONE 'Africa/Johannesburg')::date, 7, NULL,
     'order_cutoff_floor_days (VERIFY): no derivable placement. SAB is ordered in the BEES app and Sigma books the order at GRV with order_date 1990-01-01, so the ledger holds no placement date (ENG-110 add.2). Platform default until placement is captured (ENG-110 add.2 step 3). Pieter 2026-09-10: Dice orders Thursday.',
     'ENG-185 2026-09-11: SAB gets its own desk always (Pieter). delivery_dows DERIVED from sigma_movements R/W DIWAREPR, supplier 555, 365 d: Friday 22, Saturday 3, Monday 2, Sunday 1 of 28 receipt days (79% Friday), 2025-09-12 to 2026-03-27, weekly. Last SAB delivery 2026-03-27. Cutoff re-cut from the 2026-09-10 build''s 1-day floor_attested to order_cutoff_floor_days with VERIFY (ENG-110 add.2).',
     now());

  UPDATE public.bloom_route_config
     SET notes = COALESCE(notes, '') || ' | ENG-185 2026-09-11 (Pieter ruling: sab gets it''s own desk always): supplier_calendar row added, Friday delivery (derived, 22 of 28 receipt days), cutoff order_cutoff_floor_days with VERIFY (ENG-110 add.2: the ledger holds no SAB placement date). The named gap above is closed.',
         updated_at = now()
   WHERE store_code = '80579' AND route_key = 'DIRECT_BEER';

  SELECT count(*) INTO n FROM public.rpc_bloom_desks('80579') d WHERE d.route_key = 'DIRECT_BEER';
  IF n <> 1 THEN RAISE EXCEPTION 'ENG-185: rpc_bloom_desks(80579) does not return DIRECT_BEER'; END IF;
END $eng185$;