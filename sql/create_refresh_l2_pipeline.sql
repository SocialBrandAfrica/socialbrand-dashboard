-- =============================================================================
-- create_refresh_l2_pipeline.sql
-- Deployed 2026-06-10 23:0x SAST via Supabase MCP (migration
-- create_refresh_l2_pipeline_and_schedule). Kept here as canonical source.
-- =============================================================================
-- ROOT CAUSE THIS FIXES (found 2026-06-10 dashboard evaluation):
--   NOTHING refreshed the L2 MV chain nightly. No pg_cron job, no push-chain
--   call, no extractor call. The handover's "nightly REFRESH automatic after
--   L1 push" claim was wrong -- it covered mv_kpi_by_date (L1 dashboard MV)
--   only. Consequence: l2_kpi_daily sat stale with NULL gp_pct since the v1.2
--   DDL landed; l2_stock_position drifted from live lifecycle data.
--
-- WHAT THIS DOES:
--   refresh_l2_pipeline() refreshes the L2 chain in dependency order:
--     l2_movements_typed -> l2_rate_of_sale -> l2_item_classification
--     -> l2_ranging_tier -> l2_stock_position -> l2_kpi_daily
--   then re-runs refresh_l2_anomaly_family3 for all 5 stores (closes the
--   SB-CC-ANOM-001 nightly-wiring open item). Per-store anomaly errors are
--   caught and reported in the return JSONB, never abort the chain.
--
-- SCHEDULE: pg_cron job 'refresh-l2-pipeline' at 20:15 UTC (22:15 SAST) --
--   after the nightly push (20:00/21:00 SAST sweeps) + chained extractor have
--   landed L1 data. In-database, no HTTP timeout risk.
--   Measured duration on first run (2026-06-10): 113.6s total.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS refresh_l2_pipeline();

CREATE OR REPLACE FUNCTION refresh_l2_pipeline()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0     timestamptz := clock_timestamp();
  v_result jsonb := '{}'::jsonb;
  v_store  text;
BEGIN
  REFRESH MATERIALIZED VIEW l2_movements_typed;
  v_result := v_result || jsonb_build_object('movements_typed_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  REFRESH MATERIALIZED VIEW l2_rate_of_sale;
  REFRESH MATERIALIZED VIEW l2_item_classification;
  REFRESH MATERIALIZED VIEW l2_ranging_tier;
  REFRESH MATERIALIZED VIEW l2_stock_position;
  REFRESH MATERIALIZED VIEW l2_kpi_daily;
  v_result := v_result || jsonb_build_object('chain_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  FOR v_store IN SELECT unnest(ARRAY['10116','21355','80175','80176','80579'])
  LOOP
    BEGIN
      PERFORM refresh_l2_anomaly_family3(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('anomaly_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  v_result := v_result || jsonb_build_object('total_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION refresh_l2_pipeline() IS
  'Nightly L2 engine refresh: movements_typed -> rate_of_sale -> item_classification '
  '-> ranging_tier -> stock_position -> kpi_daily, then Family 3 anomaly engine x5 stores. '
  'Scheduled via pg_cron refresh-l2-pipeline (20:15 UTC). Created 2026-06-10.';

GRANT EXECUTE ON FUNCTION refresh_l2_pipeline() TO authenticated;

SELECT cron.schedule(
  'refresh-l2-pipeline',
  '15 20 * * *',
  $$SELECT refresh_l2_pipeline();$$
);
