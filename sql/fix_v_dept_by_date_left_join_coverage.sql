-- =============================================================================
-- fix_v_dept_by_date_left_join_coverage.sql
-- BUG-LOG ENG-167 -- the department view must total to the till.
-- =============================================================================
-- THE DEFECT, measured at source 2026-09-02.
--   v_dept_by_date    10116 / 2026-09-01 : R247,840.52
--   sigma_sales T/1   10116 / 2026-09-01 : R247,780.52
--   difference                            : +R60.00, the view reports MORE
--                                           than the store took
-- Group-wide over 30 days: 11 of 150 store-days disagree, R490.61 net, worst
-- single day +R215.79, worst under -R55.99. It errs in BOTH directions.
--
-- WHY IT MATTERS. `src/app/page.jsx` reads this view directly (2 sites) for the
-- department trend whenever a dept filter is active. On ~7% of store-days that
-- trend cannot be reconciled to the store's own headline. Small in rand; it is a
-- client-facing number that does not tie to the till, which is an R22 problem
-- rather than a money problem.
--
-- THE CAUSE, and it is subtler than it looks. The joins ARE `LEFT JOIN`. The
-- line that drops the rows is the predicate:
--
--     WHERE ... AND sd.name IS NOT NULL
--
-- A LEFT JOIN followed by `WHERE right_column IS NOT NULL` is an INNER JOIN
-- wearing a left join's clothes. Any sales line whose product has no
-- `sigma_articles` row, or whose article has no `sigma_departments` row, is
-- silently discarded. At 10116 on 2026-09-01 that is exactly ONE line carrying
-- **-R60.00** -- a refund -- so removing it makes the view report MORE than the
-- till. That is why the error can go either way: it depends on the sign of the
-- orphan.
--
-- This is the R20-addendum coverage rule (RULE-BOOK / SQL-CONVENTIONS section 8):
-- an aggregate that must total to the store's true takings LEFT JOINs and
-- COALESCEs; INNER is reserved for a filtered selection. `rpc_dept_summary`
-- already obeys it and reconciles at 0.00 -- this is one view, not a class.
--
-- 🔴 AND A DOC CORRECTION THAT RIDES WITH IT. DB-SCHEMA's Views table records
-- this view as "COALESCE 'UNMAPPED' on dept_name". Read at source, the view
-- contains NO COALESCE at all. The claim is false and has been since the
-- RETIRE-002 entry was written. DB-SCHEMA is CC's file; the row is corrected in
-- the same pass that applies this.
--
-- THE FIX. Two edits, nothing else:
--   1. `sd.name`                 -> `COALESCE(sd.name, 'UNMAPPED')`
--   2. drop `AND sd.name IS NOT NULL`
-- Column list, column order and types are unchanged, so CREATE OR REPLACE VIEW
-- applies without a DROP -- no CASCADE, no dependent invalidated (canon section
-- 13). `dept_name` becomes NOT NULL in practice, which no consumer can break on.
--
-- EXPECTED VISIBLE CHANGE: an `UNMAPPED` department row appears on the days that
-- carry an orphan line. That is the point -- the exclusion becomes visible
-- instead of silent (R21 section 5, R22 section 3). It matches what
-- `rpc_dept_summary` already shows.
--
-- 🔴 NOT APPLIED. Written 2026-09-02 while the database is frozen until the
-- three 03-09 DC orders are placed and exported. Apply in one pass afterwards.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_dept_by_date AS
 SELECT ss.store_code,
    ss.sale_date AS snapshot_date,
    COALESCE(sd.name, 'UNMAPPED') AS dept_name,
    round(sum(ss.sales_incl_vat), 2) AS dept_sales,
    round(sum(ss.cost_value), 2) AS dept_cost,
    round(sum(ss.qty), 2) AS dept_qty
   FROM sigma_sales ss
     LEFT JOIN sigma_articles a ON a.store_code = ss.store_code AND a.product_code = ss.product_code
     LEFT JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
  WHERE ss.period_kind = 'T'::text AND ss.txn_kind = 1
  GROUP BY ss.store_code, ss.sale_date, COALESCE(sd.name, 'UNMAPPED');

COMMENT ON VIEW public.v_dept_by_date IS
'GRADE: CALCULATED. Department sales/cost/qty per (store, sale_date) off sigma_sales T/1. LEFT JOIN + COALESCE ''UNMAPPED'' so a sales line whose product has no article or department row is SURFACED, never dropped (R20 addendum, R21 section 5) -- before ENG-167 a WHERE sd.name IS NOT NULL made the left joins behave as inner ones and the view over-reported the till by up to R215.79 on a store-day. Must total to the sigma_sales T/1 store total exactly.';

-- =============================================================================
-- R22 -- run AFTER. Every store-day must reconcile to the till, delta 0.00.
-- =============================================================================
-- WITH till AS (
--   SELECT store_code, sale_date, sum(sales_incl_vat) t
--   FROM sigma_sales WHERE sale_date > current_date - 30
--     AND period_kind='T' AND txn_kind=1 GROUP BY 1,2),
-- v AS (
--   SELECT store_code, snapshot_date sale_date, sum(dept_sales) v
--   FROM v_dept_by_date WHERE snapshot_date > current_date - 30 GROUP BY 1,2)
-- SELECT count(*) AS store_days,
--        count(*) FILTER (WHERE v.v <> till.t) AS still_wrong,   -- must be 0
--        round(sum(v.v - till.t),2)            AS net_delta      -- must be 0.00
-- FROM till JOIN v USING (store_code, sale_date);
--
-- And the exclusion is now visible rather than silent:
-- SELECT count(*) FROM v_dept_by_date
--  WHERE dept_name='UNMAPPED' AND snapshot_date > current_date - 30;   -- expect > 0
-- =============================================================================
