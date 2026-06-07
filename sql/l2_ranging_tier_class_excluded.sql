-- =============================================================================
-- l2_ranging_tier_class_excluded.sql
-- D1 AMENDMENT: add CLASS_EXCLUDED tier to l2_ranging_tier
-- Run in Supabase SQL Editor AFTER l2_rate_of_sale and l2_item_classification
-- are both live and refreshed.
-- =============================================================================
-- WHAT CHANGES:
--   l2_ranging_tier now joins l2_item_classification and returns
--   tier = 'CLASS_EXCLUDED' for PRODUCTION, NON_STOCK, and RECEIPTING_BREAK.
--   l2_stock_position simplifies its tier expression to COALESCE(rt.tier, 'BOR').
--   l2_kpi_daily DDL is unchanged -- it still reads from l2_stock_position.
--
-- WHY (R21 + D1 ruling):
--   Tier is the single authoritative source. Every consumer should read the
--   final verdict from l2_ranging_tier, not re-implement CLASS_EXCLUDED inline.
--   D1=B (SB-AP-L2-PM-BRIEF-001): CLASS_EXCLUDED from classifier verdict only.
--
-- ORDER:
--   Run steps 1-3 in order. Each DROP CASCADE removes the downstream MV
--   so the next CREATE starts clean.
-- =============================================================================

-- =============================================================================
-- STEP 1 -- l2_ranging_tier (joins l2_item_classification, adds CLASS_EXCLUDED)
-- Cascades: drops l2_stock_position + l2_kpi_daily automatically.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS l2_ranging_tier CASCADE;

CREATE MATERIALIZED VIEW l2_ranging_tier AS
WITH

ranked AS (
    SELECT
        ros.client_id,
        ros.store_code,
        ros.product_code,
        ros.daily_ros_91d,
        ros.sales_qty_91d,
        ros.sales_value_incl_vat_91d,
        ros.never_sold,
        DENSE_RANK() OVER (
            PARTITION BY ros.client_id, ros.store_code
            ORDER BY ros.sales_value_incl_vat_91d DESC, ros.sales_qty_91d DESC
        ) AS value_rank,
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

    COALESCE(cl.class, 'NORMAL')::text          AS article_class,
    (r.value_rank <= 100 AND r.qty_rank <= 100) AS in_both_top100,
    r.value_rank,
    r.qty_rank,
    r.daily_ros_91d,
    r.sales_qty_91d,
    r.sales_value_incl_vat_91d,
    r.never_sold,
    CURRENT_TIMESTAMP                           AS tiered_at

FROM ranked r
LEFT JOIN l2_item_classification cl
    ON  cl.client_id    = r.client_id
    AND cl.store_code   = r.store_code
    AND cl.product_code = r.product_code;


CREATE UNIQUE INDEX idx_l2_tier_pk
    ON l2_ranging_tier (client_id, store_code, product_code);

CREATE INDEX idx_l2_tier_store_tier
    ON l2_ranging_tier (store_code, tier);

CREATE INDEX idx_l2_tier_top100
    ON l2_ranging_tier (store_code)
    WHERE tier = 'TOP_100';

CREATE INDEX idx_l2_tier_value_rank
    ON l2_ranging_tier (store_code, value_rank);

COMMENT ON MATERIALIZED VIEW l2_ranging_tier IS
    'Per-article ranging tier from 91-day sales velocity + classifier class. '
    'CLASS_EXCLUDED = PRODUCTION / NON_STOCK / RECEIPTING_BREAK (D1 ruling, 2026-06-07). '
    'TOP_100 = in both top-100 by value AND volume (NORMAL only). '
    'TOP_1000 = in top-1000 by value OR volume, not TOP_100 (NORMAL only). '
    'BOR = Balance of Range. article_class carry-forward makes verdict transparent. '
    'Refresh nightly after l2_item_classification. SB-CC-L2-001 step 3 + D1 amendment.';


-- =============================================================================
-- STEP 2 -- l2_stock_position (simplified tier = COALESCE(rt.tier, 'BOR'))
-- Run immediately after step 1.
-- =============================================================================

-- (Paste full content of sql/create_l2_stock_position.sql here)
-- OR run the file separately -- DROP CASCADE above already cleared it.
-- Reminder: l2_stock_position.tier is now COALESCE(rt.tier, 'BOR') only.
-- No inline CLASS_EXCLUDED CASE needed -- l2_ranging_tier handles it.
-- File: sql/create_l2_stock_position.sql


-- =============================================================================
-- STEP 3 -- l2_kpi_daily (DDL unchanged -- recreate after step 2 dropped it)
-- File: sql/create_l2_kpi_daily.sql
-- =============================================================================


-- =============================================================================
-- STEP 4 -- REFRESH in order
-- Run only after all three CREATE steps succeed.
-- =============================================================================

REFRESH MATERIALIZED VIEW l2_ranging_tier;
-- Then: REFRESH MATERIALIZED VIEW l2_stock_position;
-- Then: REFRESH MATERIALIZED VIEW l2_kpi_daily;


-- =============================================================================
-- VERIFY after refresh:
-- =============================================================================
-- -- Tier distribution per store (CLASS_EXCLUDED should match non-NORMAL counts)
-- SELECT store_code, tier, article_class, COUNT(*) AS cnt
-- FROM l2_ranging_tier
-- GROUP BY store_code, tier, article_class
-- ORDER BY store_code, tier;
--
-- -- Quick sanity: CLASS_EXCLUDED tier must have non-NORMAL article_class only
-- SELECT COUNT(*) AS bad_rows
-- FROM l2_ranging_tier
-- WHERE tier = 'CLASS_EXCLUDED'
--   AND article_class = 'NORMAL';
-- -- expected: 0
--
-- -- Cross-check: l2_stock_position tier matches l2_ranging_tier
-- SELECT p.store_code,
--        COUNT(*) FILTER (WHERE p.tier <> COALESCE(rt.tier, 'BOR')) AS mismatch
-- FROM l2_stock_position p
-- LEFT JOIN l2_ranging_tier rt
--     ON rt.client_id = p.client_id AND rt.store_code = p.store_code
--    AND rt.product_code = p.product_code
-- GROUP BY p.store_code;
-- -- expected: 0 mismatches
-- =============================================================================

SELECT pg_notify('pgrst', 'reload schema');
