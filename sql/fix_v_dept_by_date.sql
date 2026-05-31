-- =============================================================================
-- fix_v_dept_by_date.sql
-- Recreate v_dept_by_date reading from daily_snapshots.
--
-- Root cause: the view was originally defined against daily_aggregates
-- (phase2c_migrate_pulse.sql). daily_aggregates was dropped in SB-SCH-001
-- (2026-05-23). The view was never recreated, so every query returned:
--   PGRST205: Could not find the table 'public.v_dept_by_date' in the schema cache
-- Effect: dept-level Sales Trend always empty -> "Select a date range to see
--   the trend" even when a dept filter was active.
--
-- New definition aggregates today_sales/cost/qty per (store, date, dept)
-- directly from daily_snapshots. Columns unchanged: store_code, snapshot_date,
-- dept_name, dept_sales, dept_cost, dept_qty.
--
-- Consumers:
--   1. page.jsx dept trend effect  — .in('snapshot_date', trendDates[91])
--   2. DeptTable.jsx (unused / legacy) — .eq('snapshot_date', date)
--
-- Run in Supabase SQL Editor. No destructive side-effects beyond view replace.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_dept_by_date AS
SELECT
    store_code,
    snapshot_date,
    dept_name,
    ROUND(SUM(today_sales)::numeric, 2)  AS dept_sales,
    ROUND(SUM(today_cost)::numeric,  2)  AS dept_cost,
    SUM(today_qty)::numeric              AS dept_qty
FROM   daily_snapshots
WHERE  dept_name      IS NOT NULL
  AND  is_placeholder  = FALSE
GROUP  BY store_code, snapshot_date, dept_name;

GRANT SELECT ON public.v_dept_by_date TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');

-- Verify: should return dept rows for SPAR Delareyville on the most recent push date.
-- SELECT * FROM v_dept_by_date WHERE store_code = '10116' ORDER BY snapshot_date DESC LIMIT 20;
