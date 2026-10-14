-- AUD-012 (PM section 40, 14-10-2026 21:30): the interior-gap lookback is 56 days, the longest rate window the order reads (RULED-ALREADY R6: "The longest rate window is 56 days"). Scope GENERAL. The invented 14 (DEMO_CALIBRATION, set by aud012_a_l2_soh_gap_detect) is retired.
-- forge_config's primary key is (config_key, store_format), so the retirement is recorded in place: the old value and its retirement are named in notes (R28), and this file keeps the 14.
-- Effect (read 14-10 ~21:2x SAST): the nightly feed check also reads red for 80579 (2026-09-07, 2026-09-08) and 21355 (2026-09-21, 2026-10-11) while those holes are open: a red check is true while a hole is open. 19 holes in total remain on v_l2_soh_gap_worklist.
UPDATE public.forge_config
   SET value_num = 56,
       scope = 'GENERAL',
       effective_from = CURRENT_DATE,
       notes = 'AUD-012. Days back from store-local today in which an interior l2_soh_daily hole turns the nightly feed check red. 56 = the longest rate window the order reads (RULED-ALREADY R6, PM section 40, 14-10-2026); older holes stay on v_l2_soh_gap_worklist. RETIRED 14-10-2026: the first value 14, invented, scope DEMO_CALIBRATION, set by aud012_a_l2_soh_gap_detect.'
 WHERE config_key = 'l2_soh_gap_lookback_days' AND store_format = '*' AND retired_on IS NULL;