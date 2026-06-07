-- =============================================================================
-- create_l2_stock_position.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 3b
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 3b)
-- Version     : 1.0
-- Date        : 2026-06-09
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Sources     : sigma_articles, sigma_departments, sigma_subdepts,
--               sigma_lifecycle, sigma_supplier_link,
--               l2_rate_of_sale (step 1), l2_ranging_tier (step 3),
--               l2_item_classification (step 2), l2_soh_daily (gate 2)
--
-- WHAT THIS IS
--   Current stock position per article per store. One row per
--   (client_id, store_code, product_code). This is the article-level bridge
--   between raw Sigma facts and the KPI mart (l2_kpi_daily, step 4).
--   l2_kpi_daily aggregates this view by store + date; it never re-derives
--   classification, tier, or days-cover logic inline.
--
-- KEY COLUMNS:
--   soh              -- current stock (sigma_lifecycle, refreshed nightly)
--   unit_cost        -- list cost from active supplier link (sigma_supplier_link)
--   capital_value    -- soh * unit_cost (positive SOH only)
--   daily_ros        -- 91-day rate of sale (l2_rate_of_sale)
--   days_cover       -- soh / daily_ros (NULL when ros = 0)
--   tier             -- TOP_100 / TOP_1000 / BOR (l2_ranging_tier)
--   class            -- NORMAL / PRODUCTION / NON_STOCK / RECEIPTING_BREAK
--                       (l2_item_classification)
--   reorder_signal   -- NORMAL + soh <= 0 + had sales in 91d
--   slow_mover_signal-- NORMAL + soh > 0 + no sale in 14d + active line
--   ghost_stock_flag    -- PRODUCTION class only with positive SOH (physically impossible)
--   investigate_stock_flag -- NON_STOCK with positive SOH (bags/vouchers/returnables)
--   stale_ledger_flag   -- NORMAL + soh>0 + no receipt 2yr + no recent sales (deposit artefacts)
--   cost_sanity_flag    -- unit_cost > sell price (pack_size=1 bug in sigma_supplier_link)
--   soh_delta           -- soh today vs yesterday (NULL until l2_soh_daily has data)
--
-- COST SOURCE NOTE:
--   unit_cost is sourced from sigma_supplier_link (list_cost) via DISTINCT ON
--   selecting the most recently valid active supplier link. This is the best
--   available L2 cost source. It may differ from daily_snapshots.unit_cost
--   (which reflects the last PRSSALE push price). The two pipelines are
--   intentionally independent -- L2 cost is Sigma-native; L1 cost is PRSSALE.
--
-- SOH DELTA NOTE:
--   soh_delta is NULL until l2_soh_daily holds at least one prior-day snapshot.
--   The MV can be created and deployed immediately -- the delta column fills in
--   automatically from the second nightly push onwards.
--
-- HOW TO RUN:
--   Prerequisites: all source tables and MVs must exist.
--   l2_soh_daily may be empty (soh_delta will be NULL -- not an error).
--   Drop + recreate (Rule 19). REFRESH after all step-1/2/3 MVs are refreshed.
--   Run nightly after l2_ranging_tier + l2_item_classification.
-- =============================================================================


-- Drop and clean recreate (Rule 19)
DROP MATERIALIZED VIEW IF EXISTS l2_stock_position CASCADE;


CREATE MATERIALIZED VIEW l2_stock_position AS
WITH

-- Best cost per article: active supplier link, most recently valid.
-- DISTINCT ON picks one row per (client_id, store_code, product_code).
-- Inactive links (status = 'I') excluded; NULL status retained (no status set).
-- list_cost (dEKL) in sigma_supplier_link is cost per ORDER PACK (case),
-- not per selling unit. Divide by pack_size to get the per-unit cost.
-- NULL when pack_size is NULL or 0 (unit unknown -- safer than using wrong cost).
best_cost AS (
    SELECT DISTINCT ON (client_id, store_code, product_code)
        client_id,
        store_code,
        product_code,
        CASE WHEN pack_size > 0
             THEN list_cost / pack_size
             ELSE NULL
        END AS list_cost,
        supplier_nr,
        pack_size
    FROM sigma_supplier_link
    WHERE status IS DISTINCT FROM 'I'
    ORDER BY client_id, store_code, product_code,
             valid_from DESC NULLS LAST,
             pack_size ASC NULLS LAST
),

-- Yesterday's SOH: latest l2_soh_daily snapshot before today.
-- Returns NULL for all columns until l2_soh_daily is populated (first night).
yesterday_soh AS (
    SELECT DISTINCT ON (client_id, store_code, product_code)
        client_id,
        store_code,
        product_code,
        soh            AS soh_yesterday,
        snapshot_date  AS soh_yesterday_date
    FROM l2_soh_daily
    WHERE snapshot_date < CURRENT_DATE
    ORDER BY client_id, store_code, product_code,
             snapshot_date DESC
)

