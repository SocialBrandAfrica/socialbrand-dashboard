-- =============================================================================
-- create_refresh_l2_pipeline.sql
-- Canonical source for refresh_l2_pipeline(). Synced to LIVE 2026-07-11;
-- de-hardcoded 2026-06-17 (SB-CC-RECONCILE-001 Phase 1).
-- =============================================================================
-- 2026-07-11 SYNC NOTE: the SB-CC-BLOOM-005/ENG-002 Ship-2 pantry chain wiring
--   below (landed live 2026-07-10 by a separate execution context) had not
--   been pulled into this repo file -- caught up now, no behaviour change,
--   pure sync. Re-verified live before pulling: `pg_get_functiondef` confirms
--   the six-object chain wired exactly as shown; all six objects' own
--   timestamp columns (`pantry_refreshed_at`/`profiled_at`) stamped
--   identically `2026-07-10 20:15:00.105977+00` at 80176, proving one nightly
--   run produced all six together (BUG-LOG ENG-002 acceptance, verified R22).
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
--   3. refresh_l2_classification x(active stores) -- SB-CC-DASH-WIRE-001 t3
--   4. refresh_l2_anomaly_family3 x(active stores) -- SB-CC-ANOM-001
--   5. L1 dashboard MVs: mv_kpi_by_date, mv_rate_of_sale (SB-CC-DASH-SOURCE-002)
--      + per-store search index
--   Every per-store / MV step is guarded so it can never abort the chain;
--   failures are reported in the return JSONB.
--
-- 2026-06-17 DE-HARDCODE (SB-CC-RECONCILE-001 Phase 1, R25 config-only template):
--   The store fleet was a hardcoded ARRAY['10116','21355','80175','80176','80579']
--   repeated in 3 loops -- a portability breach (a new customer/store would not be
--   picked up without a code edit). Replaced with a single v_active_stores array
--   sourced from `stores WHERE is_active`. Behaviour-identical today: all 5 stores
--   are is_active=true, so the array resolves to exactly the prior 5. A new active
--   store is now picked up with zero code change.
--   Consignment stays scoped to 10116 -- that is a real feature scope (only SPAR
--   Delareyville runs the HMR sushi consignment), NOT a fleet hardcode. TODO(R25):
--   drive it off a per-store consignment flag/config when a second store onboards
--   consignment, rather than the literal '10116'.
--
-- 2026-06-13 SYNC NOTE: this file had drifted behind live -- the consignment +
--   classification blocks (deployed via MCP by prior sessions) were never synced
--   to the repo. Caught up then together with the mv_rate_of_sale refresh
--   (deployed via dash_source_002_wire_mv_rate_of_sale_into_pipeline).
--   mv_rate_of_sale uses plain REFRESH (pg_cron wraps the call in a txn, so
--   REFRESH ... CONCURRENTLY is not usable inside the pipeline).
--
-- 2026-07-02 RETIRE-003, first pass (R28): the search-index loop gated each
--   upsert_search_index(store) call on MAX(daily_snapshots.snapshot_date) IS NOT
--   NULL. daily_snapshots froze 2026-06-28 (write-retired), so the gate was dead
--   logic -- always true, guarding nothing, and the pipeline's last read of the
--   retired table. Gate removed; upsert_search_index(v_store) runs directly
--   (it reads sigma_articles + v_ean_bridge + l2_rate_of_sale since RETIRE-002).
--
-- 2026-07-02 RETIRE-003, second pass: mv_rate_of_sale's own body was repointed
--   fully sigma-native (l2_stock_position + v_ean_bridge, see
--   sql/create_mv_rate_of_sale.sql) -- SOH is no longer frozen. This pipeline's
--   REFRESH call is unchanged (body-agnostic) but now refreshes a genuinely
--   current matview instead of a stale-SOH one.
--
-- SCHEDULE: pg_cron job 'refresh-l2-pipeline' at 20:15 UTC (22:15 SAST).
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS refresh_l2_pipeline();

