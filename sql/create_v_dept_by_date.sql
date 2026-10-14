-- =============================================================================
-- create_v_dept_by_date.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 2.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 (2026-06-17, daily_snapshots source).
-- ENG-167 (dashboard lane, 14-10-2026): LIVE BODY REPLACED, migration
--   eng167_v_dept_by_date_left_join_coverage. This file equals the live definition.
-- =============================================================================
-- WHY (original):
--   daily_snapshots frozen at 2026-06-28 (Push-SigmaToSupabase.ps1 retired).
--   View returned no rows for dates >= 2026-06-29.
--
-- WHAT:
--   Driver: sigma_sales (period_kind='T', txn_kind=1).
--   dept_name: sigma_articles -> sigma_departments (same join as rpc_dept_summary).
--   dept_sales: SUM(sales_incl_vat).  dept_cost: SUM(cost_value).
--   dept_qty:   SUM(qty) from sigma_sales (replaces PRSSALE today_qty).
--   daily_snapshots dependency dropped entirely.
--
-- BEHAVIOR NOTE (REPLACED 14-10-2026, ENG-167; R28 lineage kept here):
--   Until 14-10-2026 rows with no dept mapping were EXCLUDED ("AND sd.name IS NOT NULL"), which turned the
--   LEFT JOINs into inner joins and made the view read R60.00 over the till at 10116 on 2026-09-01 (a refund
--   line of -R60.00, product 88889999, no sigma_articles row) and under it on any day a positive orphan line
--   existed. Unmapped lines are now named UNMAPPED, the rule rpc_dept_summary has applied since
--   dash_source_002_step3 (R22/R23: a total must reconcile to the till, never silently drop a line).
--   R22 after apply, view total against the till: 10116 2026-09-01 R247,780.52 = R247,780.52 (was R247,840.52),
--   2026-10-13 R152,477.39 = R152,477.39; 21355, 80175 and 80579 on both days diff 0.00.
--   Performance gate (EXPLAIN ANALYZE, 91 dates, 14-10-2026 during a pipeline rerun): 5 stores and 2
--   departments 8.3 s before, 3.8 s after; 1 store and 1 department 2.7 s before, 3.7 s after.
--
-- COLUMN ORDER: preserved exactly. CREATE OR REPLACE keeps the existing ACL (anon and authenticated SELECT);
--   no GRANT is restated here (ENG-120 owns table and view permissions).
-- Rollback: CREATE OR REPLACE with the previous body (WHERE ... AND sd.name IS NOT NULL, GROUP BY sd.name).
-- =============================================================================

CREATE OR REPLACE VIEW public.v_dept_by_date AS
 SELECT ss.store_code,
    ss.sale_date AS snapshot_date,
    COALESCE(sd.name, 'UNMAPPED'::text) AS dept_name,
    round(sum(ss.sales_incl_vat), 2) AS dept_sales,
    round(sum(ss.cost_value), 2) AS dept_cost,
    round(sum(ss.qty), 2) AS dept_qty
   FROM sigma_sales ss
     LEFT JOIN sigma_articles a ON a.store_code = ss.store_code AND a.product_code = ss.product_code
     LEFT JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
  WHERE ss.period_kind = 'T'::text AND ss.txn_kind = 1
  GROUP BY ss.store_code, ss.sale_date, COALESCE(sd.name, 'UNMAPPED'::text);