SELECT
    a.client_id,
    a.store_code,
    a.product_code,
    a.description,
    a.sell_price_incl_vat,
    a.vat_code,
    a.department_nr,
    COALESCE(d.name, '')   AS dept_name,
    a.merch_group_nr,
    sd.name                AS subdept_name,
    a.plu_flag,
    a.scale_flag,
    a.article_type,

    -- -------------------------------------------------------------------------
    -- Current SOH (sigma_lifecycle, refreshed nightly from DBStAr)
    -- -------------------------------------------------------------------------
    COALESCE(lc.soh, 0)    AS soh,
    lc.standard_stock,
    lc.last_sale_date,
    lc.first_sale_date,
    lc.last_receipt_date,
    lc.last_inv_date,
    lc.last_inv_soh,

    -- -------------------------------------------------------------------------
    -- SOH delta (NULL until l2_soh_daily has prior-day data)
    -- -------------------------------------------------------------------------
    ys.soh_yesterday,
    ys.soh_yesterday_date,
    CASE
        WHEN ys.soh_yesterday IS NOT NULL
        THEN COALESCE(lc.soh, 0) - ys.soh_yesterday
        ELSE NULL
    END                    AS soh_delta,

    -- -------------------------------------------------------------------------
    -- Cost and capital (sigma_supplier_link)
    -- -------------------------------------------------------------------------
    bc.list_cost           AS unit_cost,
    bc.supplier_nr,
    bc.pack_size,

    -- Capital tied: positive SOH only (negative SOH = no capital held)
    CASE
        WHEN COALESCE(lc.soh, 0) > 0 AND bc.list_cost IS NOT NULL
        THEN COALESCE(lc.soh, 0) * bc.list_cost
        ELSE 0
    END                    AS capital_value,

    -- -------------------------------------------------------------------------
    -- Rate of sale (l2_rate_of_sale, 91-day window)
    -- -------------------------------------------------------------------------
    COALESCE(ros.daily_ros_91d, 0)           AS daily_ros,
    COALESCE(ros.sales_qty_91d, 0)           AS sales_qty_91d,
    COALESCE(ros.sales_value_incl_vat_91d, 0) AS sales_value_91d,
    COALESCE(ros.never_sold, TRUE)           AS never_sold,

    -- Days cover: NULL when ros = 0 or SOH <= 0 (show '--' in UI)
    CASE
        WHEN COALESCE(ros.daily_ros_91d, 0) > 0
             AND COALESCE(lc.soh, 0) > 0
        THEN COALESCE(lc.soh, 0) / ros.daily_ros_91d
        ELSE NULL
    END                    AS days_cover,

    -- -------------------------------------------------------------------------
    -- Ranging tier (l2_ranging_tier)
    -- D1 amendment (2026-06-07): CLASS_EXCLUDED is now assigned in
    -- l2_ranging_tier itself (joins l2_item_classification there).
    -- l2_stock_position receives the final tier directly -- no inline override.
    -- Default BOR for articles not yet in l2_ranging_tier (new lines).
    -- -------------------------------------------------------------------------
    COALESCE(rt.tier, 'BOR')   AS tier,
    rt.value_rank,
    rt.qty_rank,
    rt.in_both_top100,

    -- -------------------------------------------------------------------------
    -- Classification (l2_item_classification)
    -- Default NORMAL if no row (new article not yet classified)
    -- -------------------------------------------------------------------------
    COALESCE(cl.class, 'NORMAL')   AS class,
    COALESCE(cl.confidence, 0.99)  AS confidence,
    cl.signals,
    cl.reason                      AS class_reason,

    -- -------------------------------------------------------------------------
    -- Derived signals (pre-computed for l2_kpi_daily aggregation)
    -- -------------------------------------------------------------------------

    -- Reorder: NORMAL + out of stock + active seller (had qty in 91d)
    (    COALESCE(cl.class, 'NORMAL') = 'NORMAL'
     AND COALESCE(lc.soh, 0) <= 0
     AND COALESCE(ros.sales_qty_91d, 0) > 0
    )                      AS reorder_signal,

    -- Slow mover: NORMAL + in stock + no sale in 14d + active line
    -- 14-day window is fixed (RULE-BOOK section 5, KPI 4)
    (    COALESCE(cl.class, 'NORMAL') = 'NORMAL'
     AND COALESCE(lc.soh, 0) > 0
     AND (    lc.last_sale_date IS NULL
           OR lc.last_sale_date < CURRENT_DATE - 14
         )
     AND COALESCE(ros.sales_qty_91d, 0) > 0
    )                      AS slow_mover_signal,

    -- Negative SOH: NORMAL + soh < 0 (stock integrity signal, RULE-BOOK KPI 5)
    -- Scale items (scale_flag='1') are Type A (auto-depletion); non-scale are Type B
    (    COALESCE(cl.class, 'NORMAL') = 'NORMAL'
     AND COALESCE(lc.soh, 0) < 0
    )                      AS neg_soh_signal,

    -- Ghost stock: PRODUCTION class with positive SOH only.
    -- Definition: stock that physically CANNOT be on hand as discrete units --
    -- production raw material inputs consumed during production, not sold at POS.
    -- NON_STOCK excluded: bags are physically received (real stock, possible
    -- miscount); virtual vouchers and returnables need separate investigation.
    (    COALESCE(cl.class, 'NORMAL') = 'PRODUCTION'
     AND COALESCE(lc.soh, 0) > 0
     AND bc.list_cost IS NOT NULL
    )                      AS ghost_stock_flag,

    CASE
        WHEN COALESCE(cl.class, 'NORMAL') = 'PRODUCTION'
             AND COALESCE(lc.soh, 0) > 0
             AND bc.list_cost IS NOT NULL
        THEN COALESCE(lc.soh, 0) * bc.list_cost
        ELSE 0
    END                    AS ghost_stock_value,

    -- Virtual/investigate flag: NON_STOCK with positive SOH.
    -- Carrier bags (FRONTEND PACK) = real physical stock, likely miscount.
    -- Airtime/vouchers (ONLINE VAS PRODUCTS) = virtual, SOH should be zero.
    -- Returnable bottles/crates (TOPS) = real physical items, may inflate capital.
    -- Surfaces these for eyeballing without excluding from capital_value.
    (    COALESCE(cl.class, 'NORMAL') = 'NON_STOCK'
     AND COALESCE(lc.soh, 0) > 0
    )                      AS investigate_stock_flag,

    -- Stale ledger: NORMAL + soh > 0 + no receipt in 2+ years + no recent sales.
    -- Catches deposit/returnable items whose SOH accumulated and never depleted
    -- (e.g. deposit empties, crates booked in but returns never offset the ledger).
    -- These items inflate capital_value with ledger artefacts, not real stock.
    (    COALESCE(cl.class, 'NORMAL') = 'NORMAL'
     AND COALESCE(lc.soh, 0) > 0
     AND (   lc.last_receipt_date IS NULL
          OR lc.last_receipt_date < CURRENT_DATE - 730
         )
     AND COALESCE(ros.sales_qty_91d, 0) = 0
    )                      AS stale_ledger_flag,

    -- Cost sanity: unit_cost exceeds VAT-inclusive sell price.
    -- When pack_size is left as 1 in sigma_supplier_link but list_cost is per case,
    -- unit_cost is inflated by the case size factor (e.g. cost R1,010 for a R10 cup).
    -- These rows should be excluded from any capital KPI until the pack_size is fixed.
    (    bc.list_cost IS NOT NULL
     AND a.sell_price_incl_vat > 0
     AND bc.list_cost > a.sell_price_incl_vat
    )                      AS cost_sanity_flag,

    CURRENT_TIMESTAMP      AS positioned_at

