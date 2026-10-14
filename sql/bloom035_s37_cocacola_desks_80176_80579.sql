-- =============================================================================
-- BLOOM-035 s37 (PM 14-10-2026 21:15 section 37): "Build the Coca-Cola desk at 80176 and 80579 (ENG-203)."
--
-- RULED-ALREADY entry checked: BUG-LOG ENG-110 addendum 1 item 4 (RULE-BOOK R25 s6 / ENG-203): "A Coca-Cola desk and a SAB desk at all five stores ...
-- A store with no receipts from the supplier carries the desk with delivery days VERIFY until its own ledger derives them."
--
-- READ (14-10 21:2x, DEDUCTIVE): supplier numbers are PER STORE. Coca-Cola Beverages SA is 499 at 10116, 316 at 21355 and 80579, 275 at 80175 and 315 at 80176
-- (sigma_supplier_master by store). Receipts in the ledger: 21355 30 GRV days in 365 d (last 2026-10-02), 80176 and 80579 NONE ever.
-- At 80579, 45 Coca-Cola range lines sell and sit on no desk today (35 linked to 316, 10 to Fortune 558). At 80176 the sellers are linked to 315 (39) and
-- Fortune 595 (18); account 316 at 80176 is a different supplier (85 active links, no seller).
--
-- BUILT: one bloom_route_config row and one supplier_calendar row per store, DIRECT_COCACOLA, direct_supplier_nrs = the store's own account (80176 '315', 80579 '316').
--   cycle_weeks 1 (PM s37: measured weekly = 1, every desk displays weekly). Cutoff 2 days = the platform floor, a default and not evidence.
--   DELIVERY DAYS ARE A SEED, UNDERIVED, STAMPED VERIFY: no receipt exists to derive them, so each takes the store's own SAB direct drop (80176 Tuesday [2],
--   80579 Friday [5]), the only direct beverage drop in its ledger. The desk says so in order_cutoff_anomaly. Derived replaces it when the ledger receives from the account.
--   status RULED, confirmed_by NULL (same as the 21355 row, awaiting the R31 walk). Pieter has not confirmed these two rows.
-- The desks appear in rpc_bloom_desks at once. Their pool, verdict rows, budget and sheets arrive with the next nightly chain. Nothing is run here.
-- =============================================================================

SET lock_timeout = '5s';

INSERT INTO public.bloom_route_config
  (store_code, route_key, merch_group_nrs, excluded_supplier_types, status, scope, effective_from, confirmed_by, confirmed_at, notes, updated_at,
   direct_supplier_nrs, direct_cycle_weeks, direct_min_order_value)
SELECT v.store_code, 'DIRECT_COCACOLA', NULL, ARRAY['Z'], 'RULED', 'DEMO_CALIBRATION', DATE '2026-10-14', NULL, NULL,
       'BLOOM-035 s37 (PM 14-10-2026 21:15, ENG-203): Coca-Cola desk at every store, ENG-110 add.1 item 4. direct_supplier_nrs = ' || v.acct || ' COCA-COLA BEVERAGES SA (supplier numbers are per store: 316 at 21355 and 80579, 315 at 80176). '
         || 'NO receipts from this account in the ledger, ever: delivery days are a SEED, UNDERIVED, stamped VERIFY (see supplier_calendar). Pieter has not confirmed this row.',
       now(), ARRAY[v.acct::bigint], 1, 5000
  FROM (VALUES ('80176', '315'), ('80579', '316')) AS v(store_code, acct)
ON CONFLICT (store_code, route_key) DO NOTHING;

INSERT INTO public.supplier_calendar
  (store_code, route_key, delivery_dows, scope, effective_from, source_note, updated_at, order_cutoff_days, promo_buyin_lead_days, cycle_weeks,
   cycle_anchor_week_start, order_cutoff_basis, order_cutoff_anomaly, order_cutoff_seeded_prior, display_label, desk_sort)
SELECT v.store_code, 'DIRECT_COCACOLA', ARRAY[v.dow]::smallint[], 'DEMO_CALIBRATION', DATE '2026-10-14',
       'BLOOM-035 s37 (PM 14-10-2026 21:15): Coca-Cola desk built under ENG-203 / ENG-110 add.1 item 4. The store has NO receipts from supplier ' || v.acct
         || ' in the ledger, so delivery_dows is a SEED, UNDERIVED: the store''s own SAB direct drop day (' || v.downame || '), the only direct beverage drop in its ledger. VERIFY with the driver or the order book. Replace by derivation when the ledger receives.',
       now(), 2, 7, 1, NULL,
       'order_cutoff_floor_days (direct or dropship, no demonstrated pair, A5)',
       'VERIFY: delivery days are a seed copied from this store''s SAB drop, not derived. No receipt from the account exists. Cutoff 2 day(s) is the platform floor, a default and not evidence.',
       2, 'Coca-Cola Direct', 2
  FROM (VALUES ('80176', '315', 2, 'Tuesday'), ('80579', '316', 5, 'Friday')) AS v(store_code, acct, dow, downame)
ON CONFLICT (store_code, route_key) DO NOTHING;

SELECT pg_notify('pgrst', 'reload schema');
