-- =============================================================================
-- create_check_l1_feed_freshness.sql
-- Deployed 2026-06-11 08:2x SAST via Supabase MCP (migration
-- create_check_l1_feed_freshness). Kept here as canonical source.
-- =============================================================================
-- SB-CC-DASH-TRUTH-001 P0.1 auditability fix (R22):
--   80175's sigma_sales went dark on 06-09 and 06-10 behind green nightly
--   summary rows -- no alarm existed. This sentinel makes a dark feed surface
--   in push_log every night.
--
-- Rule per store:
--   - sigma_sales max(sale_date)      must not lag daily_snapshots max
--     (the TAC channel proves the store traded and pushed that day)
--   - sigma_movements max(movement_date) must not lag daily_snapshots max
--   - l2_soh_daily must hold a CURRENT_DATE snapshot (truthfully red until
--     the extractor chain goes green -- that gap is real)
--
-- Output: one push_log row per store per run, push_type='feed_check',
-- status SUCCESS or FAILED with the lag list in error_message.
-- Scheduled: pg_cron 'feed-freshness-check' 20:45 UTC (22:45 SAST), after
-- the L2 pipeline refresh.
--
-- First live run (2026-06-11 08:2x): correctly flagged 80175 sigma_sales AND
-- sigma_movements dark since 06-08, plus l2_soh_daily empty on all 5 stores.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS check_l1_feed_freshness();

CREATE OR REPLACE FUNCTION check_l1_feed_freshness()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store    text;
  v_snap_max date;
  v_sales_max date;
  v_mv_max   date;
  v_soh_max  date;
  v_problems text;
  v_status   text;
  v_summary  jsonb := '{}'::jsonb;
BEGIN
  FOR v_store IN SELECT unnest(ARRAY['10116','21355','80175','80176','80579'])
  LOOP
    SELECT MAX(snapshot_date) INTO v_snap_max FROM daily_snapshots WHERE store_code = v_store;
    SELECT MAX(sale_date)     INTO v_sales_max FROM sigma_sales
      WHERE store_code = v_store AND period_kind='T' AND txn_kind=1;
    SELECT MAX(movement_date) INTO v_mv_max FROM sigma_movements WHERE store_code = v_store;
    SELECT MAX(snapshot_date) INTO v_soh_max FROM l2_soh_daily WHERE store_code = v_store;

    v_problems := '';
    IF v_sales_max IS NULL OR v_sales_max < v_snap_max THEN
      v_problems := v_problems || format('sigma_sales dark since %s (TAC at %s); ',
                       COALESCE(v_sales_max::text,'never'), v_snap_max);
    END IF;
    IF v_mv_max IS NULL OR v_mv_max < v_snap_max THEN
      v_problems := v_problems || format('sigma_movements dark since %s (TAC at %s); ',
                       COALESCE(v_mv_max::text,'never'), v_snap_max);
    END IF;
    IF v_soh_max IS NULL OR v_soh_max < CURRENT_DATE THEN
      v_problems := v_problems || format('l2_soh_daily no current snapshot (last %s); ',
                       COALESCE(v_soh_max::text,'never'));
    END IF;

    v_status := CASE WHEN v_problems = '' THEN 'SUCCESS' ELSE 'FAILED' END;

    INSERT INTO push_log (store_code, push_type, table_name, status,
                          error_message, started_at, completed_at, script_version)
    VALUES (v_store, 'feed_check', 'l1_feeds', v_status,
            NULLIF(v_problems, ''), now(), now(), 'feed_check_v1');

    v_summary := v_summary || jsonb_build_object(v_store, COALESCE(NULLIF(v_problems,''), 'fresh'));
  END LOOP;

  RETURN v_summary;
END;
$$;

COMMENT ON FUNCTION check_l1_feed_freshness() IS
  'Nightly L1 feed staleness sentinel (DASH-TRUTH-001 P0.1). One push_log row '
  'per store per run (push_type=feed_check). FAILED row = a feed lags the TAC '
  'channel or l2_soh_daily missing current snapshot. pg_cron feed-freshness-check 20:45 UTC.';

GRANT EXECUTE ON FUNCTION check_l1_feed_freshness() TO authenticated;

SELECT cron.schedule(
  'feed-freshness-check',
  '45 20 * * *',
  $$SELECT check_l1_feed_freshness();$$
);
