-- =============================================================================
-- create_l2_stock_count_plan.sql
-- SocialBrand Intelligence Platform -- Family 3 Count Engine
-- =============================================================================
-- Reference   : SB-CC-FAMILY3-COUNT-ENGINE-001 (PM + CC layers)
--               STOCK-TRIAGE-TOOL.md (SB-INDEX-014)
--               SIGMA-CLEANUP-WORKFLOW.md (SB-INDEX-015)
-- Version     : 1.0
-- Date        : 2026-06-09
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Owner       : Claude Code (CC); PM review before multi-store rollout
--
-- WHAT THIS IS
--   Actionable count-plan output table populated nightly by
--   refresh_l2_stock_count_plan().  One row per (store, product, snapshot_date).
--   Every in-scope line gets exactly one bucket:
--     HEALTHY    = selling + positive SOH (in table; excluded from action files)
--     STOCKFLOW  = needs physical count via StockFlow
--     TLX        = confident dead, barcode confirmed -- safe auto-zero
--     AMBIGUOUS  = cannot act cleanly -- manual review
--
-- RELATIONSHIP TO l2_anomaly_daily
--   Runs ALONGSIDE l2_anomaly_daily (not a replacement).
--   l2_anomaly_daily = anomaly DETECTION: movement CTEs, R1k capital floor,
--                      OPEN/ACTIONED/DISMISSED lifecycle, dashboard anomaly tile.
--   l2_stock_count_plan = count PLAN: simplified gate (all non-zero SOH NORMAL),
--                         no capital floor, HEALTHY included, barcode pre-joined.
--                         Source for StockFlow CSV, TLX file, Ambiguous CSV.
--
-- R21 COMPLIANCE (RULE-BOOK SS12):
--   All classes (incl. HEALTHY) flow through the engine.
--   Capital value is NEVER a filter. Value is display-only.
--   Pieter's law: the formula decides the answer, not the product.
--
-- R22 COMPLIANCE (RULE-BOOK SS13):
--   Routing signals (sold_91d, recv_365d, deposit_like) stored on every row.
--   bucket_reason stored on every non-HEALTHY row.
--   State frozen at snapshot_date for auditability.
--
-- RECYCLED-CODE GUARD (Hard Rule 2 in brief):
--   barcode_list = NULL means no barcode in sigma_ean_master.
--   NULL barcode -> bucket forced to AMBIGUOUS.
--   product_codes are recycled in Sigma; barcode is the ONLY stable key.
--   Use split_part(barcode_list, '|', 1) as the StockFlow key.
--
-- NO VALUE FLOOR -- EVER:
--   This function has NO p_capital_floor parameter. Zero is the floor. Always.
--   Any attempt to add a floor parameter is a rule violation.
--
-- HOW TO RUN:
--   1. Run this file once (DROP + CREATE) to create the table.
--   2. Run refresh_l2_stock_count_plan.sql to create the refresh function.
--   3. Call: SELECT * FROM refresh_l2_stock_count_plan('21355');
--   4. Verify pool_total = HEALTHY + STOCKFLOW + TLX + AMBIGUOUS.
--   5. Run twice in same session on same store; JSONB summary must be identical.
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP TABLE IF EXISTS l2_stock_count_plan CASCADE;


CREATE TABLE l2_stock_count_plan (

    -- Primary key
    plan_id             uuid        DEFAULT gen_random_uuid() NOT NULL,

    -- Identity
    client_id           text,       -- matches l2_stock_position.client_id (text, not uuid)
    store_code          text        NOT NULL,
    product_code        bigint      NOT NULL,
    snapshot_date       date        NOT NULL,   -- CURRENT_DATE at refresh time

    -- Description (frozen at snapshot -- R22)
    description         text,
    subdept_name        text,
    dept_name           text,

    -- Stock state (frozen at snapshot -- R22)
    soh                 numeric,    -- includes negatives (gate is soh <> 0)
    capital_value       numeric,    -- display only -- NEVER a filter
    unit_cost           numeric,
    last_sale_date      date,
    last_receipt_date   date,

    -- Barcode -- the ONLY Sigma<->StockFlow key (recycled-code guard).
    -- product_codes are recycled in Sigma; barcode (EAN) is stable.
    -- NULL = no barcode in sigma_ean_master -> bucket forced to AMBIGUOUS.
    -- Pipe-separated when multiple EANs exist for this product.
    -- Use split_part(barcode_list, '|', 1) as the single StockFlow key.
    -- Use ALL pipe-separated values when building the TLX file.
    barcode_list        text,

    -- Routing signals stored for auditability (R22) and re-query without recompute
    sold_91d            boolean     NOT NULL DEFAULT FALSE,
    -- last_sale_date >= CURRENT_DATE-91 AND last_sale_date > 1990-01-01

    recv_365d           boolean     NOT NULL DEFAULT FALSE,
    -- last_receipt_date >= CURRENT_DATE-365 AND last_receipt_date > 1990-01-01

    deposit_like        boolean     NOT NULL DEFAULT FALSE,
    -- description OR subdept_name matches BOTTLE/CRATE/RETURN/EMPTIES/EMPTY/DEPOSIT/DEP
    -- Pending: full decode via S/G movement count (L1-001 S/O channel decode)

    -- Engine output -- every in-scope line gets exactly one bucket (R22)
    bucket              text        NOT NULL,
    -- CHECK constraint below enforces the four valid values

    bucket_reason       text,
    -- Human-readable routing rationale stored on every non-HEALTHY row.
    -- NULL for HEALTHY (no action needed).

    detected_at         timestamptz DEFAULT now(),

    -- Constraints
    PRIMARY KEY (plan_id),
    CONSTRAINT l2_scp_uq
        UNIQUE (store_code, product_code, snapshot_date),
    CONSTRAINT l2_scp_bucket_ck
        CHECK (bucket IN ('HEALTHY', 'STOCKFLOW', 'TLX', 'AMBIGUOUS'))
);


