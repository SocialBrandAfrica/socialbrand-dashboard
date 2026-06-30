-- =============================================================================
-- create_v_dept_by_date.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 2.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 (2026-06-17, daily_snapshots source).
-- =============================================================================
-- WHY:
--   daily_snapshots frozen at 2026-06-28 (Push-SigmaToSupabase.ps1 retired).
--   View returned no rows for dates >= 2026-06-29.
--
-- WHAT CHANGES:
--   Driver: sigma_sales (period_kind='T', txn_kind=1).
--   dept_name: sigma_articles -> sigma_departments (same join as rpc_dept_summary).
--   dept_sales: SUM(sales_incl_vat).  dept_cost: SUM(cost_value).
--   dept_qty:   SUM(qty) from sigma_sales (replaces PRSSALE today_qty).
--   is_placeholder filter dropped -- sigma_sales rows are real transactions by
--     definition; no placeholder concept in sigma.
--   daily_snapshots dependency dropped entirely.
--
-- BEHAVIOR NOTE: rows with no dept mapping (sd.name IS NULL) are excluded to
--   match prior behavior (WHERE dept_name IS NOT NULL). Unmapped sales appear in
--   rpc_dept_summary as 'UNMAPPED' -- that is an RPC-level choice; this view
--   preserves the original exclusion for zero client breakage.
--
-- COLUMN ORDER: preserved exactly.
-- GRANT: anon + authenticated SELECT.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP VIEW IF EXISTS public.v_dept_by_date;

CREATE VIEW public.v_dept_by_date AS
SELECT
  ss.store_code,
  ss.sale_date                                     AS snapshot_date,
  sd.name                                          AS dept_name,
  round(sum(ss.sales_incl_vat), 2)                 AS dept_sales,
  round(sum(ss.cost_value), 2)                     AS dept_cost,
  round(sum(ss.qty), 2)                            AS dept_qty
FROM public.sigma_sales ss
LEFT JOIN public.sigma_articles a
  ON  a.store_code   = ss.store_code
  AND a.product_code = ss.product_code
LEFT JOIN public.sigma_departments sd
  ON  sd.store_code    = a.store_code
  AND sd.department_nr = a.department_nr
WHERE ss.period_kind = 'T'
  AND ss.txn_kind    = 1
  AND sd.name        IS NOT NULL
GROUP BY ss.store_code, ss.sale_date, sd.name;

GRANT SELECT ON public.v_dept_by_date TO anon, authenticated;
