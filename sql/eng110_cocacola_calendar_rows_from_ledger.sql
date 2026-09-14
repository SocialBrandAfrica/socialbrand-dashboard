-- eng110_cocacola_calendar_rows_from_ledger.sql
-- RECORD of migration eng110_cocacola_calendar_rows_from_ledger, applied 2026-09-14 by CC through the Supabase
-- connector, in the same pass as ENG-082 H14 stage 2. The text below is the migration as applied.

-- ENG-110 add.1 items 1 and 2 (Pieter RULING 2026-09-10), in the same pass as ENG-082 H14 stage 2 (CC 2026-09-14).
-- The derivation is read, not typed: rpc_derive_supplier_cadence evidence is carried in each row's source_note.
-- The prior values are kept in the note and in public._cc_r22_s2_calendar_before (R28).
DO $cc$
DECLARE n int;
BEGIN
  UPDATE public.supplier_calendar
     SET delivery_dows = '{4}',
         source_note = COALESCE(source_note, '') || ' | 2026-09-14 ENG-110 add.1 item 2 (Pieter RULING 2026-09-10: the ledger governs a typed day): delivery_dows {5} to {4}. rpc_derive_supplier_cadence derives dows {4} on 91 d and on 182 d (Thursday, 69.2% confidence, 13 and 24 drops, last drop Fri 2026-09-11). ENG-082 H14 stage 2, CC.',
         updated_at = now()
   WHERE store_code = '10116' AND route_key = 'DIRECT_COCACOLA' AND delivery_dows = '{5}';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION '10116 DIRECT_COCACOLA: % rows updated, expected 1', n; END IF;

  UPDATE public.supplier_calendar
     SET cycle_weeks = 1,
         source_note = COALESCE(source_note, '') || ' | 2026-09-14 ENG-110 add.1 item 1 (Pieter RULING 2026-09-10, "21355 goes weekly"): cycle_weeks 2 to 1. rpc_derive_supplier_cadence derives weekly on 91 d (median gap 7, regime from 2026-08-14, one 42-day gap excluded as an interruption) and fortnightly on 182 d (median gap 13). No drop since Thu 2026-08-27. ENG-082 H14 stage 2, CC.',
         updated_at = now()
   WHERE store_code = '21355' AND route_key = 'DIRECT_COCACOLA' AND cycle_weeks = 2;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION '21355 DIRECT_COCACOLA: % rows updated, expected 1', n; END IF;
END $cc$;