FROM sigma_articles a
LEFT JOIN sigma_departments d
    ON  d.client_id      = a.client_id
    AND d.store_code     = a.store_code
    AND d.department_nr  = a.department_nr
LEFT JOIN sigma_subdepts sd
    ON  sd.client_id      = a.client_id
    AND sd.store_code     = a.store_code
    AND sd.merch_group_nr = a.merch_group_nr
LEFT JOIN sigma_lifecycle lc
    ON  lc.client_id    = a.client_id
    AND lc.store_code   = a.store_code
    AND lc.product_code = a.product_code
LEFT JOIN best_cost bc
    ON  bc.client_id    = a.client_id
    AND bc.store_code   = a.store_code
    AND bc.product_code = a.product_code
LEFT JOIN l2_rate_of_sale ros
    ON  ros.client_id    = a.client_id
    AND ros.store_code   = a.store_code
    AND ros.product_code = a.product_code
LEFT JOIN l2_ranging_tier rt
    ON  rt.client_id    = a.client_id
    AND rt.store_code   = a.store_code
    AND rt.product_code = a.product_code
LEFT JOIN l2_item_classification cl
    ON  cl.client_id    = a.client_id
    AND cl.store_code   = a.store_code
    AND cl.product_code = a.product_code
LEFT JOIN yesterday_soh ys
    ON  ys.client_id    = a.client_id
    AND ys.store_code   = a.store_code
    AND ys.product_code = a.product_code;