-- Indexes
CREATE INDEX idx_l2_scp_store_date
    ON l2_stock_count_plan (store_code, snapshot_date DESC);

CREATE INDEX idx_l2_scp_bucket
    ON l2_stock_count_plan (store_code, snapshot_date, bucket);

CREATE INDEX idx_l2_scp_actionable
    ON l2_stock_count_plan (store_code, snapshot_date, bucket, capital_value DESC)
    WHERE bucket IN ('STOCKFLOW', 'TLX', 'AMBIGUOUS');


COMMENT ON TABLE l2_stock_count_plan IS
    'Family 3 count-plan output. One row per (store, product, snapshot_date). '
    'All NORMAL soh<>0 articles bucketed: HEALTHY/STOCKFLOW/TLX/AMBIGUOUS. '
    'NO capital floor -- Pieter''s law: value is display-only, never a rule. '
    'Nightly refresh via refresh_l2_stock_count_plan(store_code). '
    'Runs alongside l2_anomaly_daily (different gate, different purpose). '
    'SB-CC-FAMILY3-COUNT-ENGINE-001. R21 + R22 compliant.';

COMMENT ON COLUMN l2_stock_count_plan.barcode_list IS
    'Pipe-separated EAN barcodes from sigma_ean_master. '
    'NULL = no barcode -> bucket forced to AMBIGUOUS (recycled-code guard). '
    'Use split_part(barcode_list,''|'',1) for StockFlow key. '
    'Use all values (split on |) for TLX file generation.';

COMMENT ON COLUMN l2_stock_count_plan.deposit_like IS
    'Heuristic: description or subdept_name matches deposit/crate/bottle/empties patterns. '
    'Pending full precision via S/G movement count decode (L1-001). '
    'Always routes to AMBIGUOUS -- deposits are never auto-zeroed.';

COMMENT ON COLUMN l2_stock_count_plan.capital_value IS
    'Stock on hand value at unit_cost. Display and reporting only. '
    'NEVER used as a filter or gate anywhere in this engine. '
    'Pieter''s law: value does not determine inclusion or routing.';


GRANT SELECT ON l2_stock_count_plan TO anon, authenticated;


-- =============================================================================
-- VERIFY after first refresh (determinism self-test):
--   Run refresh twice on the same store with no data changes between calls.
--   The JSONB summary must be identical both times.
-- =============================================================================
--
-- 1. Pool reconciliation (every row must be in exactly one bucket):
-- SELECT
--     bucket,
--     COUNT(*)                               AS rows,
--     ROUND(SUM(capital_value)::numeric, 0) AS capital_r,
--     ROUND(SUM(capital_value) * 100.0 /
--           SUM(SUM(capital_value)) OVER ()  , 1) AS capital_pct
-- FROM l2_stock_count_plan
-- WHERE store_code   = '21355'
--   AND snapshot_date = CURRENT_DATE
-- GROUP BY bucket
-- ORDER BY CASE bucket
--     WHEN 'HEALTHY'   THEN 1
--     WHEN 'STOCKFLOW' THEN 2
--     WHEN 'TLX'       THEN 3
--     WHEN 'AMBIGUOUS' THEN 4 END;
--
-- 2. Golden baseline check (2026-06-09 PM canonical):
--   21355: HEALTHY=708, STOCKFLOW=111, TLX=75,  AMBIGUOUS=54  pool=948
--   80176: HEALTHY=622, STOCKFLOW=112, TLX=84,  AMBIGUOUS=45  pool=863
--   80579: HEALTHY=478, STOCKFLOW=111, TLX=122, AMBIGUOUS=64  pool=775
--   If AMBIGUOUS diverges by >40 rows from canonical, check deposit_like filter.
--
-- 3. Recycled-code guard audit (no STOCKFLOW row should have NULL barcode):
-- SELECT COUNT(*) AS no_barcode_stockflow
-- FROM l2_stock_count_plan
-- WHERE store_code   = '21355'
--   AND snapshot_date = CURRENT_DATE
--   AND bucket        = 'STOCKFLOW'
--   AND barcode_list IS NULL;
-- -- Should be 0. Any row here = recycled-code risk; check manually before StockFlow load.
--
-- 4. TLX export query (pipe-split barcodes for file generator):
-- SELECT product_code, barcode_list, description, soh, capital_value
-- FROM l2_stock_count_plan
-- WHERE store_code   = '21355'
--   AND snapshot_date = CURRENT_DATE
--   AND bucket        = 'TLX'
-- ORDER BY capital_value DESC;
--
-- 5. AMBIGUOUS triage list (manual review, capital descending):
-- SELECT product_code, description, subdept_name, soh, capital_value,
--        last_sale_date, last_receipt_date, deposit_like, bucket_reason
-- FROM l2_stock_count_plan
-- WHERE store_code   = '21355'
--   AND snapshot_date = CURRENT_DATE
--   AND bucket        = 'AMBIGUOUS'
-- ORDER BY capital_value DESC;
-- =============================================================================
