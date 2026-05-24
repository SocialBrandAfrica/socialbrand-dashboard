-- =============================================================================
-- SB-RET-002 -- Step 1: quarterly_aggregates table + indexes
--
-- Cold-tier storage for rows aged out of daily_snapshots.
-- One row per (store_code, ean, year_month) -- ~30:1 compression vs daily rows.
--
-- Run BEFORE sb_ret_002_purge_function_v2.sql.
-- Safe to re-run (CREATE TABLE IF NOT EXISTS).
--
-- Decision basis: SB-RET-002-BRIEF-2026-05-24.md (PM approved 2026-05-24)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.quarterly_aggregates (
    id             bigserial     PRIMARY KEY,
    store_code     text          NOT NULL,
    ean            text          NOT NULL,
    year_month     date          NOT NULL,  -- always DATE_TRUNC('month', snapshot_date) -- 1st of month
    total_sales    numeric       NOT NULL DEFAULT 0,
    total_qty      integer       NOT NULL DEFAULT 0,
    days_with_data integer       NOT NULL DEFAULT 0,  -- how many daily rows were aggregated
    avg_soh        numeric,
    min_price      numeric,
    max_price      numeric,
    description    text,                              -- product name, from daily rows
    aggregated_at  timestamptz   NOT NULL DEFAULT now(),

    UNIQUE (store_code, ean, year_month)
);

CREATE INDEX IF NOT EXISTS quarterly_aggregates_store_month_idx
    ON public.quarterly_aggregates (store_code, year_month);

CREATE INDEX IF NOT EXISTS quarterly_aggregates_ean_idx
    ON public.quarterly_aggregates (ean);

-- Verify
SELECT
    table_name,
    (SELECT COUNT(*) FROM public.quarterly_aggregates) AS row_count
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name   = 'quarterly_aggregates';
-- Expected: 1 row, row_count = 0 (empty on first run)