CREATE OR REPLACE FUNCTION refresh_l2_pipeline()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0            timestamptz := clock_timestamp();
  v_result        jsonb := '{}'::jsonb;
  v_store         text;
  -- R25: the fleet is config, not code. Single source for every per-store loop.
  v_active_stores text[] := ARRAY(SELECT store_code FROM stores WHERE is_active ORDER BY store_code);
BEGIN
  REFRESH MATERIALIZED VIEW l2_movements_typed;
  v_result := v_result || jsonb_build_object('movements_typed_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  REFRESH MATERIALIZED VIEW l2_rate_of_sale;
  REFRESH MATERIALIZED VIEW l2_item_classification;
  REFRESH MATERIALIZED VIEW l2_ranging_tier;
  REFRESH MATERIALIZED VIEW l2_stock_position;
  REFRESH MATERIALIZED VIEW l2_kpi_daily;
  v_result := v_result || jsonb_build_object('chain_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Consignment engine (SB-CC-PMINI-WIRE-001 Gap A). Reads sigma_sales x
  -- sigma_articles; depends on L1 (refreshed pre-pipeline by the push), not on
  -- the chain above, so order within the pipeline is not load-bearing. Placed
  -- here so the one pipeline owns every L2 table. Per-store guarded so it can
  -- never break the chain. Only 10116 runs consignment (feature scope, not a
  -- fleet hardcode -- see header TODO(R25)).
  -- NOTE: standing cron jobs 13/14 also call this nightly (belt-and-braces);
  -- idempotent (DELETE+INSERT current month) so the extra runs are harmless.
  -- Retiring jobs 13/14 is the consolidation step pending PM sign-off.
  FOR v_store IN SELECT unnest(ARRAY['10116'])
  LOOP
    BEGIN
      PERFORM refresh_l2_consignment_daily(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('consignment_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('consignment_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- l2_classification engine, all active stores (SB-CC-DASH-WIRE-001 t3). Reads
  -- l2_stock_position (refreshed above) + v_item_ean. Idempotent (DELETE+INSERT
  -- per store+day). Per-store guarded so it can never break the chain.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_classification(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('classification_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('classification_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Family 3 anomaly engine, all active stores (idempotent per store+day).
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_anomaly_family3(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('anomaly_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('anomaly_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- l2_last_counted (BUG-LOG ENG-006, SB-CC-BLOOM-004 wiring session 2026-07-11):
  -- ledger-true last-count fact (sigma_movements I-channel), replaces the stale
  -- l2_stock_position.last_inv_date/last_inv_soh summary fields as the source
  -- Forge's rpc_forge_count_list/rpc_forge_integrity read. Depends only on L1
  -- (sigma_movements), not on the L2 chain above -- order here is not load-bearing.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_last_counted(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('last_counted_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('last_counted_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Track A item 1 / ENG-031: the export-eligibility pantry fact. Depends only on
  -- sigma_articles + v_ean_bridge, so it carries no L2 ordering constraint. Wired
  -- here rather than left to a manual call -- an unwired pantry fact drifts out of
  -- step with the rest, which already happened once to the Ship-2 pantry (ENG-002).
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_export_key(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('export_key_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('export_key_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- ===================== SB-CC-BLOOM-005 / ENG-002: Ship-2 pantry chain =====================
  -- l2_bloom_ros_pantry FIRST -- l2_stock_band (last in this chain) depends on
  -- it, and it is the most expensive object here even after the perf rewrite.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_bloom_ros_pantry(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('bloom_ros_pantry_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('bloom_ros_pantry_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_bloom_promo_pantry(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('bloom_promo_pantry_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_kvi_profile(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('kvi_profile_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  -- Cross-store exception layer -- runs ONCE, after both SPAR stores'
  -- l2_kvi_profile rows are fresh (it reads them, never averages, canon
  -- s2b#6 / SB-STRAT-001 s8: TOPS trio deliberately excluded).
  BEGIN
    PERFORM refresh_l2_kvi_cross_store();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('kvi_cross_store_error', SQLERRM);
  END;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_rhythm_profile(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('rhythm_profile_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_seasonality_profile(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('seasonality_profile_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_gmroi_profile(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('gmroi_profile_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  -- l2_stock_band LAST -- depends on ros_pantry, kvi_profile, rhythm_profile,
  -- seasonality_profile and gmroi_profile all being fresh (ENG-004 family-
  -- draw-resolved demand + guards read all five).
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_stock_band(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('stock_band_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('bloom_pantry_chain_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ===================== end SB-CC-BLOOM-005 / ENG-002 =====================

  -- SB-CC-PREDICT-001 step 2 (ENG-022, applied live 2026-07-18 migration
  -- predict_03_wire_sales_budget_into_pipeline): the sales-budget need projection,
  -- per store, all ruled routes. Depends on l2_rhythm_profile + l2_seasonality_profile
  -- (fresh above) + l2_stock_position + sigma_sales. Per-store guarded. This is the
  -- ENG-002-class close for l2_sales_budget -- it stops being a manual object.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_sales_budget(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('sales_budget_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('sales_budget_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- BT out-event logging (SB-CC-BT-FIX-001: moved from read RPC to nightly pipeline).
  -- Guarded so it can never abort the chain.
  BEGIN
    PERFORM rpc_bt_log_out_events();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('bt_out_events_error', SQLERRM);
  END;

  -- BT precompute (SB-CC-BT-003): l2_bt_monthly, l2_bt_buying_weekly, l2_bt_tail,
  -- l2_bt_heroes -- converts live table scans to fast nightly-refreshed L2 tables.
  -- Each sub-refresh is guarded inside refresh_bt_precompute(); a failure in one
  -- does not abort the rest of the chain.
  BEGIN
    PERFORM refresh_bt_precompute();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('bt_precompute_error', SQLERRM);
  END;
  v_result := v_result || jsonb_build_object('bt_precompute_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- L1 dashboard recovery steps (PM 06-11 ruling): belt-and-braces for the
  -- push script's REST 500s -- refresh mv_kpi_by_date + search index in-DB.
  BEGIN
    REFRESH MATERIALIZED VIEW mv_kpi_by_date;
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('mv_kpi_error', SQLERRM);
  END;

  -- mv_rate_of_sale: fully sigma-native since RETIRE-003 2026-07-02
  -- (l2_stock_position + v_ean_bridge). Guarded. Plain REFRESH (CONCURRENTLY
  -- not usable in the txn).
  BEGIN
    REFRESH MATERIALIZED VIEW mv_rate_of_sale;
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('mv_rate_of_sale_error', SQLERRM);
  END;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM upsert_search_index(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('search_index_error_' || v_store, SQLERRM);
    END;
  END LOOP;

  v_result := v_result || jsonb_build_object('total_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION refresh_l2_pipeline() IS
  'Nightly L2 engine refresh: L2 chain -> consignment(10116) -> classification x(active) '
  '-> Family 3 anomaly x(active) -> Ship-2 pantry chain (ros_pantry -> promo_pantry -> '
  'kvi_profile -> kvi_cross_store -> rhythm -> seasonality -> gmroi -> stock_band, '
  'SB-CC-BLOOM-005/ENG-002) -> BT out-event logging -> BT precompute (SB-CC-BT-003) '
  '-> mv_kpi_by_date + mv_rate_of_sale + search index. '
  'Fleet sourced from stores WHERE is_active (R25). Scheduled via pg_cron refresh-l2-pipeline (20:15 UTC).';

GRANT EXECUTE ON FUNCTION refresh_l2_pipeline() TO authenticated;

SELECT cron.schedule(
  'refresh-l2-pipeline',
  '15 20 * * *',
  $$SELECT refresh_l2_pipeline();$$
);
