-- =============================================================================
-- SB-AP-001  Aggregation Verification — run in Supabase SQL Editor
-- Purpose: Cross-check dashboard figures against raw daily_snapshots.
--          If these queries match what the dashboard shows, the RPCs are correct.
-- =============================================================================


-- ── 1. SPAR CARRIER BAG VT1 — qty by individual date (all stores) ─────────────
--    Dashboard showed: 10th = 651 · +9th = 1 657 · +8th = 2 577
WITH daily AS (
    SELECT
        snapshot_date,
        SUM(today_qty)::integer AS qty_sold
    FROM   daily_snapshots
    WHERE  description ILIKE '%CARRIER BAG VT1%'
      AND  today_qty   > 0
    GROUP BY snapshot_date
)
SELECT
    snapshot_date,
    qty_sold,
    SUM(qty_sold) OVER (ORDER BY snapshot_date DESC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)::integer
                        AS cumulative_qty_newest_first
FROM   daily
ORDER BY snapshot_date DESC;


-- ── 2. SPAR CARRIER BAG VT1 — total across ALL stores, ALL dates ──────────────
--    Dashboard showed: 8 772 units when all stores + 1–10 May selected
SELECT
    SUM(today_qty)::integer   AS total_qty_all_stores_all_dates,
    COUNT(DISTINCT store_code) AS store_count,
    COUNT(DISTINCT snapshot_date) AS date_count
FROM   daily_snapshots
WHERE  description ILIKE '%CARRIER BAG VT1%'
  AND  today_qty   > 0;


-- ── 3. TOTAL SALES across all stores, all available dates ────────────────────
--    Dashboard showed: R 3.22 M sales, R 2.37 M cost
SELECT
    ROUND(SUM(today_sales)::numeric, 2)  AS total_sales,
    ROUND(SUM(today_cost)::numeric,  2)  AS total_cost,
    ROUND(
        ((SUM(today_sales) - SUM(today_cost)) / NULLIF(SUM(today_sales), 0) * 100)::numeric,
        1
    )                                    AS gross_profit_pct,
    COUNT(DISTINCT store_code)           AS stores,
    COUNT(DISTINCT snapshot_date)        AS dates,
    MIN(snapshot_date)                   AS earliest_date,
    MAX(snapshot_date)                   AS latest_date
FROM   daily_snapshots
WHERE  today_sales > 0;


-- ── 4. HMR (both spellings) department total — all stores, all dates ─────────
--    Dashboard showed: R 206.3 k
SELECT
    dept_name,
    ROUND(SUM(today_sales)::numeric, 2) AS dept_sales,
    ROUND(SUM(today_cost)::numeric,  2) AS dept_cost,
    SUM(today_qty)::integer             AS dept_qty
FROM   daily_snapshots
WHERE  REPLACE(dept_name, '.', '') = 'HMR'
  AND  today_sales > 0
GROUP BY dept_name
ORDER BY dept_name;


-- ── 5. TOP 10 DEPARTMENTS by sales — raw table, all stores, all dates ─────────
--    Should match the Sales by Department bar list on the dashboard
SELECT
    TRIM(REPLACE(dept_name, '.', ''))   AS dept_normalised,
    ROUND(SUM(today_sales)::numeric, 2) AS total_sales,
    ROUND(SUM(today_cost)::numeric,  2) AS total_cost,
    SUM(today_qty)::integer             AS total_qty
FROM   daily_snapshots
WHERE  today_sales > 0
GROUP BY dept_normalised
ORDER BY total_sales DESC
LIMIT 10;
