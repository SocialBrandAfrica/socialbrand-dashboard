-- =============================================================================
-- BUG-1 FIX: rpc_top20 CTE rewrite (SB-AUD-002 Option B)
--
-- Root cause: the movers branch ran TWO identical full-table scans of
-- daily_snapshots (one ranked by total_sales, one by total_qty).
-- On 26 dates x 5 stores (~10M+ rows) Supabase's statement timeout fires.
--
-- Fix: aggregate daily_snapshots ONCE in a MATERIALIZED CTE, then derive
-- both top-20 rankings from the in-memory result set. One scan instead of two.
--
-- Non-movers branch is unchanged (DISTINCT ON approach; already one scan).
--
-- Also supersedes restore_top20_params.sql -- this is the file to run.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke ALL overloads
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate with single-scan CTE on the movers branch
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
  -- DISTINCT ON pins to the latest snapshot per EAN; no change from v2.
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
            AND s.period_qty      = 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  -- ---- Movers branch (default) --------------------------------------------
  -- KEY CHANGE: aggregate daily_snapshots ONCE in a MATERIALIZED CTE so that
  -- the UNION of top-20-by-value and top-20-by-qty reads the aggregated rows
  -- (at most one row per EAN) rather than the full snapshot table twice.
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
      (SELECT ean, description, dept_name, sub_dept_name, size, unit, total_sales, total_qty
         FROM agg ORDER BY total_sales DESC LIMIT 20)
      UNION
      (SELECT ean, description, dept_name, sub_dept_name, size, unit, total_sales, total_qty
         FROM agg ORDER BY total_qty DESC LIMIT 20);

  END IF;

END;
$$;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Re-grant EXECUTE (DROP CASCADE discards all grants)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[], text, boolean)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY -- should return exactly 1 row with 7 arguments
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'rpc_top20';
-- Expected: 1 row, 7 args matching the signature above
