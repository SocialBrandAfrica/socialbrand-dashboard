-- =============================================================================
-- bloom_route_config -- SB-CC-BLOOM-003 Ship 1. Config for non-DC supply routes
-- (R25: config-only, no hardcoded supplier names/numbers in code; R28: stamped).
--
-- The route is defined by PRODUCT classification (merch_group_nr, native Sigma,
-- portable across stores -- confirmed byte-identical merch group numbers/names
-- at all 3 TOPS stores 2026-07-07) plus a supplier_type EXCLUSION (never DC).
-- Origin is read from behaviour (the supplier_link's own type field, Sigma-
-- native DBLFTS.TYP) -- never a supplier name or account (R21/R25; verified
-- 2026-07-07 that the "SAB" account is NOT a stable identifier: supplier_nr 555
-- at 21355/80579, 590 at 80176, and 21355 runs it under TWO parallel accounts
-- ("SAB - DUMMY ACCOUNT" 555 + "SAB BREWERIES" 1392)).
--
-- Note: dept 2 (beer) and dept 4 (cider, merch_group 401) are ALREADY inside
-- bloom_dc_config.dc_cycle_dept_nrs for the TOPS format -- they are invisible
-- to rpc_bloom_order_dc today only because its pool join requires
-- supplier_type='Z'. This config scopes the DIRECT (non-DC) complement of the
-- same commodity class, not a new department.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.bloom_route_config (
  store_code          text NOT NULL,
  route_key           text NOT NULL,             -- e.g. 'DIRECT_BEER'
  merch_group_nrs     integer[] NOT NULL,          -- Sigma-native, product-side classification
  excluded_supplier_types text[] NOT NULL DEFAULT ARRAY['Z'], -- never DC
  status              text NOT NULL DEFAULT 'RULED',
  scope               text NOT NULL DEFAULT 'DEMO_CALIBRATION', -- R28
  effective_from      date NOT NULL,
  confirmed_by        text,
  confirmed_at        timestamptz,
  notes               text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, route_key)
);

COMMENT ON TABLE public.bloom_route_config IS
  'R25/R28 config for Bloom non-DC supply routes (SB-CC-BLOOM-003). Route
   membership = product merch_group_nr (native Sigma, portable) AND supplier
   link type NOT IN excluded_supplier_types. Never a supplier name/account.';

INSERT INTO public.bloom_route_config
  (store_code, route_key, merch_group_nrs, effective_from, confirmed_by, confirmed_at, notes)
VALUES
  ('21355', 'DIRECT_BEER', ARRAY[201,202,203,204,205,401], '2026-07-07', 'PM (Cowork)', now(),
   'SB-CC-BLOOM-003 Ship 1. Merch groups: 201 BEER QUARTS, 202 BEER IMPORT/MICRO, 203 BEER MAINSTREAM, 204 BEER NON ALCOHOLIC, 205 BEER PREMIUM, 401 CIDERS ALL. Excludes non-scan 2502/2504 (not orderable stock). Confirmed via sigma_movements 2026-07-07: DC receipt cadence median 4d vs direct-beer median 8d (SAB-equivalent) -- distinct behavioural signatures.'),
  ('80176', 'DIRECT_BEER', ARRAY[201,202,203,204,205,401], '2026-07-07', 'PM (Cowork)', now(),
   'SB-CC-BLOOM-003 Ship 1. Same merch group set (byte-identical across all 3 TOPS stores). Direct-beer receipt cadence median 7d confirmed via sigma_movements.'),
  ('80579', 'DIRECT_BEER', ARRAY[201,202,203,204,205,401], '2026-07-07', 'PM (Cowork)', now(),
   'SB-CC-BLOOM-003 Ship 1. Same merch group set. Direct-beer supplier link (SAB-equivalent, supplier_nr 555) last received 2026-03-27 -- door closed, over 3 months dark, exactly the recovery target this route exists to reopen (SB-ORD-DESK-001).')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  merch_group_nrs = EXCLUDED.merch_group_nrs,
  notes = EXCLUDED.notes,
  updated_at = now();

GRANT SELECT ON public.bloom_route_config TO anon, authenticated;
