-- =============================================================================
-- create_l2_soh_daily.sql
-- SocialBrand Intelligence Platform -- Layer 2, Gate 2 / l2_stock_position
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (Gate 2 Option A, approved 2026-06-07)
-- Version     : 1.0
-- Date        : 2026-06-08
-- Target      : Supabase (PostgreSQL), project socialbrand-data
--
-- WHAT THIS IS
--   Daily SOH history table. Populated by the extractor on each nightly delta
--   run. One row per article per store per day. The extractor writes this
--   snapshot from dw220sdb.DBStAr (the same source as sigma_lifecycle) with
--   snapshot_date = the run date, immediately before or alongside the
--   sigma_lifecycle UPSERT.
--
--   sigma_lifecycle holds the CURRENT state (one row per article, overwritten
--   nightly). l2_soh_daily holds the HISTORY (one row per article per day,
--   append-only via ON CONFLICT DO NOTHING).
--
-- GATE 2 DECISION (ratified PM 2026-06-07):
--   Option A -- daily DBStAr snapshot (approved). sigma_lifecycle.soh is the
--   authoritative post-reconciliation balance. Option B (reconstruct from
--   sigma_movements.new_soh) is demoted to reconciliation check only.
--
-- SCALE ESTIMATE:
--   ~65k articles x 5 stores = ~325k rows/day
--   13-month retention = ~130M rows (lean 5-column schema)
--   Storage: ~130M x ~60 bytes/row = ~7.8 GB (well within Supabase limits)
--
-- RETENTION:
--   13-month cap matches the global data retention policy. Purge via pg_cron
--   (same job as purge_old_snapshots if extended, or a separate l2 purge job).
--   Not implemented in this file -- add a pg_cron job when operationally ready.
--
-- POPULATED BY:
--   Invoke-ExtractFromSigmaSQL.ps1 -- Invoke-SnapshotSohDaily function.
--   Runs at start of each delta, snapshot_date = run date (YYYY-MM-DD).
--   ON CONFLICT DO NOTHING makes it safe to re-run on the same day.
-- =============================================================================


-- Not a view -- this is a persistent table (append-only history).
-- Drop entire table only if rebuilding from scratch; normally leave as-is.
-- ALTER TABLE approach is also fine for column additions (no DROP required
-- for additive schema changes; DROP required to fix broken definitions).

CREATE TABLE IF NOT EXISTS l2_soh_daily (
    client_id       text        NOT NULL,
    store_code      text        NOT NULL,
    product_code    bigint      NOT NULL,
    snapshot_date   date        NOT NULL,

    -- SOH from sigma_lifecycle.soh (dBestand in DBStAr):
    -- post-reconciliation EASYDB balance, used for capital tied and days cover.
    soh             numeric     NOT NULL,

    -- Standard stock target (dStdBest in DBStAr):
    -- the configured stock target for this article, used for days-cover baseline.
    standard_stock  numeric,

    -- Timestamp when this row was written by the extractor
    ingested_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT l2_soh_daily_pk
        PRIMARY KEY (client_id, store_code, product_code, snapshot_date)
);


-- Index for the main access pattern: SOH history for a product over time
-- (l2_stock_position, days-cover trend, capital tied by date).
CREATE INDEX IF NOT EXISTS idx_l2_soh_store_date
    ON l2_soh_daily (store_code, snapshot_date DESC);

-- Index for latest-date scan per store (capital tied KPI: latest SOH per store)
CREATE INDEX IF NOT EXISTS idx_l2_soh_latest
    ON l2_soh_daily (store_code, snapshot_date DESC, product_code);


COMMENT ON TABLE l2_soh_daily IS
    'Daily SOH history from DBStAr snapshots. One row per article per store per '
    'day. Written by the extractor (Invoke-SnapshotSohDaily). '
    'Append-only -- ON CONFLICT DO NOTHING. '
    'sigma_lifecycle holds current state; this table holds the history for '
    'capital tied, days cover, and SOH trend. '
    'Gate 2 Option A (SB-CC-L2-001). 13-month retention.';


-- =============================================================================
-- AFTER FIRST DATA LOADS (run these as spot checks):
-- =============================================================================
-- -- Row count and date range per store
-- SELECT store_code, COUNT(*) AS rows,
--        MIN(snapshot_date) AS first_snap,
--        MAX(snapshot_date) AS last_snap,
--        COUNT(DISTINCT snapshot_date) AS days
-- FROM l2_soh_daily
-- GROUP BY store_code
-- ORDER BY store_code;
--
-- -- Today's SOH should match sigma_lifecycle for same store
-- SELECT s.store_code, s.product_code,
--        s.soh AS soh_daily, l.soh AS lifecycle_soh,
--        s.soh - l.soh AS diff
-- FROM l2_soh_daily s
-- JOIN sigma_lifecycle l
--     ON  l.client_id    = s.client_id
--     AND l.store_code   = s.store_code
--     AND l.product_code = s.product_code
-- WHERE s.store_code     = '10116'
--   AND s.snapshot_date  = CURRENT_DATE
--   AND s.soh <> l.soh
-- LIMIT 10;
-- =============================================================================
