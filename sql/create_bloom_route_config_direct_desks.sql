-- create_bloom_route_config_direct_desks.sql
-- SB-CC-BLOOM-009 -- direct order desks beside the DC, pulled forward per
-- Pieter's build order (WALK-FINDINGS 2026-07-12, freeze lifted). Extends
-- `bloom_route_config` (already home to DIRECT_BEER's merch_group_nrs/
-- excluded_supplier_types) with the columns a DIRECT_<brand> desk needs --
-- an ALTER, not a new table (R21, same route-config precedent as beer).
--
-- SUPPLIER IDENTITY -- brand != supplier_nr. Checked live before building:
-- every named brand in the brief has SEVERAL active, currently-linked
-- supplier_nr rows at a store (e.g. 10116 CLOVER: 1610/704 products,
-- 1611/614, 3279/55, 2244/55, 118/51 -- Dairybelle/Ambient/Eskort
-- sub-accounts, not noise). `direct_supplier_nrs` is therefore a curated
-- array (behaviour-led product MEMBERSHIP still comes from each product's
-- own active non-Z sigma_supplier_link row -- never a hardcoded product
-- list -- but which supplier_nr(s) constitute one brand desk is a real,
-- one-time human-reviewable mapping, same discipline as bloom_dc_config's
-- own RULED status).
--
-- CADENCE METHOD, R22-VALIDATED against the brief's own PM reference
-- (10116, 8wk): distinct sigma_movements receipt dates
-- (movement_type='R', movement_process='W') for the desk's supplier_nr(s),
-- >=3 lines/day noise floor, /8 weeks. Using only the SINGLE dominant
-- (highest live-linked-product-count) supplier_nr per brand reproduced
-- PM's reference almost exactly with ZERO parameter tuning: Danone 1.50
-- (PM 1.5, exact) * Coca-Cola 1.00 (PM 1.0, exact) * National Brands 0.50
-- (PM 0.5, exact) * Clover 1.50 (PM 1.6, close -- 1610+1611 union, same
-- delivery days, no change) * Simba 0.88 (PM 0.9, rounds to match) *
-- Mondelez 0.63 via supplier_nr=950 "SUPER GROUP AFRICA - MONDELEZ" (PM
-- 0.6, close -- the obvious supplier_nr=1586 "MONDELEZ" had ZERO receipts
-- in the window, confirming 950 is the real receiving supplier, not a
-- guess). sigma_grv does not exist as a separate table in this schema --
-- `sigma_movements.supplier_nr` (100% populated on R/W rows) is the
-- L1 receipt-supplier fact used here directly; the brief's own named
-- "sigma_grv cut" debt is therefore effectively already available via this
-- table, not a blocker.
--
-- direct_cycle_weeks: canon item 3's own rule applied literally
-- (drops_per_wk >= 1 -> weekly, else fortnightly) -- Coca-Cola 10116
-- (1.00) = weekly; Coca-Cola 80175 (0.875, own supplier_nr=275, distinct
-- from 10116's 499 -- sigma_supplier_master is store-scoped) = fortnightly.
--
-- Ledger route: DIRECT_<brand> desks read the EXISTING generic 'DIRECT'
-- weekly ledger row (already seeded, e.g. 10116 R366,210/wk) -- shared
-- across all direct-brand desks at a store, same key the PM/CC "DIRECT vs
-- DIRECT_BEER look like the same money" hygiene flag already refers to.
-- No new budget rows needed for this brief; Fit-to-Budget on a direct desk
-- competes for the SAME direct pool as every other brand's desk at that
-- store, by design (one direct budget, many supplier desks drawing on it).
--
-- Priority build order per the brief (item 6): Coca-Cola first (10116 +
-- 80175, "SPAR pair carries ~85% of the direct rand"). Remaining five
-- brands x 2 stores + the other 3 desk-carrying stores follow in later
-- passes, same methodology, each R22'd before it ships (item 5).
-- =============================================================================

ALTER TABLE public.bloom_route_config
  ADD COLUMN IF NOT EXISTS direct_supplier_nrs bigint[],
  ADD COLUMN IF NOT EXISTS direct_cycle_weeks smallint,
  ADD COLUMN IF NOT EXISTS direct_min_order_value numeric DEFAULT 5000;

-- merch_group_nrs/excluded_supplier_types are DIRECT_BEER-only concepts
-- (NOT NULL from that route's own migration) -- a DIRECT_<brand> desk uses
-- direct_supplier_nrs instead and legitimately leaves these NULL.
ALTER TABLE public.bloom_route_config ALTER COLUMN merch_group_nrs DROP NOT NULL;
ALTER TABLE public.bloom_route_config ALTER COLUMN excluded_supplier_types DROP NOT NULL;

-- supplier_calendar carried a CHECK pinning route_key to the 3 known route
-- names (pre-BLOOM-009) -- relaxed to also accept DIRECT_<brand> desks,
-- never a free-for-all (still anchors the 3 named routes literally, only
-- the new class is pattern-matched).
ALTER TABLE public.supplier_calendar DROP CONSTRAINT IF EXISTS supplier_calendar_route_key_check;
ALTER TABLE public.supplier_calendar ADD CONSTRAINT supplier_calendar_route_key_check
  CHECK (route_key IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER') OR route_key LIKE 'DIRECT\_%' ESCAPE '\');

COMMENT ON COLUMN public.bloom_route_config.direct_supplier_nrs IS
  'DIRECT_<brand> desks only: the store-scoped supplier_nr(s) (sigma_supplier_master)
   that constitute this brand -- curated, R22-checked against receipt cadence, NOT
   a hardcoded PRODUCT list (product membership stays behaviour-led via each
   product''s own active non-Z sigma_supplier_link row). SB-CC-BLOOM-009.';
COMMENT ON COLUMN public.bloom_route_config.direct_cycle_weeks IS
  'DIRECT_<brand> desks: 1 (weekly) when the derived cadence is >=1 drop/wk,
   else 2 (fortnightly) -- canon v9 item 7 rule 3, applied literally.';
COMMENT ON COLUMN public.bloom_route_config.direct_min_order_value IS
  'DIRECT_<brand> desks: below this rand value the cycle''s order accumulates
   to the next cycle rather than shipping -- shown on the desk, never silently
   skipped (canon v9 item 7 rule 4). DEMO_CALIBRATION default R5,000.';

INSERT INTO public.bloom_route_config
  (store_code, route_key, direct_supplier_nrs, direct_cycle_weeks, status, scope, effective_from, notes)
VALUES
  ('10116','DIRECT_COCACOLA', ARRAY[499]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 priority 1. supplier_nr=499 COCA-COLA BEVERAGES SA, 300 live-linked products, cadence 1.00 drops/wk R22-matches PM reference (1.0) exactly, 8wk window.'),
  ('80175','DIRECT_COCACOLA', ARRAY[275]::bigint[], 2, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 priority 1, second store per brief item 6. supplier_nr=275 COCA-COLA BEVERAGES SA (store-scoped, distinct from 10116''s 499), 369 live-linked products, cadence 0.875 drops/wk -> fortnightly per canon v9 item 7 rule 3 (<1/wk).')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  direct_supplier_nrs=EXCLUDED.direct_supplier_nrs, direct_cycle_weeks=EXCLUDED.direct_cycle_weeks,
  status=EXCLUDED.status, scope=EXCLUDED.scope, notes=EXCLUDED.notes, updated_at=now();

-- Single dominant weekday, NOT the full observed set: rpc_bloom_next_
-- deliveries walks delivery_dows forward and returns the first TWO
-- matching calendar days as "delivery" + "following" -- encoding both
-- Thu+Fri as candidates for a genuinely weekly (one truck/week) supplier
-- collapses the lead to 1 day (back-to-back Thu/Fri) instead of the real
-- ~7-day gap, starving the band target. Caught live before ship: an
-- initial {4,5} config returned delivery=Thu/following=Fri, lead=1, and
-- the recipe's minimum-mode band target came out far below the desk's own
-- demonstrated weekly demand -- fixed to the single most-frequent day.
INSERT INTO public.supplier_calendar (store_code, route_key, delivery_dows, effective_from, source_note)
VALUES
  ('10116','DIRECT_COCACOLA', ARRAY[5]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009: receipt DOW fingerprint, 8wk trailing, supplier_nr=499 -- Fri dominant (4/8 qualifying drop days vs Thu 3/8, Mon 1/8) -- single day per week, not both, so next-deliveries reflects the true ~weekly gap.'),
  ('80175','DIRECT_COCACOLA', ARRAY[4]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009: receipt DOW fingerprint, 8wk trailing, supplier_nr=275 -- Thu dominant (5/7 qualifying drop days vs Fri 2/7) -- single day, fortnightly cycle applied at desk level (direct_cycle_weeks=2).')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  delivery_dows=EXCLUDED.delivery_dows, source_note=EXCLUDED.source_note, updated_at=now();

SELECT pg_notify('pgrst', 'reload schema');
