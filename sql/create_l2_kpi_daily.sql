-- =============================================================================
-- create_l2_kpi_daily.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 4
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 4)
-- Version     : 1.2
-- Date        : 2026-06-08
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Sources     : l2_stock_position (step 3b), sigma_sales (DBUMBA, L1)
--               [Phase 1, SB-INDEX-005: daily_snapshots no longer used for sales]
--
-- WHAT THIS IS
--   One row per store. Point-in-time daily summary of the engine's current
--   verdict on each store. Refreshed nightly after all step 1-3b MVs are
--   refreshed and after the L1 sigma_sales extract completes.
--
--   This is the primary source for L3 analytics, trend intelligence, and the
--   dashboard's store-level KPI cards (Capital Tied, signal counts, days cover).
--   It does NOT replace mv_kpi_by_date / v_kpi_by_date for the existing sales
--   KPI cards (Total Sales, GP%) -- those continue as-is.
--
-- R21 COMPLIANCE (RULE-BOOK §12):
--   All four article classes flow through. Capital is broken out by class so the
--   engine can track ghost capital and deposit accumulation trends over time.
--   Tier-based capital uses NORMAL class only (CLASS_EXCLUDED articles have no
--   retail ranging tier). Signal counts surface every category -- nothing hidden.
--
-- CAPITAL NOTE (Decision 2-B, SB-AP-L2-PM-BRIEF-001):
--   Dashboard headline = capital_normal (orderable, buy-and-sell stock only).
--   capital_production, capital_non_stock, capital_receipting_break are stored
--   as background columns for intelligence and cleanup trend verification.
--   capital_total = sum of all four classes.
--
-- GP% NOTE (SB-INDEX-005 Option B, enabled 2026-06-08):
--   gp_pct and sales_cost now use sigma_sales.cost_value (dEKUmsatz from DBUmBA).
--   cost_value is 100% populated on all 5 stores from 2025-02-01 to present --
--   the extractor has always extracted dEKUmsatz; it was never a missing field.
--   Plausibility verified 2026-06-08: SPAR stores 15-20%, TOPS 11-16%; all in
--   realistic South African food/liquor retail range.
--   PRSSALE today_cost is NOT a valid cross-reference: pack_size-induced errors
--   inflate it by ~2800x vs sigma (e.g. SPAR Milk 6-pack -11.9% GP in PRSSALE).
--   VAT divisor is flat 1.15 until per-item siMWST is ingested (L1-001 Step 3).
--   Dashboard authoritative GP% remains v_kpi_by_date (Phase 2 brief).
--
-- HOW TO RUN:
--   Run after REFRESH of l2_rate_of_sale, l2_item_classification,
--   l2_ranging_tier and l2_stock_position. sigma_sales must have today's
--   rows (pushed by nightly extractor) before REFRESH. Safe to re-run (DROP + CREATE).
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP MATERIALIZED VIEW IF EXISTS l2_kpi_daily CASCADE;


CREATE MATERIALIZED VIEW l2_kpi_daily AS
WITH

