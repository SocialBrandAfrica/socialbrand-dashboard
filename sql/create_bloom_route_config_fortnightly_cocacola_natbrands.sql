-- SB-CC / ENG-025 step 4 (partial) : the two receipt-confirmed fortnightly direct desks.
-- Applied 2026-07-18, migration cadence_law_08b_seed_fortnightly_two_desks.
--
-- Identity is the RECEIVING account (canon 7d -- receipts, never names/links). Both are single-brand
-- accounts whose LINK number == RECEIPT number, so the recipe's link-based pool and the receipt-based
-- cadence agree on one supplier_nr:
--   Coca-Cola 21355 = supplier 316 (COCA-COLA BEVERAGES), median drop gap 13 -> cycle_weeks=2, Fri.
--   National Brands 80175 = supplier 47 (NATIONAL BRANDS LIMITED), gap 14 -> cycle_weeks=2, Tue.
-- DC-overlap guard (rpc_bloom_direct_dc_overlap) returns 0 for both -- no double-count with the DC pool.
-- direct_cycle_weeks omitted (RETIRED -- supplier_calendar.cycle_weeks owns cadence). confirmed_by left
-- NULL until Pieter's R31 walk.
--
-- HELD, NOT here: Mondelez x2. It is Super Group distributor-delivered (10116=950, 80175=654), a
-- MULTI-BRAND account (96 received products @10116, only 42 Mondelez), and its "MONDELEZ" link account
-- (1586/1280) carries ZERO receipts. Link!=receipt and the receiving account mixes brands, so it does
-- not fit the single-supplier_nr desk model -- a scoping question owed to PM (R27 §7), never guessed.

INSERT INTO public.bloom_route_config
  (store_code, route_key, direct_supplier_nrs, status, scope, effective_from, direct_min_order_value, notes)
VALUES
  ('21355','DIRECT_COCACOLA', ARRAY[316]::bigint[], 'RULED', 'DEMO_CALIBRATION', '2026-07-18', 5000,
   'ENG-025 step 4: fortnightly (gap 13, cycle_weeks=2, Fri). Receipt-proven supplier 316 COCA-COLA BEVERAGES (link==receipt). DC-overlap vs DC_TOPS = 0. Awaiting Pieter R31 walk.'),
  ('80175','DIRECT_NATBRANDS', ARRAY[47]::bigint[], 'RULED', 'DEMO_CALIBRATION', '2026-07-18', 5000,
   'ENG-025 step 4: fortnightly (gap 14, cycle_weeks=2, Tue). Receipt-proven supplier 47 NATIONAL BRANDS LIMITED (link==receipt). DC-overlap vs DC_AMBIENT = 0. Awaiting Pieter R31 walk.')
ON CONFLICT (store_code, route_key) DO NOTHING;

-- Seed the supplier_calendar rows (cycle_weeks=2 + anchor + dows) from the ledger, not a literal INSERT:
--   SELECT * FROM public.refresh_supplier_calendar('21355','DIRECT_COCACOLA');
--   SELECT * FROM public.refresh_supplier_calendar('80175','DIRECT_NATBRANDS');
