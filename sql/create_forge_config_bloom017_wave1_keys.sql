-- =============================================================================
-- create_forge_config_bloom017_wave1_keys.sql
-- SB-CC-BLOOM-017 Wave 1 config keys. R28 stamped. All DEMO_CALIBRATION, all
-- read at runtime -- never a literal in a function (R25).
--
-- effective_from dates differ ON PURPOSE and the difference is audited: the
-- session opened 2026-07-26 22:45 SAST and ran through midnight. The first two
-- keys applied 22:59-23:01 on the 26th; the second two applied 08:52 on the
-- 27th and were initially stamped a day early. Pieter caught it at 09:03 SAST
-- on the 27th; the clock was then verified three ways (local 2026-07-27
-- 09:03:13 +0200, UTC 07:03:13, DB now() AT TIME ZONE 'Africa/Johannesburg'
-- 2026-07-27 09:03:11) before correcting. Canon SS17 standing finding: a date
-- in a file is evidence only if the clock that wrote it was itself checked.
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES
 ('corrector_min_observable_share','*',0.5,'DEMO_CALIBRATION',DATE '2026-07-26',
  'Canon SS14 ADDENDUM v14 rule 1 (DEDUCTIVE, arithmetic). A stockout-corrected window rate publishes ONLY where the window keeps at least this share of its days OBSERVABLE (observable = window_days - presumed_stockout_days). Below the floor the corrected value is WITHHELD and the consumer widens or falls back to raw, carrying the reason (R29). Worked case: milk 10116/1674, a 14d window less 11 presumed-stockout days leaves 3 observable days (0.21 share) and 2,271 units over 3 days published 757.00 per day. A divisor that collapses does not measure demand, it measures its own collapse. Live effect at ship: 8,209 window-slots withheld group-wide.'),
 ('corrected_ros_cap_multiple','*',2.0,'DEMO_CALIBRATION',DATE '2026-07-26',
  'Canon SS14 addendum v2 guard 2 (Pieter ruling 2026-07-03), re-homed to the pantry by ADDENDUM v14 rule 1: the guard on a corrected rate lives in ONE place. A corrected window rate used by ANY consumer is capped at this multiple of the MATCHING raw window rate. The uncapped value stays stocked for lineage. rpc_bloom_order_recipe reading draw_corrected uncapped while refresh_l2_stock_band applied the cap WAS the defect -- 1,599 lines group-wide were above 2.0x their own raw at the recipe.'),
 ('regime_divergence_max','*',2.0,'DEMO_CALIBRATION',DATE '2026-07-27',
  'PM constraint 2026-07-27: a WIDENING fallback is accepted only while the wider window is REGIME-CLEAN. Test: split the wider window in half, take each half''s SALE-DAY MEAN (qty / days-with-a-sale -- the in-stock rate, robust to silence), divergence = max(old/new, new/old). CONTROLLED. Base rate measured on a CLEAN window (56d to 2026-07-03, entirely before the 4 July DC interruption), n = 5,194: p50 1.20-1.28, p90 1.67-1.87, p95 1.93-2.13, group p95 = 2.00. The contaminated-window figures are statistically indistinguishable, which is the finding -- the test is silence-robust, so a 19-day outage did not move its base rate. REJECTED ALTERNATIVE, kept as a warning: longest-silence-run is CONFOUNDED WITH VELOCITY (median longest run 18-22 days, >=21d on 40% of lines) and detects slow movers, not regimes. SCOPE: gates BORROWING a wider window only, NEVER a line''s own designated tier window -- gating a line''s own window would withhold exactly the lines whose demand is changing (proven: Babysoft 80175/822145 diverges 3.42 BECAUSE its promotion started). ANCHOR IS NOT A MECHANISM (Pieter ruling 2026-07-27): the 3 July anchor was a one-off validation, not a standing or moving window; no object references it; store #6 re-calibrates on ITS OWN everyday base rate (R25), never on our July.'),
 ('promo_uplift_cap','*',5.0,'DEMO_CALIBRATION',DATE '2026-07-27',
  'Canon SS14 promo_uplift ladder cap, read as config so the at-cap test is never a literal. Measured 2026-07-27: 677 promo-pantry rows sit exactly at this cap window-blind; 121 of them are inside a live buy-in window and therefore actually lift a band (14.8% of 817 lifted lines); 556 are latent. A band lifted by a CAPPED uplift is marked provisional_capped_uplift -- the true uplift is unknown and at least the cap, so the lifted band is a FLOOR on that line, not a measurement. Per-desk at-cap share to watch: 80175 DC_AMBIENT highest.')
ON CONFLICT (config_key, store_format) DO UPDATE
  SET value_num = EXCLUDED.value_num,
      scope = EXCLUDED.scope,
      effective_from = EXCLUDED.effective_from,
      notes = EXCLUDED.notes;
