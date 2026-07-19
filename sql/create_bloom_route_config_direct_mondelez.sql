-- ENG-025 / call-3 reversal (Pieter 2026-07-19): the Mondelez direct desk, ACCOUNT-scoped.
-- Applied live 2026-07-19, migration mondelez_01_seed_direct_desk_account_scoped.
--
-- Mondelez is a type-S DROPSHIPMENT supplier delivered by Super Group. The Sigma RECEIVING account IS
-- the order: 950 @ 10116, 654 @ 80175 (SUPER GROUP AFRICA - MONDELEZ). Scoped to the FULL account, NO
-- brand filter -- the earlier "42 of 96 lines Mondelez" split was brand-name text-matching on product
-- descriptions (the same rule-break as the original supplier_text matching, relocated). We place one
-- order against one supplier account; it delivers across however many invoices. The life gate excludes
-- dead lines by demonstrated non-movement, never a description pre-filter (Pieter ruling).
--
-- Standard DIRECT_<brand> pattern, same as Coca-Cola 21355 / National Brands 80175 -- R32 config-only.
-- Cadence reproduces canon §14 v9 7g exactly: FORTNIGHTLY, median gap 13, the 42-day supply hole
-- excluded as a regime outlier, real drops R12,054-R49,337 vs noise <=R1,839 (10116 Thursday; 80175
-- Wednesday at 37.5% dow-confidence = flagged uncertain, Pieter's walk confirms the day). DC-overlap
-- guard clean (0) at both. confirmed_by NULL until the R31 walk.
INSERT INTO public.bloom_route_config
  (store_code, route_key, direct_supplier_nrs, status, scope, effective_from, direct_min_order_value, notes)
VALUES
  ('10116','DIRECT_MONDELEZ', ARRAY[950]::bigint[], 'RULED', 'DEMO_CALIBRATION', '2026-07-19', 5000,
   'Call-3 reversal (Pieter 2026-07-19): account-scoped, no brand filter. Receiving account 950 SUPER GROUP AFRICA - MONDELEZ (type S dropship). Life gate excludes dead lines. Cadence fortnightly (canon 7g). Awaiting Pieter R31 walk.'),
  ('80175','DIRECT_MONDELEZ', ARRAY[654]::bigint[], 'RULED', 'DEMO_CALIBRATION', '2026-07-19', 5000,
   'Call-3 reversal (Pieter 2026-07-19): account-scoped, no brand filter. Receiving account 654 SUPER GROUP AFRICA - MONDELEZ (type S dropship). Life gate excludes dead lines. Cadence fortnightly (canon 7g), dow low-confidence. Awaiting Pieter R31 walk.')
ON CONFLICT (store_code, route_key) DO NOTHING;

-- Seed the supplier_calendar rows (cycle_weeks=2 + anchor + dows) from the ledger, not a literal INSERT:
--   SELECT * FROM public.refresh_supplier_calendar('10116','DIRECT_MONDELEZ');
--   SELECT * FROM public.refresh_supplier_calendar('80175','DIRECT_MONDELEZ');
