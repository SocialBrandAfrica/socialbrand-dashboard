-- =============================================================================
-- REGRESSION FIX: rpc_dept_summary + rpc_kpi_dept_counts taking 18+ seconds
--
-- Root cause: snapshot_date::text = ANY(p_dates) — casting the column to text
-- destroys the index on daily_snapshots (10.4M+ rows). PostgreSQL cannot use
-- the snapshot_date index when the column is cast on the left-hand side.
--
-- Every version of these functions since add_ean_filter.sql has had this bug.
-- The table was small enough that it wasn't noticeable until now.
--
-- Fix: flip the cast to the right-hand side — snapshot_date = ANY(p_dates::date[])
-- This keeps the column uncast so the index is used.
--
-- Rule from DB-SCHEMA.md (INDEX RULE):
--   ALWAYS: snapshot_date = ANY(p_dates::date[])
--   NEVER:  snapshot_date::text = ANY(p_dates)
--
-- Uses DROP CASCADE + CREATE FUNCTION (NOT CREATE OR REPLACE) to remove all
-- overloads from the previous rewrite chain and leave exactly one clean version.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Drop ALL overloads of both functions
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_dept_summary CASCADE;
DROP FUNCTION IF EXISTS public.rpc_kpi_dept_counts CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2a -- Recreate rpc_dept_summary
--
-- Signature unchanged from the last deployed version:
--   p_store_codes text[]
--   p_dates       text[]
--   p_eans        text[]  DEFAULT NULL
--   p_subdept     text    DEFAULT NULL
--
-- Only change: snapshot_date = ANY(p_dates::date[]) (index-safe cast)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_eans        text[] DEFAULT NULL,
    p_subdept     text   DEFAULT NULL
)
RETURNS TABLE(
    dept_name   text,
    total_sales numeric,
    total_cost  numeric,
    total_qty   numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        ROUND(SUM(today_sales)::numeric, 2) AS total_sales,
        ROUND(SUM(today_cost)::numeric,  2) AS total_cost,
        SUM(today_qty)::numeric             AS total_qty
    FROM  daily_snapshots
    WHERE store_code          = ANY(p_store_codes)
      AND snapshot_date        = ANY(p_dates::date[])
      AND today_sales           > 0
      AND (p_eans    IS NULL OR ean           = ANY(p_eans))
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;


-- ---------------------------------------------------------------------------
-- STEP 2b -- Recreate rpc_kpi_dept_counts
--
-- Signature unchanged from the last deployed version:
--   p_store_codes text[]
--   p_dates       text[]
--   p_subdept     text  DEFAULT NULL
--
-- Only change: snapshot_date = ANY(p_dates::date[]) (index-safe cast)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rpc_kpi_dept_counts(
    p_store_codes text[],
    p_dates       text[],
    p_subdept     text DEFAULT NULL
)
RETURNS TABLE(
    dept_name        text,
    neg_soh_count    bigint,
    slow_mover_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        COUNT(*) FILTER (WHERE soh < 0)                    AS neg_soh_count,
        COUNT(*) FILTER (WHERE soh > 0 AND period_qty = 0) AS slow_mover_count
    FROM (
        SELECT DISTINCT ON (store_code, ean)
            TRIM(REPLACE(dept_name, '.', '')) AS dept_name,
            soh,
            period_qty
        FROM  daily_snapshots
        WHERE store_code          = ANY(p_store_codes)
          AND snapshot_date        = ANY(p_dates::date[])
          AND NOT is_placeholder
          AND dept_name            IS NOT NULL
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
        ORDER BY store_code, ean, snapshot_date DESC
    ) latest
    GROUP BY dept_name
    ORDER BY dept_name;
$$;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Re-grant EXECUTE (DROP CASCADE discards all grants)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text[], text)
    TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.rpc_kpi_dept_counts(text[], text[], text)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Reload PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY -- should return exactly 2 rows
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('rpc_dept_summary', 'rpc_kpi_dept_counts')
ORDER  BY p.proname;
-- Expected: 2 rows, 1 per function, no overloads.
-- After running, hard-refresh the dashboard.
-- Sales by Department should load in under 3 seconds (index-scan instead of seqscan).
