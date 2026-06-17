-- SB-AP-001 Fix: Add sub_dept_name to v_top_products_by_date
-- Run this once in Supabase SQL Editor.
-- Drop first because CREATE OR REPLACE cannot change column order.

DROP VIEW IF EXISTS v_top_products_by_date;

CREATE VIEW v_top_products_by_date AS
SELECT
    store_code,
    snapshot_date,
    ean,
    description,
    dept_name,
    sub_dept_name,
    today_sales,
    today_qty,
    RANK() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_sales DESC) AS rank_by_sales,
    RANK() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_qty   DESC) AS rank_by_qty
FROM daily_snapshots
WHERE today_sales > 0;

COMMENT ON VIEW v_top_products_by_date IS
    'Per-store daily product rankings including sub_dept_name. Phase 3.1 fix.';