-- Indexes for the primary access patterns:

--   1. KPI join: (client_id, store_code, product_code) -> all columns
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_pos_pk
    ON l2_stock_position (client_id, store_code, product_code);

--   2. Class sweep: all articles of a given class in a store
CREATE INDEX IF NOT EXISTS idx_l2_pos_class
    ON l2_stock_position (store_code, class);

--   3. Tier sweep: all articles of a given tier in a store
CREATE INDEX IF NOT EXISTS idx_l2_pos_tier
    ON l2_stock_position (store_code, tier);

--   4. Reorder report fast path
CREATE INDEX IF NOT EXISTS idx_l2_pos_reorder
    ON l2_stock_position (store_code)
    WHERE reorder_signal = TRUE;

--   5. Slow mover report fast path
CREATE INDEX IF NOT EXISTS idx_l2_pos_slow
    ON l2_stock_position (store_code)
    WHERE slow_mover_signal = TRUE;

--   6. Ghost stock report fast path
CREATE INDEX IF NOT EXISTS idx_l2_pos_ghost
    ON l2_stock_position (store_code)
    WHERE ghost_stock_flag = TRUE;

--   7. Capital tied sort (descending capital value within store+tier)
CREATE INDEX IF NOT EXISTS idx_l2_pos_capital
    ON l2_stock_position (store_code, tier, capital_value DESC);

--   8. Negative SOH report
CREATE INDEX IF NOT EXISTS idx_l2_pos_neg_soh
    ON l2_stock_position (store_code)
    WHERE neg_soh_signal = TRUE;

--   9. Stale ledger report
CREATE INDEX IF NOT EXISTS idx_l2_pos_stale
    ON l2_stock_position (store_code)
    WHERE stale_ledger_flag = TRUE;

--  10. Cost sanity report
CREATE INDEX IF NOT EXISTS idx_l2_pos_cost_sanity
    ON l2_stock_position (store_code)
    WHERE cost_sanity_flag = TRUE;


COMMENT ON MATERIALIZED VIEW l2_stock_position IS
    'Current stock position per article per store. Step 3b in L2 build order. '
    'Joins sigma_articles + sigma_lifecycle + sigma_supplier_link + '
    'l2_rate_of_sale + l2_ranging_tier + l2_item_classification + l2_soh_daily. '
    'tier comes directly from l2_ranging_tier (which assigns CLASS_EXCLUDED per D1). '
    'soh_delta is NULL until l2_soh_daily holds prior-day data (from second night). '
    'Source for l2_kpi_daily (step 4) aggregations. SB-CC-L2-001 step 3b + D1 amendment.';

GRANT SELECT ON l2_stock_position TO anon, authenticated;


-- =============================================================================
-- VERIFY after first REFRESH:
-- =============================================================================
-- -- Row count and signal summary per store
-- SELECT
--     store_code,
--     COUNT(*)                                         AS total_articles,
--     COUNT(*) FILTER (WHERE class = 'NORMAL')         AS normal,
--     COUNT(*) FILTER (WHERE class = 'PRODUCTION')     AS production,
--     COUNT(*) FILTER (WHERE class = 'NON_STOCK')      AS non_stock,
--     COUNT(*) FILTER (WHERE reorder_signal)           AS reorder,
--     COUNT(*) FILTER (WHERE slow_mover_signal)        AS slow_movers,
--     COUNT(*) FILTER (WHERE neg_soh_signal)           AS neg_soh,
--     COUNT(*) FILTER (WHERE ghost_stock_flag)         AS ghost_stock,
--     ROUND(SUM(capital_value)::numeric, 0)            AS capital_tied,
--     ROUND(SUM(ghost_stock_value)::numeric, 0)        AS ghost_capital,
--     COUNT(*) FILTER (WHERE unit_cost IS NULL
--                        AND class = 'NORMAL')         AS normal_no_cost
-- FROM l2_stock_position
-- GROUP BY store_code
-- ORDER BY store_code;
--
-- -- Sanity: NORMAL articles with no cost (need investigation if count is high)
-- SELECT store_code, COUNT(*) AS cnt
-- FROM l2_stock_position
-- WHERE class = 'NORMAL' AND unit_cost IS NULL AND sales_qty_91d > 0
-- GROUP BY store_code ORDER BY store_code;
--
-- -- SOH delta check (run day 2+, should be non-NULL)
-- SELECT store_code,
--        COUNT(*) FILTER (WHERE soh_delta IS NOT NULL) AS has_delta,
--        COUNT(*) FILTER (WHERE soh_delta IS NULL)     AS no_delta
-- FROM l2_stock_position
-- GROUP BY store_code ORDER BY store_code;
-- =============================================================================
