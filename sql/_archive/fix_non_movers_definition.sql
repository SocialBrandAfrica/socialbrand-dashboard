-- =============================================================================
-- Issue 5: Non-Movers definition is wrong
--
-- Old behaviour: non_movers returned all products with soh > 0 AND period_qty = 0
-- This included true dead stock (never sold) and catalogue stubs with zero
-- history. Those aren't actionable — a manager can't do anything about a product
-- that hasn't moved in years.
--
-- New behaviour: a Non-Mover is a product that HAS sold within the last year
-- but is currently not moving in the selected period. It was recently active
-- but has stalled. That IS actionable.
--
-- Added filter to non_movers branch:
--   NULLIF(s.last_sales_date_iso, '')::date >= (CURRENT_DATE - INTERVAL '365 days')
--
-- Using NULLIF to safely handle empty strings (avoids cast error). NULL and empty
-- values evaluate as NULL >= date = NULL = false, so those rows are excluded.
-- Products that have never sold (last_sales_date_iso IS NULL or '') are excluded.
-- Products last sold more than 365 days ago are excluded.
--
-- Movers branch is UNCHANGED.
-- All other parameters and return columns are UNCHANGED.
--
-- Follow Rule 3: DROP CASCADE then CREATE FUNCTION (never CREATE OR REPLACE).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke ALL overloads
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate with updated non_movers definition
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

  -- ── Non-Movers branch ─────────────────────────────────────────────────────
  -- A Non-Mover = in stock (soh > 0), not moving this period (period_qty = 0),
  -- AND has sold at least once in the last 365 days (last_sales_date_iso >= -1yr).
  -- This excludes true dead stock and catalogue stubs with no sales history.
  -- Only shows products that were recently active but have stalled — actionable.
  --
  -- Uses DISTINCT ON to pin to the latest snapshot per EAN across the date range.
  -- total_qty  = SOH (units on shelf)
  -- total_sales = SOH * sell_price (capital tied up)
  -- Returns top 40 by capital so the client can re-sort by qty or value.
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
              s.ean                                                   AS ean,
              s.description                                           AS description,
              s.dept_name                                             AS dept_name,
              s.sub_dept_name                                         AS sub_dept_name,
              s.size                                                  AS size,
              s.unit                                                  AS unit,
              ROUND((s.soh * COALESCE(s.sell_price, 0))::numeric, 2) AS total_sales,
              s.soh::numeric                                          AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.soh             > 0
            AND s.period_qty      = 0
            AND NULLIF(s.last_sales_date_iso, '')::date >= (CURRENT_DATE - INTERVAL '365 days')
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  -- ── Movers branch (default) ───────────────────────────────────────────────
  -- Products that sold today (today_sales > 0). Unchanged.
  -- UNION of top-20-by-value + top-20-by-qty = up to 40 rows returned.
  ELSE
    RETURN QUERY
      (
          SELECT
              s.ean,
              MAX(s.description)                    AS description,
              MAX(s.dept_name)                      AS dept_name,
              MAX(s.sub_dept_name)                  AS sub_dept_name,
              MAX(s.size)                           AS size,
              MAX(s.unit)                           AS unit,
              ROUND(SUM(s.today_sales)::numeric, 2) AS total_sales,
              SUM(s.today_qty)::numeric             AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.today_sales     > 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          GROUP BY s.ean
          ORDER BY total_sales DESC
          LIMIT 20
      )
      UNION
      (
          SELECT
              s.ean,
              MAX(s.description)                    AS description,
              MAX(s.dept_name)                      AS dept_name,
              MAX(s.sub_dept_name)                  AS sub_dept_name,
              MAX(s.size)                           AS size,
              MAX(s.unit)                           AS unit,
              ROUND(SUM(s.today_sales)::numeric, 2) AS total_sales,
              SUM(s.today_qty)::numeric             AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.today_sales     > 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          GROUP BY s.ean
          ORDER BY total_qty DESC
          LIMIT 20
      );
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
-- VERIFY -- should return exactly 1 row with 7 arguments
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
--
-- After running, switch to Non-Movers mode and confirm the list shows
-- products with recent sales history (last_sales_date_iso within the last year)
-- rather than all in-stock zero-period-sales items.
