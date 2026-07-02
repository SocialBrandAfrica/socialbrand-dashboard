-- =============================================================================
-- create_check_l1_feed_freshness.sql
-- v2 deployed 2026-07-02 via Supabase MCP (migration
-- retire003_check_l1_feed_freshness_v2). Canonical source.
-- v1 deployed 2026-06-11 (migration create_check_l1_feed_freshness).
-- =============================================================================
-- SB-CC-DASH-TRUTH-001 P0.1 auditability sentinel (R22): a dark feed must
-- surface in push_log every night, never hide behind a green summary row.
--
-- v2 (SB-CC-RETIRE-003, 2026-07-02) -- R28 lineage:
--   * BASELINE REPOINTED. v1 compared every feed against
--     MAX(daily_snapshots.snapshot_date) ("the TAC channel"). The PRSSALE push
--     retired 2026-06-28, freezing that baseline at 28 Jun -- sigma_sales and
--     sigma_movements could never flag again (their max is always >= 28 Jun).
--     The sigma-dark detector this sentinel exists for was permanently blind.
--     v2 baseline = the store's CURRENT TRADING DATE: (now() at the store's
--     time zone)::date, tz from store_extract_config (R25), fallback
--     Africa/Johannesburg.
--   * FLEET from stores WHERE is_active (R25) -- v1 hard-coded the 5 codes.
--   * retired_on 2026-07-02: the daily_snapshots baseline, superseded_by the
--     store-tz trading-date baseline.
--
-- Rule per store (at the 22:45 SAST cron slot, after eod_window_end 22:00,
-- all three feeds should hold TODAY's trading date):
--   - sigma_sales    max(sale_date)     < expected -> stale
--   - sigma_movements max(movement_date) < expected -> stale
--   - l2_soh_daily   max(snapshot_date) < expected -> stale
-- A manual run BEFORE the store's EOD lands truthfully flags everything --
-- same surface-never-hide semantics v1 had on the l2_soh_daily leg. A slow
-- EOD landing between 22:45 and the 23:30 hard cutoff shows one false FAILED
-- that self-corrects the next night -- acceptable: red asks a human to look.
--
-- Output: one push_log row per store per run, push_type='feed_check',
-- status SUCCESS or FAILED with the lag list in error_message. Consumed by
-- rpc_layer_freshness (dashboard freshness strip).
-- Scheduled: pg_cron 'feed-freshness-check' 20:45 UTC (22:45 SAST), after
-- the L2 pipeline refresh.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS check_l1_feed_freshness();

CREATE OR REPLACE FUNCTION check_l1_feed_freshness()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store     text;
  v_expected  date;
  v_sales_max date;
  v_mv_max    date;
  v_soh_max   date;
  v_problems  text;
  v_status    text;
  v_summary   jsonb := '{}'::jsonb;
BEGIN
  FOR v_store IN SELECT s.store_code FROM stores s WHERE s.is_active ORDER BY s.store_code
  LOOP
    -- Expected data date = the store's current trading date (R25: tz from config).
    SELECT (now() AT TIME ZONE COALESCE(c.time_zone, 'Africa/Johannesburg'))::date
      INTO v_expected
      FROM (SELECT 1) one
      LEFT JOIN store_extract_config c
             ON c.store_code = v_store AND c.is_active;

    SELECT MAX(sale_date) INTO v_sales_max FROM sigma_sales
      WHERE store_code = v_store AND period_kind='T' AND txn_kind=1;
    SELECT MAX(movement_date) INTO v_mv_max FROM sigma_movements WHERE store_code = v_store;
    SELECT MAX(snapshot_date) INTO v_soh_max FROM l2_soh_daily WHERE store_code = v_store;

    v_problems := '';
    IF v_sales_max IS NULL OR v_sales_max < v_expected THEN
      v_problems := v_problems || format('sigma_sales stale: last %s, expected %s; ',
                       COALESCE(v_sales_max::text,'never'), v_expected);
    END IF;
    IF v_mv_max IS NULL OR v_mv_max < v_expected THEN
      v_problems := v_problems || format('sigma_movements stale: last %s, expected %s; ',
                       COALESCE(v_mv_max::text,'never'), v_expected);
    END IF;
    IF v_soh_max IS NULL OR v_soh_max < v_expected THEN
      v_problems := v_problems || format('l2_soh_daily stale: last %s, expected %s; ',
                       COALESCE(v_soh_max::text,'never'), v_expected);
    END IF;

    v_status := CASE WHEN v_problems = '' THEN 'SUCCESS' ELSE 'FAILED' END;

    INSERT INTO push_log (store_code, push_type, table_name, status,
                          error_message, started_at, completed_at, script_version)
    VALUES (v_store, 'feed_check', 'l1_feeds', v_status,
            NULLIF(v_problems, ''), now(), now(), 'feed_check_v2');

    v_summary := v_summary || jsonb_build_object(v_store, COALESCE(NULLIF(v_problems,''), 'fresh'));
  END LOOP;

  RETURN v_summary;
END;
$$;

COMMENT ON FUNCTION check_l1_feed_freshness() IS
  'Nightly L1 feed staleness sentinel (DASH-TRUTH-001 P0.1; v2 RETIRE-003). One '
  'push_log row per store per run (push_type=feed_check). FAILED = a feed lags '
  'the store''s current trading date (store-tz, config-driven). pg_cron '
  'feed-freshness-check 20:45 UTC.';

GRANT EXECUTE ON FUNCTION check_l1_feed_freshness() TO authenticated;

-- Cron job already scheduled (feed-freshness-check, 45 20 * * *). Re-schedule
-- only on a fresh deploy:
-- SELECT cron.schedule('feed-freshness-check', '45 20 * * *',
--   $$SELECT check_l1_feed_freshness();$$);
