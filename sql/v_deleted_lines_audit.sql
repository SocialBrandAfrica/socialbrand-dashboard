-- v_deleted_lines_audit
-- ---------------------
-- Categorises every Delete-status line in daily_snapshots into five buckets
-- based on the most recent snapshot for each (store_code, ean) pair.
--
-- Buckets (mutually exclusive, evaluated in priority order):
--   ACTIVE_STOCK   - SOH > 0 and selling this period. Likely an accidental
--                    deletion. Investigate before cleaning from Sigma.
--   DEAD_STOCK     - SOH > 0 but no period sales. Stock stranded on shelf.
--                    Capital tied up in a deleted line.
--   RECENT_SALES   - Sold this period but no stock left. May be a
--                    discontinued line that cleared out cleanly.
--   SOLD_LAST_YEAR - No stock, no period sales, but last sale within 12
--                    months. Seasonal candidate - check before removing.
--   SAFE_TO_REMOVE - No stock, no period sales, no sale in 12+ months (or
--                    never sold). Hand this list to the store manager to
--                    clean dead PLUs out of Sigma.
--
-- Run in Supabase SQL Editor to create the view:
--   \i v_deleted_lines_audit.sql
--   or paste the CREATE OR REPLACE VIEW block directly.

CREATE OR REPLACE VIEW v_deleted_lines_audit AS
WITH latest AS (
    SELECT DISTINCT ON (store_code, ean)
        store_code,
        store_name,
        snapshot_date,
        ean,
        description,
        size,
        unit,
        sell_price,
        dept_code,
        dept_name,
        sub_dept_code,
        sub_dept_name,
        internal_ref,
        status,
        soh,
        period_qty,
        period_sales,
        today_qty,
        today_sales,
        last_sales_date_iso,
        is_placeholder
    FROM daily_snapshots
    WHERE status = 'Delete'
    ORDER BY store_code, ean, snapshot_date DESC
)
SELECT
    store_code,
    store_name,
    snapshot_date                           AS last_seen_date,
    ean,
    description,
    size,
    unit,
    ROUND(sell_price::numeric, 2)           AS sell_price,
    dept_name,
    sub_dept_name,
    internal_ref,
    ROUND(soh::numeric, 3)                  AS soh,
    ROUND(period_qty::numeric, 3)           AS period_qty,
    ROUND(period_sales::numeric, 2)         AS period_sales,
    ROUND(today_sales::numeric, 2)          AS today_sales,
    last_sales_date_iso,
    CASE
        WHEN soh > 0 AND COALESCE(period_sales, 0) > 0
            THEN 'ACTIVE_STOCK'
        WHEN soh > 0 AND COALESCE(period_sales, 0) = 0
            THEN 'DEAD_STOCK'
        WHEN COALESCE(soh, 0) <= 0 AND COALESCE(period_sales, 0) > 0
            THEN 'RECENT_SALES'
        WHEN COALESCE(soh, 0) <= 0
          AND COALESCE(period_sales, 0) = 0
          AND last_sales_date_iso >= CURRENT_DATE - INTERVAL '365 days'
            THEN 'SOLD_LAST_YEAR'
        ELSE
            'SAFE_TO_REMOVE'
    END                                     AS audit_bucket
FROM latest
ORDER BY
    store_code,
    CASE
        WHEN soh > 0 AND COALESCE(period_sales, 0) > 0  THEN 1
        WHEN soh > 0 AND COALESCE(period_sales, 0) = 0  THEN 2
        WHEN COALESCE(soh, 0) <= 0 AND COALESCE(period_sales, 0) > 0 THEN 3
        WHEN COALESCE(soh, 0) <= 0 AND COALESCE(period_sales, 0) = 0
          AND last_sales_date_iso >= CURRENT_DATE - INTERVAL '365 days' THEN 4
        ELSE 5
    END,
    dept_name,
    description;


-- Quick summary query — run after creating the view to see bucket counts per store:
--
-- SELECT
--     store_name,
--     audit_bucket,
--     COUNT(*)                        AS lines,
--     ROUND(SUM(soh * sell_price)::numeric, 2) AS stock_value_incl_vat
-- FROM v_deleted_lines_audit
-- GROUP BY store_name, audit_bucket
-- ORDER BY store_name, audit_bucket;
