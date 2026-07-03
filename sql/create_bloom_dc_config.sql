-- =============================================================================
-- create_bloom_dc_config.sql
-- SB-CC-BLOOM-001. L3 recipe config per CLEANUP-ENGINE-CANON section 14
-- ("L3 recipe ORDER_DC ... per store from config -- DEMO_CALIBRATION
-- constants"). R28: every row carries provenance (effective_from, scope,
-- confirmed_by/confirmed_at) -- never a silent guess promoted to config.
-- =============================================================================
-- WHAT THIS HOLDS: the one genuinely per-store variable in the ORDER_DC
-- recipe -- the cycle department set. Everything else canon names as a
-- recipe constant (tier targets 14/12/14, BOR trigger <3, uplift cap 5.0,
-- default 2.00) is GLOBAL DEMO_CALIBRATION, not per-store, so it is not
-- duplicated five times here; it lives in the recipe RPC itself, one place,
-- with its own R28 stamp.
--
-- DEPARTMENT SETS -- the method (R21, formula not product): match the L2
-- engine's DC-linked NORMAL pool against each store's OWN department NAMES
-- (department_nr is proven NOT portable, even within the same store format
-- -- verified 2026-07-02: 80176/80579 carry a deposit dept "BOTTLES" at
-- nr=19 that 21355 lacks entirely). Two store formats exist on this platform:
--   SPAR (10116, 80175) -- full supermarket taxonomy: GROCERIES FOODS,
--     GROCERIES HOUSE HOLD, HEALTH & BEAUTY, CIGARETTES, COLD REFRESHMENTS,
--     WINE, NON FOOD/GENERAL MERCH, PERISHABLES, FROZENS, SWEETS & SNACKS,
--     DC - SPECIAL PROMOTIONS. 10116's taxonomy is BYTE-IDENTICAL to 80175's
--     (27/27 department names AND numbers match) -- inherited directly,
--     Pieter-ratified 2026-07-02 (HANDOVER-CURRENT "DEPT SETS RULED x5").
--     BOTH run a fresh/production cycle separately (bakery/butchery/produce/
--     HMR exist at these stores; out of scope for v1, see brief s9).
--   TOPS (21355, 80176, 80579) -- liquor/bottle-store taxonomy, categorically
--     different: no groceries/health&beauty/perishables/produce/bakery/
--     butchery/HMR split exists at all. Proposed by CC from data (department-
--     name pattern + 91d trading-activity sanity check), CONFIRMED BY PIETER
--     2026-07-02 (HANDOVER-CURRENT): APERETIF, BEER, COOLERS & FABS, CIDERS,
--     SNACKS, CIGARETTES, COLD REFRESHMENTS, WINE, NON FOODS, LIQUERS,
--     COCKTAILS, FROZENS, SPIRITS, plus the DC-promo dept. Excluded: AIRTIME,
--     FRONT END PACKAGING, DORMANT PRODUCTS (verified 0% of it sold anything
--     in 91d at all three TOPS stores; its one sub-department is literally
--     named DORMANT ITEMS -- genuinely dead, not a mislabelled live category),
--     the deposit dept where present (BOTTLES/BOTTLE CRATES -- same World-2
--     DEPOSIT/RETURNABLE class canon already carves out elsewhere, subdept
--     names match canon's own deposit examples verbatim: BOTTLE POSITIVE
--     CHARGE, BOTTLES NEGATIVE REFUND, BOTTLE CHARGE, BOTTLE RETURN CREDIT),
--     NON SCAN, ONLINE*, SPAR MOBILE, EXPENSES, Sales Difference, junk
--     placeholder depts. TOPS runs ONE cycle only, no fresh/production leg
--     (Pieter-confirmed: neither format has those departments at all).
--     department_nr for the trading categories is consistent 1-13 across all
--     three TOPS stores (verified); only their extra junk/deposit dept
--     numbers differ, and those are excluded regardless.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP TABLE IF EXISTS public.bloom_dc_config CASCADE;

CREATE TABLE public.bloom_dc_config (
  store_code               text NOT NULL PRIMARY KEY,
  format_group              text NOT NULL,                 -- 'SPAR' | 'TOPS' (DF-1 format grouping, canon s9)
  dc_cycle_dept_nrs         smallint[] NOT NULL,            -- the ONE ruled DC cycle for this store
  fresh_cycle_applicable    boolean NOT NULL DEFAULT false, -- bakery/butchery/produce/HMR cycle exists (SPAR only); out of scope v1
  status                    text NOT NULL DEFAULT 'PROPOSED' CHECK (status IN ('PROPOSED','RULED')),
  scope                     text NOT NULL DEFAULT 'DEMO_CALIBRATION' CHECK (scope IN ('DEMO_CALIBRATION','GENERAL')),
  effective_from            date NOT NULL,
  confirmed_by              text,                           -- NULL while PROPOSED
  confirmed_at              timestamptz,
  notes                     text,
  updated_at                timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.bloom_dc_config TO anon, authenticated;

INSERT INTO public.bloom_dc_config
  (store_code, format_group, dc_cycle_dept_nrs, fresh_cycle_applicable, status, effective_from, confirmed_by, confirmed_at, notes)
VALUES
  ('80175', 'SPAR', ARRAY[9,10,11,12,13,14,15,16,17,18,29]::smallint[], true,
   'RULED', DATE '2026-07-02', 'Pieter', now(),
   'Original ruled set. Validated live: non-promo order R173,977.97 vs StockFlow order 2229 R173,912.32, 0.04% apart.'),
  ('10116', 'SPAR', ARRAY[9,10,11,12,13,14,15,16,17,18,29]::smallint[], true,
   'RULED', DATE '2026-07-02', 'Pieter', now(),
   'Inherited from 80175 -- department taxonomy byte-identical (27/27 names AND numbers match). First 10116 test order to go past Pieter''s eyes before trusted unattended.'),
  ('21355', 'TOPS', ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,29]::smallint[], false,
   'RULED', DATE '2026-07-02', 'Pieter', now(),
   'CC-proposed from data (department-name pattern + 91d trading-activity check on DORMANT PRODUCTS), Pieter-confirmed as proposed. No dept 19 at this store (unlike 80176/80579''s deposit dept) -- nothing to exclude there.'),
  ('80176', 'TOPS', ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,29]::smallint[], false,
   'RULED', DATE '2026-07-02', 'Pieter', now(),
   'CC-proposed, Pieter-confirmed. Dept 19 (BOTTLES, deposit) excluded -- subdept names BOTTLE POSITIVE CHARGE / BOTTLES NEGATIVE REFUND match canon''s own DEPOSIT/RETURNABLE examples verbatim.'),
  ('80579', 'TOPS', ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,29]::smallint[], false,
   'RULED', DATE '2026-07-02', 'Pieter', now(),
   'CC-proposed, Pieter-confirmed. Dept 19 (BOTTLE, CRATES., deposit) excluded -- same World-2 DEPOSIT/RETURNABLE class.');
