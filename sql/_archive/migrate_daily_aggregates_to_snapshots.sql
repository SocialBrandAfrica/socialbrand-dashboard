-- =============================================================================
-- migrate_daily_aggregates_to_snapshots.sql
-- =============================================================================
-- The backfill for 2026-05-17 and 2026-05-18 landed in daily_aggregates and
-- stock_snapshots (pushed by Push-SigmaToSupabase.ps1) instead of
-- daily_snapshots (the table the dashboard reads).
--
-- This script joins the two source tables and inserts the missing rows into
-- daily_snapshots, then refreshes the mv_kpi_by_date materialized view so the
-- date picker and KPI strip pick up the new data immediately.
--
-- Run once in the Supabase SQL Editor.
-- ON CONFLICT DO NOTHING means it is safe to re-run — no duplicates created.
-- =============================================================================

WITH

-- Latest SOH reading per EAN + store per day (stock_snapshots may have
-- multiple intraday snapshots — we want the most recent one for each date).
latest_soh AS (
    SELECT DISTINCT ON (store_code, ean, snapshot_at::date)
        store_code,
        ean,
        snapshot_at::date  AS soh_date,
        soh
    FROM  stock_snapshots
    WHERE snapshot_at::date IN ('2026-05-17', '2026-05-18')
    ORDER BY store_code, ean, snapshot_at::date, snapshot_at DESC
)

INSERT INTO daily_snapshots (
    store_code,
    store_name,
    file_date,
    snapshot_date,
    ean,
    description,
    internal_ref,
    dept_code,
    dept_name,
    sub_dept_code,
    sub_dept_name,
    today_qty,
    today_sales,
    today_cost,
    soh,
    is_placeholder,
    -- Fields not available from the new schema — leave as NULL / safe defaults.
    -- The dashboard treats NULL gracefully for these columns.
    size,
    unit,
    sell_price,
    vat_pct,
    period_qty,
    period_cost,
    period_sales,
    status,
    last_sales_date_iso,
    unit_cost
)
SELECT
    da.store_code,

    -- Derive store_name from store_code (matches the STORES constant in page.jsx)
    CASE da.store_code
        WHEN '10116' THEN 'SPAR Delareyville'
        WHEN '21355' THEN 'TOPS Delareyville'
        WHEN '80175' THEN 'SPAR Roosville'
        WHEN '80176' THEN 'TOPS Roosville'
        WHEN '80579' THEN 'TOPS Dice'
        ELSE da.store_code
    END                        AS store_name,

    da.agg_date                AS file_date,
    da.agg_date                AS snapshot_date,
    da.ean,
    da.description,
    da.plu_code                AS internal_ref,
    da.dept_code,
    da.dept_name,
    da.sub_dept_code,
    da.sub_dept_name,

    -- Sales figures — daily_aggregates stores VAT-inclusive sales
    da.qty_sold                AS today_qty,
    da.sales_inc_vat           AS today_sales,
    da.cost_of_sales           AS today_cost,

    -- SOH from the most recent stock snapshot on the same date
    COALESCE(ls.soh, 0)        AS soh,

    FALSE                      AS is_placeholder,

    -- Nullable / unavailable fields
    NULL                       AS size,
    NULL                       AS unit,
    NULL                       AS sell_price,
    NULL                       AS vat_pct,
    NULL                       AS period_qty,
    NULL                       AS period_cost,
    NULL                       AS period_sales,
    'Active'                   AS status,
    NULL                       AS last_sales_date_iso,
    NULL                       AS unit_cost

FROM  daily_aggregates da
LEFT  JOIN latest_soh ls
          ON  ls.store_code = da.store_code
          AND ls.ean        = da.ean
          AND ls.soh_date   = da.agg_date
WHERE da.agg_date IN ('2026-05-17', '2026-05-18')

ON CONFLICT DO NOTHING;


-- =============================================================================
-- Refresh the materialised view so the date picker and KPI strip see May 17-18.
-- =============================================================================
REFRESH MATERIALIZED VIEW mv_kpi_by_date;
