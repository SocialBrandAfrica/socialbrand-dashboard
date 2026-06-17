-- =============================================================================
-- PRODUCTION FIX: Drop all overloaded RPC versions and recreate clean
--
-- Root cause: CREATE OR REPLACE with a different parameter list creates a NEW
-- PostgreSQL function overload instead of replacing the existing one.
-- PostgREST sees multiple signatures and cannot resolve which to call, returning
-- "could not choose a best candidate function" for every RPC request.
--
-- Affected functions (with overload counts before this fix):
--   rpc_dept_summary    -- 3 overloads (2-param, 3-param, 4-param)
--   rpc_top20           -- 2 overloads (4-param, 5-param)
--   rpc_kpi_dept_counts -- 2 overloads (2-param, 3-param)
--
-- Fix: DROP CASCADE all known signatures, then CREATE exactly once.
-- GRANT EXECUTE is re-applied inline because DROP discards all grants.
--
-- Run this entire script in one go in the Supabase SQL Editor.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Drop all overloads
-- We use explicit signatures so we don't accidentally drop a function that
-- happens to share only its name. CASCADE drops dependent grants automatically.
-- ---------------------------------------------------------------------------

-- rpc_dept_summary (3 overloads to drop)
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[])                CASCADE;
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text[])        CASCADE;
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text[], text)  CASCADE;

-- rpc_top20 (2 overloads to drop)
DROP FUNCTION IF EXISTS public.rpc_top20(text[], text[], text, text)           CASCADE;
DROP FUNCTION IF EXISTS public.rpc_top20(text[], text[], text, text, text[])   CASCADE;

-- rpc_kpi_dept_counts (2 overloads to drop)
DROP FUNCTION IF EXISTS public.rpc_kpi_dept_counts(text[], text[])             CASCADE;
DROP FUNCTION IF EXISTS public.rpc_kpi_dept_counts(text[], text[], text)       CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate rpc_dept_summary (single version, final signature)
--
-- Supports all callers:
--   loadViews / subdept effect  -> p_store_codes, p_dates [, p_subdept]
--   EAN filter (if re-enabled)  -> p_store_codes, p_dates, p_eans
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_dept_summary(
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
        ROUND(SUM(today_sales)::numeric, 2)  AS total_sales,
        ROUND(SUM(today_cost)::numeric,  2)  AS total_cost,
        SUM(today_qty)::numeric              AS total_qty
    FROM  daily_snapshots
    WHERE store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
      AND today_sales         > 0
      AND (p_eans    IS NULL OR ean           = ANY(p_eans))
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text[], text)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Recreate rpc_top20 (single version, final signature)
--
-- 5 params. p_eans not currently used by page.jsx but kept for compatibility.
-- UNION of top-20-by-value and top-20-by-qty so the client can switch modes
-- without a second round-trip.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_top20(
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

GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[])
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Recreate rpc_kpi_dept_counts (single version, final signature)
--
-- Used by KPI cards for dept-filtered Negative SOH + Slow Movers counts.
-- DISTINCT ON pins to the latest snapshot per EAN per store within the window.
-- dept_name is normalised (dots stripped) to match UI chip labels.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_kpi_dept_counts(
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
        WHERE store_code         = ANY(p_store_codes)
          AND snapshot_date::text = ANY(p_dates)
          AND NOT is_placeholder
          AND dept_name           IS NOT NULL
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
        ORDER BY store_code, ean, snapshot_date DESC
    ) latest
    GROUP BY dept_name
    ORDER BY dept_name;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_kpi_dept_counts(text[], text[], text)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY -- run this SELECT after the above completes to confirm exactly
-- one signature exists per function name
-- ---------------------------------------------------------------------------
SELECT
    p.proname                                   AS function_name,
    pg_get_function_arguments(p.oid)            AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname IN ('rpc_dept_summary', 'rpc_top20', 'rpc_kpi_dept_counts')
ORDER  BY p.proname;
-- Expected: exactly 1 row per function name
