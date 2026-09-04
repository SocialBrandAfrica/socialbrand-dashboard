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
-- CLASSIFIER NOTE (D1 amendment, 2026-06-07):
--   This MV now joins l2_item_classification to assign CLASS_EXCLUDED to
--   PRODUCTION, NON_STOCK, and RECEIPTING_BREAK articles (D1=B ruling;
--   SB-AP-L2-PM-BRIEF-001). Tier is the single authoritative source of
--   truth for all downstream consumers (R21: fix the general rule, not
--   each instance). l2_stock_position uses COALESCE(rt.tier, 'BOR')
--   directly -- no longer re-applies CLASS_EXCLUDED inline.
--   Gate 3 (classifier precision vs SB-AP-004 CSVs) remains open; this
--   amendment does not depend on Gate 3 closing because CLASS_EXCLUDED
--   is assigned from classifier verdict (not from product lists), and
--   articles with no classification row default to NORMAL (velocity tier).
--   Velocity ranks (value_rank, qty_rank) are still computed and stored
--   for CLASS_EXCLUDED articles so the engine retains the full signal.
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
        ros.client_id,
        ros.store_code,
        ros.product_code,
        ros.daily_ros_91d,
        ros.sales_qty_91d,
        ros.sales_value_incl_vat_91d,
        ros.never_sold,

        -- Value rank: higher value = lower rank number (1 = highest seller)
        DENSE_RANK() OVER (
            PARTITION BY ros.client_id, ros.store_code
            ORDER BY ros.sales_value_incl_vat_91d DESC, ros.sales_qty_91d DESC
        ) AS value_rank,

        -- Volume rank: higher qty = lower rank number (1 = highest unit seller)
        DENSE_RANK() OVER (
            PARTITION BY ros.client_id, ros.store_code
            ORDER BY ros.sales_qty_91d DESC, ros.sales_value_incl_vat_91d DESC
        ) AS qty_rank
    FROM l2_rate_of_sale ros
)

SELECT
    r.client_id,
    r.store_code,
    r.product_code,

    -- Tier verdict: CLASS_EXCLUDED overrides velocity tier for non-NORMAL classes.
    -- Class defaults to NORMAL for articles not yet in l2_item_classification.
    -- TOP_100 / TOP_1000 velocity guards apply only to NORMAL articles.
    -- sales_qty_91d > 0 guard prevents zero-sales articles from landing in
    -- TOP_1000 via DENSE_RANK on stores with fewer than 1000 active SKUs.
    CASE
        WHEN COALESCE(cl.class, 'NORMAL')
                 IN ('PRODUCTION', 'NON_STOCK', 'RECEIPTING_BREAK')
                                                THEN 'CLASS_EXCLUDED'
        WHEN r.value_rank <= 100 AND r.qty_rank <= 100
                                                THEN 'TOP_100'
        WHEN (r.value_rank <= 1000 OR r.qty_rank <= 1000)
             AND r.sales_qty_91d > 0            THEN 'TOP_1000'
        ELSE                                         'BOR'
    END::text                                   AS tier,

    -- Class carry-forward: makes CLASS_EXCLUDED verdict transparent to consumers.
    -- Defaults to 'NORMAL' for articles not yet in l2_item_classification.
    COALESCE(cl.class, 'NORMAL')::text          AS article_class,

    -- Both-list flag: explicit signal that the article qualifies from both rankings
    (r.value_rank <= 100 AND r.qty_rank <= 100) AS in_both_top100,

    -- Rank values for diagnostics and days-cover ordering
    r.value_rank,
    r.qty_rank,

    -- Carry-forward rate metrics needed by l2_kpi_daily (avoid a second join)
    r.daily_ros_91d,
    r.sales_qty_91d,
    r.sales_value_incl_vat_91d,
    r.never_sold,

    -- Refresh timestamp
    CURRENT_TIMESTAMP                           AS tiered_at

FROM ranked r
LEFT JOIN l2_item_classification cl
    ON  cl.client_id    = r.client_id
    AND cl.store_code   = r.store_code
    AND cl.product_code = r.product_code;


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
    E'GRADE: CALCULATED. Velocity tier from the 91-day value and volume rankings.
'
    'Per-article ranging tier from 91-day sales velocity + classifier class. '
    'CLASS_EXCLUDED = PRODUCTION / NON_STOCK / RECEIPTING_BREAK (D1 ruling, 2026-06-07). '
    'TOP_100 = in both top-100 by value AND volume (NORMAL only). '
    'TOP_1000 = in top-1000 by value OR volume, not TOP_100 (NORMAL only). '
    'BOR = Balance of Range -- outside top-1000 by both, or unclassified zero-sales. '
    'article_class carry-forward makes CLASS_EXCLUDED verdict transparent. '
    'Refresh nightly after l2_item_classification. SB-CC-L2-001 step 3 + D1 amendment. '
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
