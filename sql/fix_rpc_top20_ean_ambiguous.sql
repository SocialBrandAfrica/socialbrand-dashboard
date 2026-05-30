-- =============================================================================
-- HOTFIX: rpc_top20 — ambiguous column reference "ean" (PostgreSQL 42702)
-- Ref: SB-CC-HOTFIX-001
-- Date: 2026-05-30
--
-- Root cause:
--   fix_rpc_top20_cte.sql (currently deployed) declared the function as
--   RETURNS TABLE(ean text, ...) and then used a bare "ean" in the UNION
--   SELECT list that reads from the MATERIALIZED CTE "agg". In plpgsql,
--   every column in RETURNS TABLE becomes an implicit OUT variable in the
--   function scope. PostgreSQL sees "ean" as ambiguous between agg.ean and
--   the OUT variable ean, and rejects the query with error 42702.
--
-- Fix:
--   Qualify every column reference in the UNION selects with "agg."
--   Everything else is identical to fix_rpc_top20_cte.sql.
--   The non-movers branch is unchanged.
--
-- Side note (deferred — not fixed here):
--   Non-movers branch uses INTERVAL '365 days' for the active-line lookback.
--   Rule Book requires 364 days. Fix deferred to a future SQL brief.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke ALL overloads
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate with qualified CTE column references
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.rpc_top20(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text    DEFAULT NULL,
    p_subdept      text    DEFAULT NULL,
    p_eans         text[]  DEFAULT NULL,
    p_activity     text    DEFAULT 'movers',
    p_parents      boolean DEFAULT FALSE
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
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN

  -- ---- Non-Movers branch --------------------------------------------------
  -- Unchanged from fix_rpc_top20_cte.sql. Already qualifies all columns
  -- with latest.* so no ambiguity issue here.
  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    RETURN QUERY
      SELECT
          latest.ean,
          latest.description,
          latest.dept_name,
          latest.sub_dept_name,
          latest.size,
          latest.unit,
          latest.total_sales,
          latest.total_qty
      FROM (
          SELECT DISTINCT ON (s.ean)
              s.ean,
              s.description,
              s.dept_name,
              s.sub_dept_name,
              s.size,
              s.unit,
              ROUND((s.soh * COALESCE(s.sell_price, 0))::numeric, 2) AS total_sales,
              s.soh::numeric                                          AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.soh             > 0
            AND s.last_sales_date_iso BETWEEN (CURRENT_DATE - INTERVAL '365 days')
                                          AND (CURRENT_DATE - INTERVAL '28 days')
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  -- ---- Movers branch (default) --------------------------------------------
  -- FIX: all UNION column references now qualified with agg.*
  -- This removes the ambiguity between agg.ean and the OUT variable ean.
  -- Logic and performance (MATERIALIZED CTE) are unchanged.
  ELSE
    RETURN QUERY
      WITH agg AS MATERIALIZED (
          SELECT
              s.ean,
              MAX(s.description)                     AS description,
              MAX(s.dept_name)                       AS dept_name,
              MAX(s.sub_dept_name)                   AS sub_dept_name,
              MAX(s.size)                            AS size,
              MAX(s.unit)                            AS unit,
              ROUND(SUM(s.today_sales)::numeric, 2)  AS total_sales,
              SUM(s.today_qty)::numeric              AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.today_sales     > 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          GROUP BY s.ean
      )
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_sales DESC LIMIT 20)
      UNION
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_qty DESC LIMIT 20);

  END IF;

END;
$$;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Re-grant EXECUTE (DROP CASCADE discards all grants)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[], text, boolean)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Reload PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY -- must return exactly 1 row with 7 arguments
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'rpc_top20';
-- Expected: 1 row
--   p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL,
--   p_subdept text DEFAULT NULL, p_eans text[] DEFAULT NULL,
--   p_activity text DEFAULT 'movers', p_parents boolean DEFAULT false
