-- =============================================================================
-- report_stock_data_quality.sql
-- SocialBrand Intelligence Platform -- Standing Data Quality Report
-- =============================================================================
-- Reference   : L2-001, L2-DEFINITIONS-REVIEW.md
-- Purpose     : Surface items requiring Sigma correction. Run after each
--               nightly push to measure cleanup progress.
--               Pieter uses this output to action changes directly in Sigma:
--               - Pack size errors   -> correct pack_size in sigma_supplier_link
--               - Stale SOH          -> zero SOH (wave 1), set non-accruing (wave 2)
--               - Investigate stock  -> assess each line, fix or reclassify
--
-- HOW TO USE: Paste each QUERY section individually into the Supabase SQL editor.
-- =============================================================================


-- =============================================================================
-- QUERY 1: Summary by store -- flags and capital impact
-- =============================================================================
SELECT
    store_code,
    -- Cost sanity (pack_size=1 when list_cost is per case)
    COUNT(*) FILTER (WHERE cost_sanity_flag)
        AS cost_sanity_count,
    ROUND(SUM(capital_value) FILTER (WHERE cost_sanity_flag)::numeric, 0)
        AS cost_sanity_capital,

    -- Stale ledger (SOH > 0 but no receipt in 2yr and no recent sales)
    COUNT(*) FILTER (WHERE stale_ledger_flag)
        AS stale_ledger_count,
    ROUND(SUM(capital_value) FILTER (WHERE stale_ledger_flag)::numeric, 0)
        AS stale_ledger_capital,

    -- Investigate stock (NON_STOCK class with positive SOH)
    COUNT(*) FILTER (WHERE investigate_stock_flag)
        AS investigate_stock_count,
    ROUND(SUM(capital_value) FILTER (WHERE investigate_stock_flag)::numeric, 0)
        AS investigate_stock_capital,

    -- Total capital for context
    ROUND(SUM(capital_value)::numeric, 0)
        AS total_capital_all_classes,
    ROUND(SUM(capital_value) FILTER (WHERE class = 'NORMAL')::numeric, 0)
        AS normal_class_capital

FROM l2_stock_position
GROUP BY store_code
ORDER BY store_code;


-- =============================================================================
-- QUERY 2: Cost sanity errors -- unit_cost > sell price (pack_size needs fixing)
-- Action in Sigma: correct pack_size in sigma_supplier_link for each product.
-- =============================================================================
SELECT
    store_code,
    product_code,
    description,
    soh,
    sell_price_incl_vat                              AS sell_price,
    unit_cost,
    pack_size,
    ROUND(capital_value::numeric, 2)                 AS capital_value,
    ROUND((unit_cost / NULLIF(sell_price_incl_vat, 0))::numeric, 1)
                                                     AS cost_to_sell_ratio,
    last_receipt_date,
    tier,
    class
FROM l2_stock_position
WHERE cost_sanity_flag = TRUE
ORDER BY store_code, capital_value DESC;


-- =============================================================================
-- QUERY 3: Stale ledger items -- SOH > 0 but no receipt in 2 years and no sales
-- Action in Sigma: zero the SOH (wave 1), then set line non-accruing (wave 2).
-- =============================================================================
SELECT
    store_code,
    product_code,
    description,
    soh,
    unit_cost,
    ROUND(capital_value::numeric, 2)                 AS capital_value,
    last_receipt_date,
    last_sale_date,
    last_inv_date,
    last_inv_soh,
    tier,
    class
FROM l2_stock_position
WHERE stale_ledger_flag = TRUE
ORDER BY store_code, capital_value DESC;


-- =============================================================================
-- QUERY 4: Investigate stock (NON_STOCK class with positive SOH)
-- Sub-types to assess per line:
--   Carrier bags / packaging      -> physical stock, likely miscount on SOH
--   Airtime / voucher lines       -> virtual, SOH must be zero
--   Returnable deposit containers -> physical items, confirm classification
-- Action in Sigma: assess each line; zero SOH or reclassify as appropriate.
-- =============================================================================
SELECT
    store_code,
    product_code,
    description,
    soh,
    unit_cost,
    ROUND(capital_value::numeric, 2)                 AS capital_value,
    last_receipt_date,
    last_sale_date,
    article_type,
    tier
FROM l2_stock_position
WHERE investigate_stock_flag = TRUE
ORDER BY store_code, capital_value DESC;


-- =============================================================================
-- QUERY 5: Ghost stock detail (PRODUCTION class with positive SOH and cost)
-- These are raw material inputs that cannot physically be at POS as sellable units.
-- Note: ghost_stock_value is unreliable (SOH may be in grams/ml, cost per kg/bag).
-- Use this for count verification only, not as a financial figure.
-- Action in Sigma: confirm each line is correctly classified as PRODUCTION.
-- =============================================================================
SELECT
    store_code,
    product_code,
    description,
    soh,
    unit_cost,
    pack_size,
    ROUND(ghost_stock_value::numeric, 2)             AS ghost_stock_value,
    last_receipt_date,
    last_sale_date,
    article_type
FROM l2_stock_position
WHERE ghost_stock_flag = TRUE
ORDER BY store_code, ghost_stock_value DESC;
