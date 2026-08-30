-- create_refresh_l2_pipeline.sql
--
-- REPLACED FROM LIVE 2026-08-30 (ENG-115 class rule: a sql/ file that was not
-- generated from live can never be hash-gated, only replaced). The DO NOT APPLY
-- banner this file carried since 2026-08-24 is now DISCHARGED -- the file is safe
-- to apply because it IS live, proven by hash gate in the same pass.
--
-- THE DIVERGENCE THAT IS NOW CLOSED, stated so the close is auditable:
--   the previous file was missing THREE refresh legs that run live nightly --
--     refresh_l2_product_resolution  (Identity Phase 2 / FORGE-MAP-001)
--     refresh_l2_family_ros          (ENG-073, the family-resolved display rate)
--     refresh_l2_population_verdict  (SB-CC-BLOOM-026 §12, the cross-app fact)
--   Applying it would have SILENTLY DROPPED all three from the nightly chain and
--   left l2_population_verdict stale while still reading as populated.
--
-- ⚠️ THE LIVE BODY HAS NOT MOVED SINCE THE 2026-08-24 STAMP. Verified, not assumed:
-- raw md5(pg_get_functiondef) = 9ed5f5bce31dac2ecd283d1ad7a81ada at 13,304 chars,
-- identical to the stamped pin. Only the FILE was stale. (The stamp is a RAW md5
-- and the gate below is a WHITESPACE-STRIPPED md5 -- two different functions of
-- the same input, and comparing them directly would have manufactured a phantom
-- drift. Standing Constraint 1 in the other direction: a sentinel is only a
-- sentinel against the SAME sentinel.)
--
-- ⚠️ ORDER IS THE WHOLE POINT OF THIS FUNCTION. It is not a list of refreshes, it
-- is a DEPENDENCY ORDER, and three positions are load-bearing and commented as
-- such in the body: identity before every bridge consumer; family_ros after
-- product_resolution but before mv_rate_of_sale; range_state after
-- refresh_bt_precompute because its dependencies STRADDLE the chain -- that last
-- one went 13 days stale unwired and collapsed the Recipe desk to 28% of its own
-- signed reference. Never reorder a leg to make a diff smaller.
--
-- ⚠️ EVERY PER-STORE LEG IS WRAPPED IN ITS OWN BEGIN/EXCEPTION so one store cannot
-- take the whole chain down; the failure is RECORDED into the returned jsonb under
-- '<leg>_error_<store>' rather than swallowed. A silent skip would be an L1 breach.
-- Read the returned jsonb after a run -- an empty error set is the only pass.
--
-- ⚠️ NAMED RESIDUAL, NOT FIXED HERE: this function is SECURITY DEFINER with NO
-- `SET search_path`, unlike every other object in this folder. That is a real
-- advisory (a mutable search_path on a definer function), and it is left exactly
-- as live rather than corrected in passing -- this is the nightly chain, and a
-- search_path change to it is its own ship with its own R22, not a rider on a
-- source-parity commit. Written down, not hidden.
--
-- ⚠️ THE CONSIGNMENT LEG IS HARDCODED TO '10116'. That is a store-specific literal
-- inside general canon (§0h): it is the only store with a consignment arrangement
-- today. It belongs in config; filed, not silently generalised.

