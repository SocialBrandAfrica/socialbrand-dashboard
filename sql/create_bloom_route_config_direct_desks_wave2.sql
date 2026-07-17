-- create_bloom_route_config_direct_desks_wave2.sql
-- SB-CC-BLOOM-009 wave 2 -- Clover, Danone and Simba direct desks at the SPAR
-- pair (10116 + 80175). Pure CONFIG: zero schema change, zero RPC change.
-- rpc_bloom_order_recipe / rpc_bloom_stock_state / rpc_bloom_scenario_overview
-- all already generalise on the `DIRECT\_%` route pattern and read
-- direct_supplier_nrs off a RULED bloom_route_config row, so a new desk is
-- config + a frontend list entry. That is R32's rollout test passing on its
-- own terms (an existing applet on an existing store, zero schema surgery).
--
-- ============================================================================
-- SUPPLIER IDENTITY -- settled on RECEIPTS, not names or link counts.
-- ============================================================================
-- Every brand carries several live-linked supplier_nr rows per store. Three
-- independent signals were run before a single row was seeded, and all three
-- agree on ONE receiving supplier_nr per brand per store:
--
--   (1) live-linked product count   (2) actual R/W receipt cadence
--   (3) demonstrated 28d cost demand vs the brief's own PM reference
--
-- The receipt test is what DECIDES, because the Coca-Cola pass already proved
-- the name-obvious account can be a ghost (supplier_nr=1586 "MONDELEZ", zero
-- receipts). Confirmed again here, at scale:
--
--   10116 CLOVER: 1611 "CLOVER" holds 614 live links and 613 products that
--   1610 does not carry -- and ZERO of them have sold in 28 days (R0.00).
--   A dead legacy account. 1610 alone is the desk. (This supersedes the wave-1
--   file's "1610+1611 union" note, which observed the same cadence but did not
--   test whether 1611 contributed anything. It does not.)
--
-- The same exclusive-selling-product test was run across EVERY non-dominant
-- sub-account of all five brands (Clover Ambient/Eskort/Dairybelle, Simba
-- Candy Tops/Sakata, Mondelez Toberol/SG Convenience, Danone Dry Goods,
-- NatBrands Grocgrop/Biscuits). Total demand any of them carries that the
-- dominant misses: Mondelez 1586 = R54.66/wk, Mondelez 1280 = R4.53/wk,
-- every other sub-account = R0.00. Immaterial. The dominant supplier_nr alone
-- is the correct pool for every brand, proven not assumed.
--
-- Demand cross-check vs the brief's own PM reference (item 5, 10116 weekly):
--   Simba    R18,006 vs PM R18,092  (-0.5%)
--   Mondelez R16,159 vs PM R15,938  (+1.4%)
--   Danone   R 8,959 vs PM R 9,075  (-1.3%)
--   Clover   R36,005 vs PM R29,403  (+22.5%)
--   NatBrands R7,096 vs PM R 8,502  (-16.5%)
-- The two outliers are NOT pool-membership errors -- the sub-account test above
-- proves the dominant covers everything that sells. They are the 5-day window
-- shift between the brief (2026-07-12) and this build (2026-07-17). Reported,
-- never tuned to match (R22: the number is what it is).
--
-- ============================================================================
-- CADENCE -- median gap between consecutive drops, NOT drops-per-week.
-- ============================================================================
-- The brief's rule 3 ("weekly where drops_per_wk >= 1, else fortnightly") is a
-- PROXY. Measured directly, it mis-classifies two brands, so this file uses the
-- thing the proxy was reaching for: the median gap between consecutive real
-- drop days (16wk window, >=3 lines/day noise floor). R21 -- behaviour decides,
-- never a constant fitted to one case.
--
--   brand / store        drops_per_wk   MEDIAN GAP   verdict
--   CLOVER   10116          1.50           5.0 d     twice weekly  (Tue 7 / Thu 4)
--   CLOVER   80175          1.75           5.0 d     twice weekly  (Tue 8 / Thu 6)
--   DANONE   10116          1.50           5.0 d     twice weekly  (Thu 7 / Tue 4)
--   DANONE   80175          1.88           4.0 d     twice weekly  (Thu 8 / Tue 6)
--   SIMBA    10116          0.75           7.0 d     WEEKLY        (Fri 5 / Sat 1)
--   SIMBA    80175          0.75           7.0 d     WEEKLY        (Fri 5 / Sat 1)
--
-- SIMBA is the correction: 0.75 drops/wk reads "fortnightly" under the literal
-- rule, but its median gap is exactly 7.0 -- a weekly Friday truck that skips
-- roughly a quarter of its Fridays (noise floor + holidays pull the average
-- down; max gap 18d). It is at EXACT parity with the already-shipped, accepted
-- Coca-Cola 10116 desk (median gap 7.0, mean 8.2, max 15). Weekly, {5}.
--
-- CLOVER + DANONE get TWO delivery days ({2,4}), and this does NOT contradict
-- the wave-1 file's "single dominant weekday, NOT the full observed set" note.
-- That note is correct for a genuinely ONCE-weekly supplier, where encoding a
-- second day invents a truck that does not exist and collapses the lead to 1
-- day. Clover's and Danone's second truck is REAL (median gap 4-5 days, Tue AND
-- Thu, every week). Forcing them to a single DOW would tell the recipe the next
-- truck is 7 days out when it is genuinely 2-5 -- over-ordering, the exact
-- inverse of the bug wave 1 fixed. Same principle, opposite configuration.
--
-- ============================================================================
-- NOT IN THIS WAVE, and why (no silent skips -- R21 SS5 / brief item 4)
-- ============================================================================
-- MONDELEZ (median gap 12-13 d) and NATIONAL BRANDS (median gap 11-13 d) are
-- GENUINELY fortnightly at both stores. supplier_calendar.delivery_dows is a
-- weekday array with no fortnightly concept, so a single DOW would offer them a
-- 7-day drop cover against a real ~13-day gap -- knowingly HALVING the order.
-- Canon v9 item 8 (the accuracy gate) forbids shipping a desk whose band input
-- is knowingly wrong, so they are HELD pending the fortnightly cycle mechanic,
-- not seeded at a wrong cover. That mechanic is a shared pantry debt (R32 --
-- paid once in the calendar for every route), not a per-desk patch.
--
-- Named live defect found while checking this (flagged, NOT fixed here):
-- bloom_route_config.direct_cycle_weeks and direct_min_order_value are STORED
-- BUT NEVER READ -- nothing in sql/ or src/ consumes either, so brief rules 3
-- (cycle) and 4 (R5,000 minimum, accumulate to next cycle) are config
-- decoration rather than behaviour on EVERY direct desk, wave 1 included.
-- Consequence today: Coca-Cola 80175 carries direct_cycle_weeks=2 while its
-- own median gap is 7.0 (weekly) -- the config is wrong AND inert, so the live
-- desk happens to order on the correct weekly cover by accident. The moment the
-- column becomes load-bearing that stale row would DOUBLE a live desk's cover.
-- Carrying that dependent is part of the fortnightly build (R30), which is why
-- direct_cycle_weeks is set honestly on every row below even though nothing
-- reads it yet.
-- ============================================================================

