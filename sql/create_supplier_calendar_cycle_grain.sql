-- SB-CC / ENG-025 : the fortnightly grain on supplier_calendar + its DEMO_CALIBRATION constants.
-- canon CLEANUP-ENGINE-CANON section 14 v9 items 7e / 7f / 7g. Incremental over create_supplier_calendar.sql
-- (same pattern as create_supplier_calendar_promo_buyin.sql). Applied 2026-07-18, migrations
-- cadence_law_01_grain_supplier_calendar_cycle + cadence_law_02b/02c_forge_config_cadence_keys
-- + cadence_law_06_retire_direct_cycle_weeks.
--
-- cycle_weeks expresses weekly(1)/fortnightly(2)/n-weekly. A week is a delivery week when it sits a
-- whole multiple of cycle_weeks from cycle_anchor_week_start. At cycle_weeks=1 behaviour is
-- byte-identical to the pre-grain table -- that identity IS the zero-delta R22 proof (ENG-025 step 3).
-- cycle_anchor_week_start is the BUDGET-WEEK START (Saturday, budget_week_start_dow) of the qualifying
-- drop, never a raw drop date (canon 7e correction 1: a Wednesday anchor makes both Saturdays either
-- side qualify and a fortnightly desk orders weekly, silently). Both derive from the ledger, never
-- typed in (R21) -- see rpc_derive_supplier_cadence.

ALTER TABLE public.supplier_calendar
  ADD COLUMN IF NOT EXISTS cycle_weeks smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS cycle_anchor_week_start date;

-- An n-weekly cycle with a NULL anchor evaluates NULL, qualifies for no week, and the desk silently
-- never orders (a silent empty, canon section 8.6 guard 4). Forbid it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.supplier_calendar'::regclass
      AND conname='supplier_calendar_cycle_anchor_ck'
  ) THEN
    ALTER TABLE public.supplier_calendar
      ADD CONSTRAINT supplier_calendar_cycle_anchor_ck
      CHECK (cycle_weeks = 1 OR cycle_anchor_week_start IS NOT NULL);
  END IF;
END $$;

COMMENT ON COLUMN public.supplier_calendar.cycle_weeks IS
  'Delivery cadence in weeks (1=weekly, 2=fortnightly, n=n-weekly). A week is a delivery week when it sits a whole multiple of cycle_weeks from cycle_anchor_week_start. cycle_weeks=1 is byte-identical to pre-grain behaviour. DEMO_CALIBRATION per desk, derived by rpc_derive_supplier_cadence (canon section 14 v9 7e/7f/7g).';
COMMENT ON COLUMN public.supplier_calendar.cycle_anchor_week_start IS
  'Budget-week START (Saturday, budget_week_start_dow) of the most recent qualifying drop -- NOT a raw drop date (canon 7e correction 1). Required whenever cycle_weeks<>1. Derived from the R/W ledger, never typed in (R21).';

-- ENG-025 / canon 7e: the calendar OWNS cadence. bloom_route_config.direct_cycle_weeks is RETIRED
-- with lineage (R28), never dropped, never read.
COMMENT ON COLUMN public.bloom_route_config.direct_cycle_weeks IS
  'RETIRED 2026-07-18 (R28), superseded_by supplier_calendar.cycle_weeks. The calendar owns cadence (canon section 14 v9 item 7e). Never read; retained for lineage, never dropped. Do not re-wire -- cycle_weeks lives on supplier_calendar, derived by rpc_derive_supplier_cadence.';

-- Cadence-derivation DEMO_CALIBRATION constants. forge_config is the generic key/value registry
-- (config_key, store_format, value_num, scope, ...). store_format='*' = all formats; store #6
-- re-derives its calendar rows but inherits these constants.
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
  ('cadence_window_days',        '*', 182,  'DEMO_CALIBRATION', '2026-07-18', 'canon 7d: minimum window to observe gaps; a 28d window misread Mondelez as weekly'),
  ('drop_floor_ratio',          '*', 0.25, 'DEMO_CALIBRATION', '2026-07-18', 'canon 7g: a receipt DAY is a DROP when cost_value >= this x that supplier own median receipt-day cost. Value-relative, not a flat line count'),
  ('regime_outlier_gap_multiple','*', 3,    'DEMO_CALIBRATION', '2026-07-18', 'canon 7g: a gap beyond this x the median is a supply interruption -- excluded from the median and NAMED, never averaged in'),
  ('dow_confidence_min',        '*', 60,   'DEMO_CALIBRATION', '2026-07-18', 'canon 7i: below this modal_dow_pct WITHIN the current regime the route has no stable delivery day and says so'),
  ('dow_tolerance_days',        '*', 1,    'DEMO_CALIBRATION', '2026-07-18', 'canon 7i: +/-1-day adjacent scatter is logistics/posting noise, one delivery day, not a second'),
  ('dow_regime_lookback_days',  '*', 84,   'DEMO_CALIBRATION', '2026-07-18', 'canon 7i: derive the delivery dow from the CURRENT regime (trailing 12wk), not the whole window, so a dow-only day-move (80175 Coca-Cola Tue->Thu, no gap change) is not averaged across two regimes')
ON CONFLICT (config_key, store_format) DO NOTHING;
