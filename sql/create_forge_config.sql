-- =============================================================================
-- create_forge_config.sql
-- Forge toolkit (2026-07-10 build) config table. Built live, never committed
-- to the repo until this pass (HANDOVER-CURRENT item 10, "Forge fold-in" debt)
-- -- folded in here as repo-hygiene groundwork while other Forge objects were
-- being touched (ENG-006, 2026-07-11).
-- =============================================================================
-- Store-format-aware count-cycle constants (canon §15: SPAR gets a full-store
-- pass inside 12 weeks, TOPS counts fewer articles more often at 4 weeks) plus
-- the stratum-share / near-certainty-belt constants rpc_forge_count_list and
-- rpc_forge_lines read. `store_format='*'` is the fallback row a store-
-- specific lookup falls through to (see rpc_forge_count_list's `cfg` CTE:
-- `ORDER BY f.store_format DESC LIMIT 1`, so a named format outranks '*').
-- All rows scope=DEMO_CALIBRATION -- interim levers, not formula, same
-- convention as bloom_dc_config's p_days_cover default (SB-CC-BLOOM-002).
-- =============================================================================

DROP TABLE IF EXISTS public.forge_config CASCADE;

CREATE TABLE public.forge_config (
  config_key      text NOT NULL,
  store_format    text NOT NULL DEFAULT '*',
  value_num       numeric NOT NULL,
  scope           text NOT NULL DEFAULT 'DEMO_CALIBRATION',
  effective_from  date NOT NULL DEFAULT CURRENT_DATE,
  retired_on      date,
  notes           text,
  PRIMARY KEY (config_key, store_format)
);

GRANT SELECT ON public.forge_config TO anon, authenticated;

INSERT INTO public.forge_config (config_key, store_format, value_num, effective_from, notes) VALUES
  ('count_cycle_weeks',      'SPAR', 12, '2026-07-10', 'canon §15: full-store pass inside 12 weeks at SPAR format'),
  ('count_cycle_weeks',      'TOPS', 4,  '2026-07-10', 'canon §15: fewer articles counted more often'),
  ('trading_days_per_week',  '*',    6,  '2026-07-10', 'budget divisor: cycle_weeks x this'),
  ('inactive_window_days',   '*',    91, '2026-07-10', 'stratum 3: no sale in this window = inactive'),
  ('inactive_slice_pct',     '*',    15, '2026-07-10', 'stratum 3 share of daily budget'),
  ('zero_audit_pct',         '*',    5,  '2026-07-10', 'stratum 5 share of daily budget, soh=0 random slice'),
  ('tlx_soh_belt',           '*',    24, '2026-07-10', 'canon §8.12#3 near-certainty belt: |soh| < 24 for TLX'),
  -- SB-CC-BLOOM-014 (canon §14 v12): the tail keep-or-delist cover threshold
  -- rpc_bloom_order_recipe reads. A SLOW line's single pack must turn within
  -- this many days to earn the one-pack minimum; slower = worklist, not order.
  ('relevant_min_cover_days','*',    60, '2026-07-20', 'canon §14 v12: SLOW one-pack minimum only where pack_size/rhythm_adjusted_demand <= this; Pieter tunes')
ON CONFLICT (config_key, store_format) DO NOTHING;