-- ---------------------------------------------------------------------------
-- Stock aggregation: collapse l2_stock_position to one row per store.
-- All signals and capital buckets computed here.
-- ---------------------------------------------------------------------------
stock_agg AS (
    SELECT
        client_id,
        store_code,

        -- Article counts by class
        COUNT(*)                                                         AS total_articles,
        COUNT(*) FILTER (WHERE class = 'NORMAL')                        AS articles_normal,
        COUNT(*) FILTER (WHERE class = 'PRODUCTION')                    AS articles_production,
        COUNT(*) FILTER (WHERE class = 'NON_STOCK')                     AS articles_non_stock,
        COUNT(*) FILTER (WHERE class = 'RECEIPTING_BREAK')              AS articles_receipting_break,

        -- Active sellers: NORMAL class that had sales in the 91-day window
        COUNT(*) FILTER (WHERE class = 'NORMAL' AND sales_qty_91d > 0)  AS active_sellers,

        -- In-stock NORMAL articles with positive SOH
        COUNT(*) FILTER (WHERE class = 'NORMAL' AND soh > 0)            AS articles_in_stock,

        -- Capital by class (Decision 2-B: all four classes preserved)
        COALESCE(SUM(capital_value) FILTER (WHERE class = 'NORMAL'),            0)
            AS capital_normal,
        COALESCE(SUM(capital_value) FILTER (WHERE class = 'PRODUCTION'),        0)
            AS capital_production,
        COALESCE(SUM(capital_value) FILTER (WHERE class = 'NON_STOCK'),         0)
            AS capital_non_stock,
        COALESCE(SUM(capital_value) FILTER (WHERE class = 'RECEIPTING_BREAK'),  0)
            AS capital_receipting_break,
        COALESCE(SUM(capital_value),                                            0)
            AS capital_total,

        -- Capital by tier (NORMAL retail tiers only; CLASS_EXCLUDED is not a
        -- retail tier so those articles contribute zero here by design)
        COALESCE(SUM(capital_value) FILTER (WHERE tier = 'TOP_100'),    0) AS capital_top100,
        COALESCE(SUM(capital_value) FILTER (WHERE tier = 'TOP_1000'),   0) AS capital_top1000,
        COALESCE(SUM(capital_value) FILTER (WHERE tier = 'BOR'),        0) AS capital_bor,

        -- Ghost stock (PRODUCTION with positive SOH and cost)
        -- Value is unreliable as a financial figure (SOH may be in grams/ml,
        -- cost per kg/bag). Use count and value for trend tracking only.
        COUNT(*) FILTER (WHERE ghost_stock_flag)                         AS ghost_stock_count,
        COALESCE(SUM(ghost_stock_value),                                0) AS ghost_stock_value,

        -- Capital-weighted days cover: capital / (daily_ros * unit_cost)
        -- = days of orderable stock at current rate of sale.
        -- NULL when no active sellers have cost data.
        COALESCE(
            SUM(capital_value)
                FILTER (WHERE class = 'NORMAL' AND daily_ros > 0 AND unit_cost IS NOT NULL)
            /
            NULLIF(
                SUM(daily_ros * unit_cost)
                    FILTER (WHERE class = 'NORMAL' AND daily_ros > 0 AND unit_cost IS NOT NULL),
                0
            ),
            NULL
        ) AS days_cover_normal_wtd,

        COALESCE(
            SUM(capital_value)
                FILTER (WHERE tier = 'TOP_100' AND daily_ros > 0 AND unit_cost IS NOT NULL)
            /
            NULLIF(
                SUM(daily_ros * unit_cost)
                    FILTER (WHERE tier = 'TOP_100' AND daily_ros > 0 AND unit_cost IS NOT NULL),
                0
            ),
            NULL
        ) AS days_cover_top100_wtd,

        COALESCE(
            SUM(capital_value)
                FILTER (WHERE tier = 'TOP_1000' AND daily_ros > 0 AND unit_cost IS NOT NULL)
            /
            NULLIF(
                SUM(daily_ros * unit_cost)
                    FILTER (WHERE tier = 'TOP_1000' AND daily_ros > 0 AND unit_cost IS NOT NULL),
                0
            ),
            NULL
        ) AS days_cover_top1000_wtd,

        -- Signal counts: all signals surfaced, nothing hidden (R21)
        COUNT(*) FILTER (WHERE reorder_signal)          AS reorder_count,
        COUNT(*) FILTER (WHERE slow_mover_signal)        AS slow_mover_count,
        -- neg_soh_count = NORMAL-scope (Family 3B integrity outliers, R21).
        -- neg_soh_count_all = canon RULE-BOOK §5 KPI 5: ALL classes, pure soh<0
        -- (incl. Stock-Integrity Type-A production negatives). The dashboard
        -- Negative SOH card headline reads neg_soh_count_all (ledger truth);
        -- neg_soh_count stays for the engine's NORMAL integrity sweep.
        COUNT(*) FILTER (WHERE neg_soh_signal)           AS neg_soh_count,
        COUNT(*) FILTER (WHERE soh < 0)                  AS neg_soh_count_all,
        COUNT(*) FILTER (WHERE investigate_stock_flag)   AS investigate_stock_count,
        COUNT(*) FILTER (WHERE stale_ledger_flag)        AS stale_ledger_count,
        COUNT(*) FILTER (WHERE cost_sanity_flag)         AS cost_sanity_count

    FROM l2_stock_position
    GROUP BY client_id, store_code
),

-- ---------------------------------------------------------------------------
-- Sales aggregation: latest sigma_sales (DBUMBA) day per store.
-- Phase 1 of SB-INDEX-005: sigma_sales replaces daily_snapshots for revenue
-- so a missed store EOD never creates a silent hole in l2_kpi_daily.
-- Filter: period_kind='T' AND txn_kind=1 (sales rows only, same as L2 pipeline).
-- Option B (2026-06-08): sales_cost = dEKUmsatz; gp_pct = ex-VAT margin.
-- ---------------------------------------------------------------------------
latest_sigma_day AS (
    SELECT
        store_code,
        MAX(sale_date) AS latest_date
    FROM sigma_sales
    WHERE period_kind = 'T'
      AND txn_kind    = 1
    GROUP BY store_code
),

