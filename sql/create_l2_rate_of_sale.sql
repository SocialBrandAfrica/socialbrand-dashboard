-- =============================================================================
-- create_l2_rate_of_sale.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 1
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 1)
-- Version     : 1.0
-- Date        : 2026-06-07
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Source      : sigma_sales (dw220sdb.DBUmBA, Layer 1)
--               sigma_articles (dw220sdb.DBARTS) -- base population
--
-- WHAT THIS IS
--   Per-item rate-of-sale metrics materialised at nightly refresh time.
--   The 91-day window is the ranging-tier window (RULE-BOOK). The 14-day
--   window drives the slow-mover signal (SB-PM-002). Both are computed
--   relative to CURRENT_DATE at refresh time.
--
--   Base population: sigma_articles (all ranged items, incl. inactive).
--   Products with no sales in a window get qty = 0 and ros = 0.
--   Products that have NEVER sold have last_sale_date = NULL and
--   days_since_last_sale = NULL -- these are the never-sold signal
--   for the classifier (SB-CC-L2-001 gate 6).
--
-- KEY DESIGN DECISIONS
--   - sigma_sales stores only cPerKz='T' AND cVorKz=1 rows (extractor
--     filter). No additional filter needed in Layer 2.
--   - Multiple rows per (store_code, product_code, sale_date) exist because
--     the unique key includes cashier_nr. SUM aggregates across cashiers
--     correctly without double-counting (each row is one cashier's tally
--     for that day, not a duplicate of the day's total).
--   - LY ROS suppressed at this step. LY comparison requires shiftDate(-364)
--     and is materialised in l2_kpi_daily once a full year exists (mid-2027).
--   - Sentinel date 1990-01-01 does not appear in sigma_sales (it is a
--     lifecycle-table sentinel, handled in the classifier). sale_date in
--     sigma_sales is always a real trading date.
--
-- OBSERVED SCALE (10116, verified 2026-06-07):
--   sigma_sales:    2,125,469 rows  |  2025-02-01 to 2026-06-04
--   sigma_articles:    69,798 rows  |  distinct products on estate
--   products w/ sale in 91d: 9,671  |  14d: 6,816
--
-- HOW TO RUN
--   After l2_movements_typed exists. Drop + recreate (Rule 19).
--   REFRESH MATERIALIZED VIEW l2_rate_of_sale; -- nightly, after sigma_sales updated
-- =============================================================================


-- Drop and clean recreate (Rule 19: no ALTER workarounds)
DROP MATERIALIZED VIEW IF EXISTS l2_rate_of_sale CASCADE;


CREATE MATERIALIZED VIEW l2_rate_of_sale AS
WITH

-- 91-day rolling window (ranging-tier and days-cover window, RULE-BOOK)
ros_91d AS (
    SELECT
        client_id,
        store_code,
        product_code,
        SUM(qty)            AS sales_qty_91d,
        SUM(sales_incl_vat) AS sales_value_incl_vat_91d,
        COUNT(DISTINCT sale_date) AS trading_days_91d
    FROM sigma_sales
    WHERE sale_date >= CURRENT_DATE - 91
    GROUP BY client_id, store_code, product_code
),

-- 14-day rolling window (slow-mover signal: no sale in 14d = slow mover, SB-PM-002)
ros_14d AS (
    SELECT
        client_id,
        store_code,
        product_code,
        SUM(qty)            AS sales_qty_14d,
        SUM(sales_incl_vat) AS sales_value_incl_vat_14d
    FROM sigma_sales
    WHERE sale_date >= CURRENT_DATE - 14
    GROUP BY client_id, store_code, product_code
),

-- Last known sale date per product (all-time, not window-scoped)
-- NULL here means the product exists in sigma_articles but has never sold.
last_sale AS (
    SELECT
        client_id,
        store_code,
        product_code,
        MAX(sale_date) AS last_sale_date,
        MIN(sale_date) AS first_sale_date
    FROM sigma_sales
    GROUP BY client_id, store_code, product_code
)

SELECT
    -- Identity key (one row per article per store)
    a.client_id,
    a.store_code,
    a.product_code,

    -- 91-day metrics
    COALESCE(r91.sales_qty_91d, 0)              AS sales_qty_91d,
    COALESCE(r91.sales_value_incl_vat_91d, 0)   AS sales_value_incl_vat_91d,
    COALESCE(r91.trading_days_91d, 0)            AS trading_days_91d,
    -- Rate of sale: qty per calendar day over 91-day window
    -- This is the canonical rate used by l2_ranging_tier (RULE-BOOK R8)
    ROUND(COALESCE(r91.sales_qty_91d, 0) / 91.0, 6) AS daily_ros_91d,

    -- 14-day metrics
    COALESCE(r14.sales_qty_14d, 0)              AS sales_qty_14d,
    COALESCE(r14.sales_value_incl_vat_14d, 0)   AS sales_value_incl_vat_14d,
    ROUND(COALESCE(r14.sales_qty_14d, 0) / 14.0, 6) AS daily_ros_14d,

    -- Last-sale-date signals
    ls.last_sale_date,
    ls.first_sale_date,
    CASE
        WHEN ls.last_sale_date IS NOT NULL
        THEN (CURRENT_DATE - ls.last_sale_date)
        ELSE NULL
    END AS days_since_last_sale,

    -- Convenience booleans for downstream joins (avoids repeated CASE logic)
    (ls.last_sale_date IS NOT NULL AND ls.last_sale_date >= CURRENT_DATE - 14)
        AS has_sale_in_14d,
    (ls.last_sale_date IS NOT NULL AND ls.last_sale_date >= CURRENT_DATE - 91)
        AS has_sale_in_91d,
    (ls.last_sale_date IS NULL)
        AS never_sold,

    -- Refresh timestamp (baked in at REFRESH time, used for staleness checks)
    CURRENT_DATE AS computed_date

FROM sigma_articles a
LEFT JOIN ros_91d r91
    ON  r91.client_id    = a.client_id
    AND r91.store_code   = a.store_code
    AND r91.product_code = a.product_code
LEFT JOIN ros_14d r14
    ON  r14.client_id    = a.client_id
    AND r14.store_code   = a.store_code
    AND r14.product_code = a.product_code
LEFT JOIN last_sale ls
    ON  ls.client_id    = a.client_id
    AND ls.store_code   = a.store_code
    AND ls.product_code = a.product_code;


-- Primary key equivalent (unique per article per store)
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_ros_store_prod
    ON l2_rate_of_sale (client_id, store_code, product_code);

-- Rate-of-sale rank scan (l2_ranging_tier reads this sorted DESC)
CREATE INDEX IF NOT EXISTS idx_l2_ros_91d_rank
    ON l2_rate_of_sale (store_code, daily_ros_91d DESC);

-- Slow-mover flag scan (last_sale_date IS NOT NULL, no recent sale)
CREATE INDEX IF NOT EXISTS idx_l2_ros_lastsale
    ON l2_rate_of_sale (store_code, last_sale_date DESC NULLS LAST);

-- Never-sold scan (classifier: never-sold signal gate 6 measurement)
CREATE INDEX IF NOT EXISTS idx_l2_ros_neversold
    ON l2_rate_of_sale (store_code, never_sold)
    WHERE never_sold = TRUE;


COMMENT ON MATERIALIZED VIEW l2_rate_of_sale IS
    'Per-item rate of sale for 91-day and 14-day windows, computed at nightly '
    'refresh. Base: sigma_articles (all ranged items). Products with no sale '
    'in a window get qty=0 / ros=0. Never-sold products have last_sale_date=NULL. '
    'daily_ros_91d feeds l2_ranging_tier; days_since_last_sale feeds slow-mover '
    'and classifier (SB-CC-L2-001 step 1, SB-PM-002). ';


-- =============================================================================
-- VERIFY after first CREATE/REFRESH (run these as spot checks):
-- =============================================================================
-- -- Row count should match sigma_articles row count for same stores
-- SELECT store_code, COUNT(*) AS articles, COUNT(last_sale_date) AS ever_sold,
--        COUNT(*) FILTER (WHERE never_sold) AS never_sold,
--        ROUND(AVG(daily_ros_91d)::numeric, 4) AS avg_ros_91d
-- FROM l2_rate_of_sale
-- GROUP BY store_code;
--
-- -- Top 10 sellers (sanity: should be known high-volume items at SPAR)
-- SELECT product_code, daily_ros_91d, sales_qty_91d, last_sale_date
-- FROM l2_rate_of_sale
-- WHERE store_code = '10116'
-- ORDER BY daily_ros_91d DESC LIMIT 10;
-- =============================================================================
