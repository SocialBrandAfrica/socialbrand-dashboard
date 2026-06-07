-- =============================================================================
-- create_l2_ranging_tier.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 3
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 3)
-- Version     : 1.0
-- Date        : 2026-06-08
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Source      : l2_rate_of_sale (step 1)
--
-- WHAT THIS IS
--   Per-article ranging tier assigned from 91-day sales velocity relative to
--   all other articles in the same store. One row per (client_id, store_code,
--   product_code). Reads l2_rate_of_sale; refreshes nightly after it.
--
--   Tiers (RULE-BOOK section 4 + constants TOP_TIER_RANK_CUTOFF=100,
--   MID_TIER_RANK_CUTOFF=1000):
--     TOP_100  -- in BOTH top-100 by value AND top-100 by volume (91d).
--                 Confirmed high-velocity lines; 15-day days-cover target.
--     TOP_1000 -- in top-1000 by value OR volume, but NOT in TOP_100.
--                 Mid-velocity lines; also 15-day target.
--     BOR      -- Balance of Range: outside top-1000 by both measures.
--                 Low-velocity or zero-sales lines. Variable days-cover target
--                 determined by pack size and delivery frequency.
--
--   Ranking uses DENSE_RANK so ties at a boundary are included (e.g. if 3
--   articles are tied for rank 100 by value, all 3 qualify for the value-100
--   list). RULE-BOOK describes thresholds as approximate.
--
--   Articles with zero 91-day sales (including never-sold) rank at the bottom
--   of both lists by DENSE_RANK and therefore always land in BOR.
--
-- CLASSIFIER NOTE:
--   This MV intentionally does NOT join l2_item_classification. Gate 3
--   (classifier precision against SB-AP-004 label CSVs) is still open; no
--   wiring until it is closed. Production/NON_STOCK articles naturally fall
--   to BOR because they have zero or negligible sales. The KPI mart
--   (l2_kpi_daily, step 4) will join both this MV and the classifier to
--   exclude PRODUCTION/NON_STOCK from capital-tied-by-tier.
--
-- HOW TO RUN:
--   Prerequisites: l2_rate_of_sale must exist and be refreshed.
--   Drop + recreate (Rule 19). Run after l2_rate_of_sale REFRESH.
--   REFRESH MATERIALIZED VIEW l2_ranging_tier;
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP MATERIALIZED VIEW IF EXISTS l2_ranging_tier CASCADE;


CREATE MATERIALIZED VIEW l2_ranging_tier AS
WITH

-- Rank all articles per store by 91-day sales value and volume.
-- Articles with zero sales get value/qty = 0 and rank at the bottom.
ranked AS (
    SELECT
        client_id,
        store_code,
        product_code,
        daily_ros_91d,
        sales_qty_91d,
        sales_value_incl_vat_91d,
        never_sold,

        -- Value rank: higher value = lower rank number (1 = highest seller)
        DENSE_RANK() OVER (
            PARTITION BY client_id, store_code
            ORDER BY sales_value_incl_vat_91d DESC, sales_qty_91d DESC
        ) AS value_rank,

        -- Volume rank: higher qty = lower rank number (1 = highest unit seller)
        DENSE_RANK() OVER (
            PARTITION BY client_id, store_code
            ORDER BY sales_qty_91d DESC, sales_value_incl_vat_91d DESC
        ) AS qty_rank
    FROM l2_rate_of_sale
)

SELECT
    client_id,
    store_code,
    product_code,

    -- Tier verdict (TOP_100 > TOP_1000 > BOR)
    CASE
        WHEN value_rank <= 100 AND qty_rank <= 100 THEN 'TOP_100'
        WHEN value_rank <= 1000 OR qty_rank <= 1000 THEN 'TOP_1000'
        ELSE                                              'BOR'
    END::text                                   AS tier,

    -- Both-list flag: explicit signal that the article qualifies from both rankings
    (value_rank <= 100 AND qty_rank <= 100)     AS in_both_top100,

    -- Rank values for diagnostics and days-cover ordering
    value_rank,
    qty_rank,

    -- Carry-forward rate metrics needed by l2_kpi_daily (avoid a second join)
    daily_ros_91d,
    sales_qty_91d,
    sales_value_incl_vat_91d,
    never_sold,

    -- Refresh timestamp
    CURRENT_TIMESTAMP                           AS tiered_at

FROM ranked;


-- Indexes for the three primary access patterns:
--   1. KPI join: (client_id, store_code, product_code) -> tier
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_tier_pk
    ON l2_ranging_tier (client_id, store_code, product_code);

--   2. Tier sweep: all articles of a given tier in a store
CREATE INDEX IF NOT EXISTS idx_l2_tier_store_tier
    ON l2_ranging_tier (store_code, tier);

--   3. Top-100 fast path (capital tied + days cover by top tier)
CREATE INDEX IF NOT EXISTS idx_l2_tier_top100
    ON l2_ranging_tier (store_code)
    WHERE tier = 'TOP_100';

--   4. Value rank scan (sorted capital tied report)
CREATE INDEX IF NOT EXISTS idx_l2_tier_value_rank
    ON l2_ranging_tier (store_code, value_rank);


COMMENT ON MATERIALIZED VIEW l2_ranging_tier IS
    'Per-article ranging tier from 91-day sales velocity. '
    'TOP_100 = in both top-100 by value AND volume. '
    'TOP_1000 = in top-1000 by value OR volume (not TOP_100). '
    'BOR = Balance of Range (outside top-1000 by both). '
    'Refresh nightly after l2_rate_of_sale. SB-CC-L2-001 step 3. '
    'RULE-BOOK section 4 + constants TOP_TIER_RANK_CUTOFF=100 / MID_TIER_RANK_CUTOFF=1000.';


-- =============================================================================
-- VERIFY after first REFRESH (run these as spot checks):
-- =============================================================================
-- -- Tier distribution per store
-- SELECT store_code, tier, COUNT(*) AS cnt,
--        COUNT(*) FILTER (WHERE never_sold) AS never_sold_in_tier,
--        ROUND(AVG(daily_ros_91d)::numeric, 4) AS avg_ros
-- FROM l2_ranging_tier
-- GROUP BY store_code, tier
-- ORDER BY store_code, tier;
--
-- -- Sanity: TOP_100 articles should appear in both value and qty lists
-- SELECT store_code, COUNT(*) AS top100_count,
--        COUNT(*) FILTER (WHERE in_both_top100) AS both_confirmed
-- FROM l2_ranging_tier
-- WHERE tier = 'TOP_100'
-- GROUP BY store_code;
--
-- -- Top 5 by value rank on 10116 (should be known high-velocity SPAR lines)
-- SELECT product_code, tier, value_rank, qty_rank,
--        ROUND(daily_ros_91d::numeric, 4) AS ros,
--        ROUND(sales_value_incl_vat_91d::numeric, 0) AS value_91d
-- FROM l2_ranging_tier
-- WHERE store_code = '10116'
-- ORDER BY value_rank LIMIT 5;
-- =============================================================================
