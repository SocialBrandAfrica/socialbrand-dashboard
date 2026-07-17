-- create_bloom_route_config_cadence_rederive.sql
-- ENG-025 step 1 of 2: FIX THE ROWS. PM ruling 2026-07-17 (R28, effective
-- 2026-07-17): "Fix the ROWS before the COLUMN goes live." This file does the
-- rows ONLY. `direct_cycle_weeks` stays dead until step 2, deliberately.
--
-- WHY THE ROWS ARE WRONG. The BLOOM-009 desks derived cadence from
-- DROPS-PER-WEEK (receipt days / 8 weeks). That statistic is pulled under 1 by
-- a single missed or skipped drop, and it then reads "fortnightly" off a
-- supplier that delivers every 7 days like clockwork. PM ruled the correct
-- statistic is the MEDIAN DROP GAP, on a 182-day window carrying its
-- gaps_observed -- a 28-day window read Mondelez as weekly off two
-- observations, which is not evidence.
--
-- RE-DERIVED LIVE, 182d, median gap, >=3 lines/day noise floor (R21 --
-- behaviour-led, never a name or a typed-in guess):
--   10116 DIRECT_COCACOLA  median 7.0  (23 gaps)  weekly      row already 1, ok
--   80175 DIRECT_COCACOLA  median 7.0  (22 gaps)  weekly      row said 2  <-- WRONG
--   10116 DIRECT_CLOVER    median 4.0  (44 gaps)  weekly      row already 1, ok
--   80175 DIRECT_CLOVER    median 5.0  (44 gaps)  weekly      row already 1, ok
--   10116 DIRECT_DANONE    median 5.0  (35 gaps)  weekly      row already 1, ok
--   80175 DIRECT_DANONE    median 4.0  (49 gaps)  weekly      row already 1, ok
--   10116 DIRECT_SIMBA     median 7.0  (18 gaps)  weekly      row already 1, ok
--   80175 DIRECT_SIMBA     median 7.0  (18 gaps)  weekly      row already 1, ok
--   21355 DIRECT_BEER      median 6.0  (27 gaps)  weekly      row was NULL
--   80176 DIRECT_BEER      median 7.0  (21 gaps)  weekly      row was NULL
--   80579 DIRECT_BEER      median 4.0  (11 gaps)  weekly      row was NULL
--
-- THE ONE THAT MATTERED: 80175 DIRECT_COCACOLA carried `fortnightly` against a
-- real 7.0-day median gap on 22 observations (its own drops-per-week read
-- 0.875, just under the threshold). It orders CORRECTLY today only because the
-- column is dead. Making the column live before this fix would have doubled
-- that desk's cover overnight -- which is precisely why the ruling sequences
-- rows first. The accident was load-bearing; this removes the need for it.
--
-- SAFETY: this file is a NO-OP on behaviour. `direct_cycle_weeks` is written
-- but never read by any live object (that is ENG-025 itself). Every suggested
-- quantity on every desk is byte-identical before and after. The R22 zero-delta
-- proof belongs to step 2, when the column actually goes live -- and by then
-- every live desk reads 1 (weekly), so step 2 is a no-op too, by construction.
--
-- FORTNIGHTLY IS NOT CLOSED HERE. Mondelez, National Brands and Coca-Cola 21355
-- are genuinely fortnightly and stay HELD behind the `supplier_calendar` grain
-- debt: `delivery_dows` carries day-of-week only and cannot express alternate
-- weeks, so there is no way to say WHICH week is a delivery week. CC proposes
-- the grain, PM signs before it lands (PM ruling). They are deliberately NOT
-- seeded at a weekly number to close a ticket.
-- =============================================================================

BEGIN;

-- 80175 Coca-Cola: fortnightly -> weekly. The row fix that matters.
UPDATE public.bloom_route_config
   SET direct_cycle_weeks = 1,
       notes = COALESCE(notes,'') || ' | ENG-025 2026-07-17: direct_cycle_weeks 2->1. Re-derived from receipts, 182d: median drop gap 7.0 over 22 gaps = weekly. The stored 2 came from the drops-per-week method (0.875/wk, just under the >=1 threshold) which a single skipped drop distorts; the median gap is the ruled statistic (PM, R28). Inert at write time -- the column is not yet read.',
       updated_at = now()
 WHERE store_code = '80175' AND route_key = 'DIRECT_COCACOLA';

-- DIRECT_BEER predates the column and never carried a cycle at all.
-- All three re-derive weekly. NULL is not "weekly by luck" -- state it.
UPDATE public.bloom_route_config
   SET direct_cycle_weeks = 1,
       notes = COALESCE(notes,'') || ' | ENG-025 2026-07-17: direct_cycle_weeks NULL->1. Predates the column (BLOOM-003 Ship 1). Re-derived from receipts, 182d median drop gap: 21355 6.0/27 gaps, 80176 7.0/21 gaps, 80579 4.0/11 gaps -- all weekly. Stated rather than left NULL so the column is never read as an absence.',
       updated_at = now()
 WHERE route_key = 'DIRECT_BEER' AND direct_cycle_weeks IS NULL;

-- Post-condition (R22, no silent empties): every RULED direct desk must now
-- carry a cycle, and on today's evidence every one of them is weekly. If a
-- fortnightly desk ever lands before the grain debt is paid, this fails loudly.
DO $$
DECLARE v_null int; v_fortnightly int;
BEGIN
  SELECT COUNT(*) INTO v_null
    FROM public.bloom_route_config
   WHERE status='RULED' AND route_key LIKE 'DIRECT%' AND direct_cycle_weeks IS NULL;
  IF v_null > 0 THEN
    RAISE EXCEPTION 'ENG-025 post-condition failed: % RULED direct desk(s) still carry a NULL direct_cycle_weeks', v_null;
  END IF;

  SELECT COUNT(*) INTO v_fortnightly
    FROM public.bloom_route_config
   WHERE status='RULED' AND route_key LIKE 'DIRECT%' AND direct_cycle_weeks <> 1;
  IF v_fortnightly > 0 THEN
    RAISE EXCEPTION 'ENG-025 post-condition failed: % direct desk(s) carry a non-weekly cycle, but supplier_calendar cannot express alternate weeks yet (the grain debt). A fortnightly desk must not go live before that lands.', v_fortnightly;
  END IF;

  RAISE NOTICE 'ENG-025 rows OK: every RULED direct desk carries direct_cycle_weeks=1, re-derived from its own receipts (182d median gap).';
END $$;

COMMIT;
