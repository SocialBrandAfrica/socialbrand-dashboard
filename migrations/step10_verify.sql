-- =============================================================================
-- SB-AP-002 Step 10 — Final verification
-- =============================================================================

-- 1. All tables in public schema
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- 2. stores must have 5 rows
SELECT COUNT(*) AS store_count FROM stores;

-- 3. Existing views still return data from daily_snapshots
SELECT 'v_kpi_by_date'          AS view_name, COUNT(*) AS row_count FROM v_kpi_by_date
UNION ALL
SELECT 'v_dept_by_date'         AS view_name, COUNT(*) AS row_count FROM v_dept_by_date
UNION ALL
SELECT 'v_top_products_by_date' AS view_name, COUNT(*) AS row_count FROM v_top_products_by_date
UNION ALL
SELECT 'v_focus_trend'          AS view_name, COUNT(*) AS row_count FROM v_focus_trend;
