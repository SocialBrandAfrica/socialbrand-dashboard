-- =============================================================================
-- PRODUCTION FIX: rpc_top20 still returning HTTP 500 after fix_rpc_overloads.sql
--
-- Root cause: fix_rpc_overloads.sql dropped two known overloads by explicit
-- signature but missed a third variant (phase2c_add_metadata_columns.sql created
-- a 4-param version that reads from daily_aggregates — different body, same
-- signature as the daily_snapshots 4-param, so PostgreSQL kept it as a separate
-- function entry). PostgREST still sees ambiguous overloads and returns 500.
--
-- Fix: DROP without specifying a signature — CASCADE removes ALL overloads of
-- rpc_top20 unconditionally, regardless of how many exist or what their
-- signatures are. Then CREATE FUNCTION (not CREATE OR REPLACE) builds exactly
-- one clean version.
--
-- rpc_dept_summary and rpc_kpi_dept_counts are confirmed fixed. Do not touch.
--
-- Run this entire script in one go in the Supabase SQL Editor.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke all rpc_top20 overloads (no signature = drops every one)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate exactly once using CREATE FUNCTION (not CREATE OR REPLACE)
--
-- Final signature:
--   p_store_codes  text[]
--   p_dates        text[]
--   p_dept         text    DEFAULT NULL
--   p_subdept      text    DEFAULT NULL
--   p_eans         text[]  DEFAULT NULL  (for future EAN-scoped calls)
--
-- Returns union of top-20-by-value + top-20-by-qty (up to 40 rows) so the
-- client can switch between qty/value mode without a second round-trip.
-- Reads from daily_snapshots (the live PRSSALE pipeline table).
-- is_placeholder = FALSE so PLU-only parent rows are excluded.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rpc_top20(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text   DEFAULT NULL,
    p_subdept      text   DEFAULT NULL,
    p_eans         text[] DEFAULT NULL
)
RETURNS TABLE(
    ean           text,
    description   text,
    dept_name     text,
    sub_dept_name text,
    size          text,
    unit          text,
    total_sales   numeric,
    total_qty     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    (
        SELECT
            ean,
            MAX(description)                    AS description,
            MAX(dept_name)                      AS dept_name,
            MAX(sub_dept_name)                  AS sub_dept_name,
            MAX(size)                           AS size,
            MAX(unit)                           AS unit,
            ROUND(SUM(today_sales)::numeric, 2) AS total_sales,
            SUM(today_qty)::numeric             AS total_qty
        FROM  daily_snapshots
        WHERE store_code         = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND today_sales         > 0
          AND is_placeholder      = FALSE
          AND (p_dept    IS NULL OR dept_name     = p_dept)
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
          AND (p_eans    IS NULL OR ean            = ANY(p_eans))
        GROUP BY ean
        ORDER BY total_sales DESC
        LIMIT 20
    )
    UNION
    (
        SELECT
            ean,
            MAX(description)                    AS description,
            MAX(dept_name)                      AS dept_name,
            MAX(sub_dept_name)                  AS sub_dept_name,
            MAX(size)                           AS size,
            MAX(unit)                           AS unit,
            ROUND(SUM(today_sales)::numeric, 2) AS total_sales,
            SUM(today_qty)::numeric             AS total_qty
        FROM  daily_snapshots
        WHERE store_code         = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND today_sales         > 0
          AND is_placeholder      = FALSE
          AND (p_dept    IS NULL OR dept_name     = p_dept)
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
          AND (p_eans    IS NULL OR ean            = ANY(p_eans))
        GROUP BY ean
        ORDER BY total_qty DESC
        LIMIT 20
    );
$$;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Re-grant EXECUTE (DROP CASCADE discards all grants)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[])
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY -- should return exactly 1 row
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'rpc_top20';
-- Expected: 1 row
--   rpc_top20 | p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL::text,
--               p_subdept text DEFAULT NULL::text, p_eans text[] DEFAULT NULL::text[]