sales_agg AS (
    SELECT
        s.store_code,
        lsd.latest_date                               AS sales_date,
        COALESCE(SUM(s.sales_incl_vat), 0)            AS sales_incl_vat,
        -- sales_cost: dEKUmsatz (SB-INDEX-005 Option B, enabled 2026-06-08)
        COALESCE(SUM(s.cost_value),     0)            AS sales_cost,
        COALESCE(SUM(s.qty),            0)            AS sales_qty,
        -- gp_pct: (revenue_ex_vat - cost) / revenue_ex_vat. Flat 1.15 VAT divisor
        --   until per-item siMWST is ingested (L1-001 Step 3).
        CASE WHEN SUM(s.sales_incl_vat) > 0
             THEN ROUND(
                    ((SUM(s.sales_incl_vat) / 1.15 - COALESCE(SUM(s.cost_value), 0))
                     / NULLIF(SUM(s.sales_incl_vat) / 1.15, 0))::numeric,
                    4)
             ELSE NULL
        END                                           AS gp_pct
    FROM sigma_sales s
    INNER JOIN latest_sigma_day lsd
        ON  lsd.store_code  = s.store_code
        AND lsd.latest_date = s.sale_date
    WHERE s.period_kind = 'T'
      AND s.txn_kind    = 1
    GROUP BY s.store_code, lsd.latest_date
)

-- ---------------------------------------------------------------------------
-- Final output: one row per store
-- ---------------------------------------------------------------------------
SELECT
    sa.client_id,
    sa.store_code,
    CURRENT_DATE                                 AS positioned_at,

    -- Sales (latest push date for this store)
    sl.sales_date,
    sl.sales_incl_vat,
    sl.sales_cost,
    sl.sales_qty,
    sl.gp_pct,

    -- Article counts
    sa.total_articles,
    sa.articles_normal,
    sa.articles_production,
    sa.articles_non_stock,
    sa.articles_receipting_break,
    sa.active_sellers,
    sa.articles_in_stock,

    -- Capital by class (all four classes, per R21 Decision 2-B)
    sa.capital_normal,
    sa.capital_production,
    sa.capital_non_stock,
    sa.capital_receipting_break,
    sa.capital_total,

    -- Capital by retail tier (NORMAL class orderable stock only)
    sa.capital_top100,
    sa.capital_top1000,
    sa.capital_bor,

    -- Ghost stock trend (for cleanup verification, not financial reporting)
    sa.ghost_stock_count,
    sa.ghost_stock_value,

    -- Capital-weighted days cover
    ROUND(sa.days_cover_normal_wtd::numeric,   1) AS days_cover_normal_wtd,
    ROUND(sa.days_cover_top100_wtd::numeric,   1) AS days_cover_top100_wtd,
    ROUND(sa.days_cover_top1000_wtd::numeric,  1) AS days_cover_top1000_wtd,

    -- Signal counts (all surfaces, nothing hidden — R21)
    sa.reorder_count,
    sa.slow_mover_count,
    sa.neg_soh_count,
    sa.neg_soh_count_all,
    sa.investigate_stock_count,
    sa.stale_ledger_count,
    sa.cost_sanity_count

FROM stock_agg sa
LEFT JOIN sales_agg sl ON sl.store_code = sa.store_code;


-- Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_kpi_daily_pk
    ON l2_kpi_daily (client_id, store_code);

CREATE INDEX IF NOT EXISTS idx_l2_kpi_daily_capital
    ON l2_kpi_daily (store_code, capital_normal DESC);

CREATE INDEX IF NOT EXISTS idx_l2_kpi_daily_sales_date
    ON l2_kpi_daily (store_code, sales_date);


COMMENT ON MATERIALIZED VIEW l2_kpi_daily IS
    'Daily store-level intelligence summary. Step 4 in L2 build order. '
    'One row per store. Stock/capital source: l2_stock_position. '
    'Sales source: sigma_sales (DBUMBA, SB-INDEX-005 Phase 1 + Option B 2026-06-08). '
    'gp_pct = (revenue_ex_vat - dEKUmsatz) / revenue_ex_vat; flat-1.15 VAT divisor. '
    'capital_normal is the headline capital KPI (NORMAL class orderable stock). '
    'All four class capitals stored for trend intelligence (R21, Decision 2-B). '
    'Refresh nightly after all step 1-3b MVs and after sigma_sales extract. SB-CC-L2-001.';

GRANT SELECT ON l2_kpi_daily TO anon, authenticated;


-- =============================================================================
-- VERIFY after first REFRESH:
-- =============================================================================
-- SELECT
--     store_code,
--     sales_date,
--     ROUND(sales_incl_vat::numeric, 0)            AS sales,
--     ROUND(gp_pct * 100, 1)                       AS gp_pct,
--     articles_normal,
--     active_sellers,
--     ROUND(capital_normal::numeric, 0)            AS capital_normal,
--     ROUND(capital_production::numeric, 0)        AS capital_production,
--     ROUND(capital_non_stock::numeric, 0)         AS capital_non_stock,
--     ROUND(capital_top100::numeric, 0)            AS capital_top100,
--     days_cover_normal_wtd,
--     reorder_count,
--     slow_mover_count,
--     neg_soh_count,
--     ghost_stock_count,
--     stale_ledger_count,
--     cost_sanity_count
-- FROM l2_kpi_daily
-- ORDER BY store_code;
-- =============================================================================
