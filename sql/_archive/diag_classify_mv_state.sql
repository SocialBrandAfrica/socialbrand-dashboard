-- =============================================================================
-- DIAGNOSTIC -- confirm deployed state before completing patch1 + closing O1.
-- Read-only. Run each query, paste the grid back. No changes made.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q1 -- classify_snapshot_item overloads. Expect 2 rows (the collision):
--        classify_snapshot_item(text,text,numeric)         <- orphan 3-arg
--        classify_snapshot_item(text,text,numeric,date)    <- patch1 4-arg
-- ---------------------------------------------------------------------------
SELECT p.oid::regprocedure AS signature
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'classify_snapshot_item'
ORDER  BY 1;

-- ---------------------------------------------------------------------------
-- Q2 -- mv_kpi_by_date definition. Confirms whether the MV still uses the OLD
--        capital_tied (no never-sold exclusion) -- the cause of R9.83M on the
--        multi-date headline.
-- ---------------------------------------------------------------------------
SELECT definition
FROM   pg_matviews
WHERE  matviewname = 'mv_kpi_by_date';

-- ---------------------------------------------------------------------------
-- Q3 -- rpc_dept_summary overloads. AFTER running the O1 fix this must be 1 row.
--        Before the fix it is 2 (the PGRST203 collision).
-- ---------------------------------------------------------------------------
SELECT p.oid::regprocedure AS signature
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'rpc_dept_summary'
ORDER  BY 1;