INSERT INTO public.bloom_route_config
  (store_code, route_key, direct_supplier_nrs, direct_cycle_weeks, status, scope, effective_from, notes)
VALUES
  ('10116','DIRECT_CLOVER', ARRAY[1610]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=1610 CLOVER SA (PTY)LTD, 715 live-linked products, R36,005/wk demonstrated cost demand. Receipt-proven: 1611 "CLOVER" holds 613 exclusive products with R0.00 sales in 28d = dead legacy account, excluded. Median drop gap 5.0d = genuinely twice weekly.'),
  ('80175','DIRECT_CLOVER', ARRAY[1286]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=1286 CLOVER SA (PTY)LTD (store-scoped, distinct from 10116''s 1610), 699 live-linked products, R20,180/wk. Median drop gap 5.0d = twice weekly.'),
  ('10116','DIRECT_DANONE', ARRAY[1257]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=1257 DANONE SA, 151 live-linked products, R8,959/wk vs PM reference R9,075 (-1.3%). Median drop gap 5.0d = twice weekly.'),
  ('80175','DIRECT_DANONE', ARRAY[956]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=956 DANONE SA, 148 live-linked products, R5,813/wk. Median drop gap 4.0d = twice weekly.'),
  ('10116','DIRECT_SIMBA', ARRAY[1970]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=1970 SIMBA (PTY) LTD, 220 live-linked products, R18,006/wk vs PM reference R18,092 (-0.5%). Median drop gap 7.0d = WEEKLY despite 0.75 drops/wk (skips ~1 Friday in 4); parity with the shipped Coca-Cola 10116 desk (median 7.0).'),
  ('80175','DIRECT_SIMBA', ARRAY[1337]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2. supplier_nr=1337 SIMBA (PTY) LTD, 177 live-linked products, R8,395/wk. Median drop gap 7.0d = weekly.')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  direct_supplier_nrs=EXCLUDED.direct_supplier_nrs, direct_cycle_weeks=EXCLUDED.direct_cycle_weeks,
  status=EXCLUDED.status, scope=EXCLUDED.scope, notes=EXCLUDED.notes, updated_at=now();

-- delivery_dows reflects the TRUE observed cadence per desk (see the cadence
-- table above): {2,4} where a second weekly truck genuinely runs, {5} where one
-- does not. order_cutoff_days inherits the table default (2, ENG-011).
INSERT INTO public.supplier_calendar (store_code, route_key, delivery_dows, effective_from, source_note)
VALUES
  ('10116','DIRECT_CLOVER', ARRAY[2,4]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=1610 -- Tue 7 / Thu 4 / Fri 1 qualifying drop days, median gap 5.0d. TWO real trucks a week, so both days encoded (the wave-1 single-day rule guards a once-weekly supplier from a phantom second truck; Clover''s second truck is real).'),
  ('80175','DIRECT_CLOVER', ARRAY[2,4]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=1286 -- Tue 8 / Thu 6, median gap 5.0d. Two real trucks a week.'),
  ('10116','DIRECT_DANONE', ARRAY[2,4]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=1257 -- Thu 7 / Tue 4 / Fri 1, median gap 5.0d. Two real trucks a week.'),
  ('80175','DIRECT_DANONE', ARRAY[2,4]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=956 -- Thu 8 / Tue 6 / Mon 1, median gap 4.0d. Two real trucks a week.'),
  ('10116','DIRECT_SIMBA', ARRAY[5]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=1970 -- Fri 5 / Sat 1, median gap 7.0d. Single day: one real truck a week, skipped ~1 Friday in 4.'),
  ('80175','DIRECT_SIMBA', ARRAY[5]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 2: receipt DOW fingerprint, 16wk, supplier_nr=1337 -- Fri 5 / Sat 1, median gap 7.0d. Single day, one real truck a week.')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  delivery_dows=EXCLUDED.delivery_dows, source_note=EXCLUDED.source_note, updated_at=now();

SELECT pg_notify('pgrst', 'reload schema');
