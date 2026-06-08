-- =============================================================================
-- create_l2_anomaly_daily.sql
-- SocialBrand Intelligence Platform -- Anomaly Radar, SB-CC-ANOM-001 Family 3
-- =============================================================================
-- Reference   : SB-CC-ANOM-001 v0.4, STOCK-TRIAGE-TOOL.md (SB-INDEX-014),
--               STOCK-CLEANUP-RULE-EVOLUTION-2026-06-08.md
-- Version     : 1.0
-- Date        : 2026-06-08
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Owner       : Claude Code (CC); PM review before multi-store rollout
--
-- WHAT THIS IS
--   Persistent anomaly log populated nightly by refresh_l2_anomaly_family3().
--   One row per (store, product, snapshot_date, anomaly_type).
--   Family 3A: dead NORMAL stock routed through the qualifying cascade
--              (STOCKFLOW / TLX_ZERO / AMBIGUOUS).
--   Family 3B: integrity outliers surfaced from l2_stock_position signals
--              (neg_soh, cost_sanity, stale_ledger, investigate_stock).
--
-- R21 COMPLIANCE (RULE-BOOK SS12):
--   All classes flow through the engine. The formula decides the answer,
--   not the product. No hard-coded names -- behaviour and movement signals.
--   Production-by-no-receipt excluded until L1 movement decode is ready.
--
-- R22 COMPLIANCE (RULE-BOOK SS13):
--   Every row has frozen evidence (state at detection), cascade_step, signals,
--   confidence, and detected_at. Nothing is assumed -- every field is
--   traceable to the source table that produced it.
--
-- PRODUCTION CARVE-OUT WARNING:
--   production-by-no-receipt is NOT implemented in Family 3 -- it over-fires
--   on DSD + IBT channels (Coca-Cola, ciders tested on 80579, 2026-06-08).
--   The cascade uses sub-dept + dummy-supplier as an INTERIM low-confidence
--   signal only, always routed AMBIGUOUS with confidence=0.4.
--   Full production detection requires L1 movement-channel decode (SB-CC-L1-001).
--
-- HOW TO RUN:
--   1. Run this file once (DROP + CREATE) to create the table.
--   2. Run refresh_l2_anomaly_family3.sql to create the refresh function.
--   3. Call: SELECT * FROM refresh_l2_anomaly_family3('10116');
--   4. Review output on 10116 before running multi-store.
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP TABLE IF EXISTS l2_anomaly_daily CASCADE;


