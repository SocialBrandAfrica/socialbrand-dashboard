-- =============================================================================
-- SB-AP-001  Targeted Audit — May 1–10, All 5 Stores
-- Same scope as the dashboard selection when numbers were recorded.
-- Dashboard reported: Sales R 3.22M · Cost R 2.37M · HMR R 206.3k · Bag 8 772 units
-- =============================================================================

-- Confirm exactly which dates and stores are in scope
SELECT snapshot_date, store_code, COUNT(*) AS rows
FROM   daily_snapshots
WHERE  snapshot_date BETWEEN '2026-05-01' AND '2026-05-10'
GROUP BY snapshot_date, store_code
ORDER BY snapshot_date, store_code;


-- ── A. GRAND TOTAL — must match dashboard KPI band ───────────────────────────
--    Expected: ~R 3 220 000 sales · ~R 2 370 000 cost
SELECT
    ROUND(SUM(today_sales)::numeric, 0)  AS total_sales,
    ROUND(SUM(today_cost)::numeric,  0)  AS total_cost,
    ROUND(
        ((SUM(today_sales) - SUM(today_cost)) / NULLIF(SUM(today_sales),0) * 100)::numeric,
        1
    )                                    AS gp_pct,
    SUM(today_qty)::integer              AS total_units,
    COUNT(DISTINCT store_code)           AS stores,
    COUNT(DISTINCT snapshot_date)        AS dates
FROM   daily_snapshots
WHERE  snapshot_date BETWEEN '2026-05-01' AND '2026-05-10'
  AND  today_sales > 0;


-- ── B. HMR DEPARTMENT — must match dashboard dept bar ────────────────────────
--    Expected: ~R 206 300 sales
SELECT
    TRIM(REPLACE(dept_name, '.', ''))    AS dept_normalised,
    ROUND(SUM(today_sales)::numeric, 0)  AS dept_sales,
    ROUND(SUM(today_cost)::numeric,  0)  AS dept_cost,
    SUM(today_qty)::integer              AS dept_units
FROM   daily_snapshots
WHERE  snapshot_date BETWEEN '2026-05-01' AND '2026-05-10'
  AND  REPLACE(dept_name, '.', '') = 'HMR'
GROUP BY dept_normalised;


-- ── C. SPAR CARRIER BAG VT1 — units by date, cumulative ──────────────────────
--    Expected: 10th = 651 · +9th = 1 657 · +8th = 2 577 · all 10 days = 8 772
WITH daily AS (
    SELECT
        snapshot_date,
        SUM(today_qty)::integer AS qty_sold
    FROM   daily_snapshots
    WHERE  snapshot_date BETWEEN '2026-05-01' AND '2026-05-10'
      AND  description ILIKE '%CARRIER BAG VT1%'
      AND  today_qty > 0
    GROUP BY snapshot_date
)
SELECT
    snapshot_date,
    qty_sold,
    SUM(qty_sold) OVER (ORDER BY snapshot_date DESC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)::integer
                        AS running_total_newest_first
FROM   daily
ORDER BY snapshot_date DESC;


-- ── D. TOP 10 DEPARTMENTS — must match Sales by Department bar list ───────────
SELECT
    TRIM(REPLACE(dept_name, '.', ''))    AS dept_normalised,
    ROUND(SUM(today_sales)::numeric, 0)  AS total_sales
FROM   daily_snapshots
WHERE  snapshot_date BETWEEN '2026-05-01' AND '2026-05-10'
  AND  today_sales > 0
GROUP BY dept_normalised
ORDER BY total_sales DESC
LIMIT 10;
