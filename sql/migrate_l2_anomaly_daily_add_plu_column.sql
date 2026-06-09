-- =============================================================================
-- migrate_l2_anomaly_daily_add_plu_column.sql
-- SB-CC-L1-EAN-COMPLETENESS -- Phase 2: surface PLU signal in anomaly rows
-- =============================================================================
-- Version  : 1.0
-- Date     : 2026-06-09
-- Ref      : SB-CC-L1-EAN-COMPLETENESS, create_l2_anomaly_daily.sql v1.1
-- Owner    : CC (Claude Code)
--
-- WHAT THIS DOES
--   Adds is_confirmed_plu boolean to l2_anomaly_daily so that each anomaly
--   row carries the PLU/scale classification signal for audit and routing.
--   Populated by refresh_l2_anomaly_family3() reading v_item_ean.
--
-- HOW TO RUN
--   Run AFTER migrate_sigma_ean_master_barcode_to_text.sql and create_v_item_ean.sql.
--   Safe to re-run (IF NOT EXISTS).
--   Then re-run refresh_l2_anomaly_family3.sql to redeploy the updated function.
-- =============================================================================


ALTER TABLE l2_anomaly_daily
    ADD COLUMN IF NOT EXISTS is_confirmed_plu boolean DEFAULT false;

COMMENT ON COLUMN l2_anomaly_daily.is_confirmed_plu IS
    'TRUE when sigma_articles.plu_flag=''1'' (cPLU) or scale_flag=''1'' (cWAG) '
    'and no GS1 barcode exists in sigma_ean_master. '
    'Confirmed made-in-store / scale item -- not a data gap. '
    'Source: v_item_ean.is_confirmed_plu (extractor v1.7+). '
    'Ref: SB-CC-L1-EAN-COMPLETENESS.';