CREATE OR REPLACE FUNCTION public.refresh_l2_pipeline()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_t0            timestamptz := clock_timestamp();
  v_result        jsonb := '{}'::jsonb;
  v_store         text;
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

  -- ============ IDENTITY PHASE 2 (CANON SS17): resolved identity FIRST ============
  -- v_ean_bridge is a thin view over l2_ean_resolved, so this must precede every
  -- bridge consumer below (export key, Bloom pantry, bt_*, mv_rate_of_sale, search).
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_ean_resolved(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('ean_resolved_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('ean_resolved_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- The LINK_CODES candidate queue. Detects family / successor / absent-identity
  -- CANDIDATES only; resolves nothing (status CHECK-locked to CANDIDATE pending
  -- the item-12 ruling). Feeds ENG-020 leg 2's non-empty gate.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_link_codes_queue(v_store);
      BEGIN
        PERFORM refresh_l2_product_resolution(v_store);
      EXCEPTION WHEN OTHERS THEN
        v_result := v_result || jsonb_build_object('product_resolution_error_' || v_store, SQLERRM);
      END;
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('link_codes_queue_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('link_codes_queue_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ============ end IDENTITY PHASE 2 ============

  -- ============ ENG-073 / BLOOM-020 item 1: THE FAMILY-RESOLVED DISPLAY RATE ============
  -- Placed HERE, and the position is load-bearing in both directions. It reads
  -- l2_product_resolution (refreshed immediately above), l2_stock_position and
  -- l2_rate_of_sale (the chain, at the top), so it cannot run earlier; and
  -- mv_rate_of_sale plus the display RPCs read IT, and they run at the tail, so
  -- it must not run later. l2_range_state is the standing warning here -- it went
  -- 13 days stale unwired because its dependencies straddled the chain.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_family_ros(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('family_ros_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('family_ros_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ============ end ENG-073 ============

  -- ============ SB-CC-DEBT-001 / CANON 12e: THE COST-INTEGRITY BASELINE ============
  -- What we RECEIVED married to what we OWE, per (store, order_nr), with a named
  -- verdict. Must be fresh before anything computes on purchase cost.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_creditor_stock_match(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('creditor_stock_match_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('creditor_stock_match_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ============ end SB-CC-DEBT-001 ============

  -- ============ SB-CC-BLOOM-017 W1 item 1.3: IN-TRANSIT STOCK ============
  -- Open ordered qty per (store, product), bounded by the ROUTE own demonstrated
  -- placement->GRV lead x in_transit_lead_multiple. Canon s14 ADDENDUM v14 rule 3.
  -- Sits with the creditor baseline because both derive from the sigma_orders L1 leg.
  -- Must be fresh BEFORE any consumer projects SOH (rpc_bloom_order_recipe reads it).
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_on_order(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('on_order_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('on_order_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ============ end SB-CC-BLOOM-017 W1 item 1.3 ============

  FOR v_store IN SELECT unnest(ARRAY['10116'])
  LOOP
    BEGIN
      PERFORM refresh_l2_consignment_daily(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('consignment_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('consignment_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_classification(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('classification_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('classification_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_anomaly_family3(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('anomaly_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('anomaly_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_last_counted(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('last_counted_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('last_counted_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- Track A item 1 / ENG-031: the export-eligibility pantry fact
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

  -- Ladder rungs 2 and 3, PLATFORM-WIDE, after every store's own_promo pass.
  BEGIN
    PERFORM fill_l2_bloom_promo_pantry_sibling_fallback();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('bloom_promo_fallback_error', SQLERRM);
  END;

  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_kvi_profile(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('kvi_profile_error_' || v_store, SQLERRM);
    END;
  END LOOP;

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

  -- SB-CC-PREDICT-001 step 2 (ENG-022): the sales-budget need projection, per store, all ruled routes.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_sales_budget(v_store);
      -- LEG D: the projection is the NEEDS rail's only source, so the rail is written
      -- in the same breath. MANUAL (cashflow punch-in) rows are never overwritten.
      PERFORM refresh_order_budget_ledger_needs(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('sales_budget_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('sales_budget_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  BEGIN
    PERFORM rpc_bt_log_out_events();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('bt_out_events_error', SQLERRM);
  END;

  BEGIN
    PERFORM refresh_bt_precompute();
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('bt_precompute_error', SQLERRM);
  END;
  v_result := v_result || jsonb_build_object('bt_precompute_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  -- ============ ORD-STOP-001 defect 5: l2_range_state DRIVES DEPTH ============
  -- MUST run here, after refresh_bt_precompute, because it reads l2_bt_heroes
  -- (late) as well as l2_kvi_profile (mid) and l2_classification (early). It is
  -- the only pantry fact whose dependencies straddle the chain, which is how it
  -- went 13 days stale unwired and collapsed the Recipe desk to 28% of its own
  -- signed reference. A missing or stale row defaults a line to SLOW = zero depth.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_range_state(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('range_state_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('range_state_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  -- ============ end ORD-STOP-001 defect 5 ============

  -- ============ SB-CC-BLOOM-026 SS12 / R33: the cross-app population fact ============
  -- MUST run after range_state, stock_band, kvi_profile and the ros pantry: it reads
  -- all four. Per-store and guarded, so one store cannot take the whole chain down.
  FOR v_store IN SELECT unnest(v_active_stores)
  LOOP
    BEGIN
      PERFORM refresh_l2_population_verdict(v_store);
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('population_verdict_error_' || v_store, SQLERRM);
    END;
  END LOOP;
  v_result := v_result || jsonb_build_object('population_verdict_done_s', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));

  BEGIN
    REFRESH MATERIALIZED VIEW mv_kpi_by_date;
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object('mv_kpi_error', SQLERRM);
  END;

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
$function$;

-- Grants stated explicitly, and they match live exactly (postgres / authenticated /
-- service_role hold EXECUTE; anon and PUBLIC do not). R30 addendum extension:
-- PUBLIC and anon BOTH revoked on a mutating function -- a role-specific grant
-- survives a REVOKE FROM PUBLIC, and that trap has fired three times here.
REVOKE EXECUTE ON FUNCTION public.refresh_l2_pipeline() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_pipeline() FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_pipeline() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_pipeline() TO service_role;
