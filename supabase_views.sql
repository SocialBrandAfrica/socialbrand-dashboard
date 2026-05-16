-- =============================================================================
-- SB-AP-001 Phase 3 — Dashboard Aggregation Views
-- Run this in Supabase SQL Editor to fix the dashboard totals.
-- These views aggregate on the server so the dashboard never pulls raw rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. v_kpi_by_date
-- One row per store per date. Used by KPI strip and YoY graph.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_by_date AS
SELECT
    store_code,
    store_name,
    snapshot_date,
    SUM(today_sales)                                              AS total_sales,
    SUM(today_cost)                                               AS total_cost,
    SUM(today_qty)                                                AS total_qty,
    COUNT(*) FILTER (WHERE soh < 0)                               AS neg_soh_count,
    COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0
                     AND is_placeholder = FALSE)                  AS slow_mover_count
FROM daily_snapshots
GROUP BY store_code, store_name, snapshot_date;

COMMENT ON VIEW v_kpi_by_date IS
    'Daily KPIs aggregated per store per date. Used by the Phase 3 dashboard.';


-- -----------------------------------------------------------------------------
-- 2. v_dept_by_date
-- One row per department per store per date.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dept_by_date AS
SELECT
    store_code,
    snapshot_date,
    dept_name,
    SUM(today_sales)  AS dept_sales,
    SUM(today_cost)   AS dept_cost,
    SUM(today_qty)    AS dept_qty
FROM daily_snapshots
WHERE today_sales > 0
GROUP BY store_code, snapshot_date, dept_name;

COMMENT ON VIEW v_dept_by_date IS
    'Department sales aggregated per store per date. Used by the dept table panel.';


-- -----------------------------------------------------------------------------
-- 3. v_top_products_by_date
-- One row per EAN per store per date — already one row in daily_snapshots,
-- but this view adds a rank so the dashboard can filter TOP 20 server-side.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_products_by_date AS
SELECT
    store_code,
    snapshot_date,
    ean,
    description,
    dept_name,
    today_sales,
    today_qty,
    RANK() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_sales DESC) AS rank_by_sales,
    RANK() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_qty   DESC) AS rank_by_qty
FROM daily_snapshots
WHERE today_sales > 0;

COMMENT ON VIEW v_top_products_by_date IS
    'Per-store daily product rankings. Filter rank_by_sales <= 20 for Top 20.';


-- -----------------------------------------------------------------------------
-- 4. v_focus_trend
-- Daily trend per dept/description for the Focus Drilldown.
-- Aggregated per date so the browser gets ~30 rows not ~1M.
-- Note: supplier is joined from the suppliers table via products — not stored
-- in daily_snapshots directly. Supplier search handled separately via v_diwaais.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_focus_trend AS
SELECT
    store_code,
    snapshot_date,
    ean,
    dept_name,
    sub_dept_name,
    description,
    SUM(today_sales) AS sales,
    SUM(today_qty)   AS qty
FROM daily_snapshots
GROUP BY store_code, snapshot_date, ean, dept_name, sub_dept_name, description;

COMMENT ON VIEW v_focus_trend IS
    'Aggregated trend data for the Focus Drilldown panel. Supplier search uses v_diwaais.';