CREATE TABLE l2_anomaly_daily (

    -- Primary key
    anomaly_id          uuid        DEFAULT gen_random_uuid() NOT NULL,

    -- Identity
    client_id           text,   -- matches l2_stock_position.client_id (text, not uuid)
    store_code          text        NOT NULL,
    product_code        bigint      NOT NULL,
    snapshot_date       date        NOT NULL,   -- CURRENT_DATE at detection time

    -- Anomaly classification
    family              text        NOT NULL,   -- '3A' (triage) or '3B' (integrity)
    anomaly_type        text        NOT NULL,
    -- 3A types: DEAD_STOCK, PHANTOM_SUSPECT, DEPOSIT, PARENT_CHILD,
    --            CONSUMABLE, PRODUCTION_INTERIM
    -- 3B types: NEGATIVE_SOH, COST_SANITY, STALE_LEDGER, INVESTIGATE_STOCK

    route               text,
    -- STOCKFLOW  = needs physical count via StockFlow
    -- TLX_ZERO   = safe to zero (no barcode-less exceptions)
    -- AMBIGUOUS  = cannot auto-route (deposit / no barcode / parent-child /
    --              production-interim / sold-after-receipt suspect)
    -- NULL for 3B (integrity outliers do not get routed)

    cascade_step        text,
    -- The FIRST cascade step (A/B/C/D) that determined this row's fate.
    -- A1=DEPOSIT  A2=PRODUCTION_INTERIM  A3=CONSUMABLE  A4=PARENT_CHILD
    -- B5=NEGATIVE_SOH
    -- C6=SOLD_AFTER_RECEIPT  C8=RECENT_MOVEMENT  C8b=RECODE_SIBLING
    -- D9=PHANTOM_NEVER_RECEIVED  D10=DECLUTTER

    -- Stock state frozen at detection (R22 -- never recomputed from a later run)
    description         text,
    subdept_name        text,
    dept_name           text,
    soh                 numeric,
    capital_value       numeric,
    unit_cost           numeric,
    daily_ros           numeric,
    sales_qty_91d       numeric,
    last_sale_date      date,
    last_receipt_date   date,
    never_sold          boolean,    -- no till sale ever (full history from sigma_lifecycle)
    has_barcode         boolean,

    -- Behavioural signals computed at detection (R22 audit trail)
    deposit_sg_count    int,        -- count of S/G events (>=2 = deposit class)
    last_grv_date       date,       -- last positive R/W/DIWAREPR movement
    last_any_inbound    date,       -- last positive movement of ANY type
    last_any_movement   date,       -- last movement of any type, either direction
    parent_child_flag   boolean     DEFAULT false,
    production_interim  boolean     DEFAULT false,  -- sub-dept/supplier heuristic, NOT confirmed

    -- R22 audit fields
    confidence          numeric,    -- 0.0 to 1.0; reflects how certain the cascade verdict is
    evidence            text,       -- human-readable: what triggered this + key signal values
    signals_snapshot    text,       -- comma-separated l2_stock_position.signals at detection

    -- Lifecycle (used by dashboard display layer, not the engine)
    status              text        DEFAULT 'OPEN',
    -- OPEN / ACTIONED / DISMISSED

    detected_at         timestamptz DEFAULT now(),

    -- Constraints
    PRIMARY KEY (anomaly_id),
    CONSTRAINT l2_anomaly_daily_uq
        UNIQUE (store_code, product_code, snapshot_date, anomaly_type)
);


-- Indexes for dashboard queries
CREATE INDEX idx_l2_anomaly_store_date
    ON l2_anomaly_daily (store_code, snapshot_date DESC);

CREATE INDEX idx_l2_anomaly_route
    ON l2_anomaly_daily (store_code, snapshot_date, route)
    WHERE route IS NOT NULL;

CREATE INDEX idx_l2_anomaly_family
    ON l2_anomaly_daily (store_code, family, snapshot_date DESC);

CREATE INDEX idx_l2_anomaly_status
    ON l2_anomaly_daily (store_code, status, snapshot_date DESC)
    WHERE status = 'OPEN';


COMMENT ON TABLE l2_anomaly_daily IS
    'Persistent anomaly log. Family 3A = dead NORMAL stock qualifying cascade '
    '(STOCKFLOW/TLX_ZERO/AMBIGUOUS). Family 3B = integrity outliers '
    '(neg_soh, cost_sanity, stale_ledger, investigate_stock). '
    'Nightly refresh via refresh_l2_anomaly_family3(store_code). '
    'R21 engine-principle: formula decides, not product. '
    'R22: every row fully auditable to source. SB-CC-ANOM-001 Family 3.';


GRANT SELECT ON l2_anomaly_daily TO anon, authenticated;


-- =============================================================================
-- VERIFY after first refresh:
-- =============================================================================
-- SELECT family, anomaly_type, route,
--        COUNT(*) AS rows,
--        ROUND(SUM(capital_value)::numeric, 0) AS total_capital,
--        ROUND(AVG(confidence)::numeric, 2) AS avg_confidence
-- FROM l2_anomaly_daily
-- WHERE store_code = '10116'
--   AND snapshot_date = CURRENT_DATE
-- GROUP BY family, anomaly_type, route
-- ORDER BY family, total_capital DESC;
-- =============================================================================
