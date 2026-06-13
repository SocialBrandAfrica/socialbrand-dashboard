-- =============================================================================
-- create_refresh_l2_pipeline.sql
-- Canonical source for refresh_l2_pipeline(). Synced to LIVE 2026-06-13.
-- =============================================================================
-- ROOT CAUSE THIS FIXES (found 2026-06-10 dashboard evaluation):
--   NOTHING refreshed the L2 MV chain nightly. The handover's "nightly REFRESH
--   automatic after L1 push" claim was wrong -- it covered mv_kpi_by_date only.
--
-- WHAT THIS DOES (current live order):
--   1. L2 chain in dependency order:
--      l2_movements_typed -> l2_rate_of_sale -> l2_item_classification
--      -> l2_ranging_tier -> l2_stock_position -> l2_kpi_daily
--   2. refresh_l2_consignment_daily (10116) -- SB-CC-PMINI-WIRE-001 Gap A
--   3. refresh_l2_classification x5 -- SB-CC-DASH-WIRE-001 t3
--   4. refresh_l2_anomaly_family3 x5 -- SB-CC-ANOM-001
--   5. L1 dashboard MVs: mv_kpi_by_date, mv_rate_of_sale (SB-CC-DASH-SOURCE-002)
--      + per-store search index
--   Every per-store / MV step is guarded so it can never abort the chain;
--   failures are reported in the return JSONB.
--
-- 2026-06-13 SYNC NOTE: this file had drifted behind live -- the consignment +
--   classification blocks (deployed via MCP by prior sessions) were never synced
--   to the repo. Caught up here together with the new mv_rate_of_sale refresh
--   (deployed via dash_source_002_wire_mv_rate_of_sale_into_pipeline).
--   mv_rate_of_sale uses plain REFRESH (pg_cron wraps the call in a txn, so
--   REFRESH ... CONCURRENTLY is not usable inside the pipeline).
--
-- SCHEDULE: pg_cron job 'refresh-l2-pipeline' at 20:15 UTC (22:15 SAST).
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS refresh_l2_pipeline();

CREATE OR REPLACE FUNCTION refresh_l2_pipeline()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0     timestamptz := clock_timestamp();
  v_result jsonb := '{}'::jsonb;
  v_store  text;
  v_snap   date;
BEGIN
  REFRESH MATERIALIZED VIEW l2_movements_typed;
  v_result := v_result || jsonb_build_object('movements_typed_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  REFRESH MATERIALIZED VIEW l2_rate_of_sale;
  REFRESH MATERIALIZED VIEW l2_item_classification;
  REFRESH MATERIALIZED VIEW l2_ranging_tier;
  REFRESH MATERIALIZED VIEW l2_stock_position;
  REFRESH MATERIALIZED VIEW l2_kpi_daily;
  v_result := v_result || jsonb_build_object('chain_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Consignment engine (SB-CC-PMINI-WIRE-001 Gap A). Per-store guarded.
  FOR v_store IN SELECT unnest(ARRAY['10116'])
  LOOP
    BEGIN
      PERFORM refresh_l2_consignment_daily(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('consignment_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('consignment_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- l2_classification engine, all 5 stores (SB-CC-DASH-WIRE-001 t3). Per-store guarded.
  FOR v_store IN SELECT unnest(ARRAY['10116','21355','80175','80176','80579'])
  LOOP
    BEGIN
      PERFORM refresh_l2_classification(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('classification_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('classification_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Family 3 anomaly engine, all 5 stores (idempotent per store+day).
  FOR v_store IN SELECT unnest(ARRAY['10116','21355','80175','80176','80579'])
  LOOP
    BEGIN
      PERFORM refresh_l2_anomaly_family3(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('anomaly_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  -- L1 dashboard recovery steps (PM 06-11 ruling): belt-and-braces for the
  -- push script's REST 500s -- refresh mv_kpi_by_date + search index in-DB.
  BEGIN
    REFRESH MATERIALIZED VIEW mv_kpi_by_date;
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('mv_kpi_error', SQLERRM);
  END;

  -- mv_rate_of_sale (SB-CC-DASH-SOURCE-002): ROS off sigma_sales + held SOH off
  -- daily_snapshots. Guarded. Plain REFRESH (CONCURRENTLY not usable in the txn).
  BEGIN
    REFRESH MATERIALIZED VIEW mv_rate_of_sale;
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('mv_rate_of_sale_error', SQLERRM);
  END;

  FOR v_store IN SELECT unnest(ARRAY['10116','21355','80175','80176','80579'])
  LOOP
    BEGIN
      SELECT MAX(snapshot_date) INTO v_snap FROM daily_snapshots WHERE store_code = v_store;
      IF v_snap IS NOT NULL THEN
        PERFORM upsert_search_index(v_store, v_snap);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('search_index_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  v_result := v_result || jsonb_build_object('total_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION refresh_l2_pipeline() IS
  'Nightly L2 engine refresh: L2 chain -> consignment(10116) -> classification x5 '
  '-> Family 3 anomaly x5 -> mv_kpi_by_date + mv_rate_of_sale + search index. '
  'Scheduled via pg_cron refresh-l2-pipeline (20:15 UTC).';

GRANT EXECUTE ON FUNCTION refresh_l2_pipeline() TO authenticated;

SELECT cron.schedule(
  'refresh-l2-pipeline',
  '15 20 * * *',
  $$SELECT refresh_l2_pipeline();$$
);
