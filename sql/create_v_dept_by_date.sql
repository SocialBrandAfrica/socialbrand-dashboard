-- =============================================================================
-- create_v_dept_by_date.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for v_dept_by_date.
-- Supersedes fix_v_dept_by_date.sql + the copies in phase2c_* (sediment).
-- Extracted verbatim from LIVE 2026-06-17. Dept-level daily sales off daily_snapshots
-- (legacy PRSSALE source; sigma migration is the stock-facts thread, not this reconcile).
-- =============================================================================
CREATE OR REPLACE VIEW public.v_dept_by_date AS
 SELECT store_code,
    snapshot_date,
    dept_name,
    round(sum(today_sales), 2) AS dept_sales,
    round(sum(today_cost), 2) AS dept_cost,
    sum(today_qty) AS dept_qty
   FROM daily_snapshots
  WHERE dept_name IS NOT NULL AND is_placeholder = false
  GROUP BY store_code, snapshot_date, dept_name;
