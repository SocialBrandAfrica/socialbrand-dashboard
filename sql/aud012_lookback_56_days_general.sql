-- AUD-012: interior-gap lookback set to 56 days, scope GENERAL (derivation in BUG-LOG AUD-012). forge_config is keyed (config_key, store_format), so the earlier value 14 is retired in place: named in notes, kept in aud012_a_l2_soh_gap_detect.sql.
-- Effect (read 14-10 ~21:2x SAST): the nightly feed check also reads FAILED for 80579 (2026-09-07, 2026-09-08) and 21355 (2026-09-21, 2026-10-11) while those holes are open; 19 holes remain on v_l2_soh_gap_worklist.
UPDATE public.forge_config
   SET value_num = 56,
       scope = 'GENERAL',
       effective_from = CURRENT_DATE,
       notes = 'AUD-012. Days back from store-local today in which an interior l2_soh_daily hole turns the nightly feed check red. 56 days; derivation in BUG-LOG AUD-012; older holes stay on v_l2_soh_gap_worklist. Retired value: 14 (scope DEMO_CALIBRATION, set by aud012_a_l2_soh_gap_detect).'
 WHERE config_key = 'l2_soh_gap_lookback_days' AND store_format = '*' AND retired_on IS NULL;