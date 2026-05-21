-- =============================================================================
-- Item A: Restore p_activity and p_parents to rpc_top20
--
-- p_activity ('movers' | 'non_movers', DEFAULT 'movers')
--   'movers'     = products that sold today (today_sales > 0)
--                  Returns union of top-20-by-value + top-20-by-qty (40 rows max)
--                  so the client can switch between By Qty / By Value without
--                  a second RPC call.
--   'non_movers' = products in stock (soh > 0) with no period sales
--                  Returns top 40 by capital tied (soh * sell_price DESC)
--                  total_qty  = SOH (units on shelf)
--                  total_sales = SOH * sell_price (capital tied up)
--                  Client re-sorts by total_qty (By Qty = most units) or
--                  total_sales (By Value = most capital) as usual.
--
-- p_parents (boolean, DEFAULT FALSE)
--   FALSE = exclude is_placeholder rows (PLU/parent catalogue stubs)
--   TRUE  = include all rows including placeholders
--
-- Also supersedes fix_top20_overload.sql — this is the one file to run.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke ALL overloads (no signature = removes every version)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate with the full correct 7-param signature
--
-- Index rule: use snapshot_date = ANY(p_dates::date[]) NOT ::text cast —
-- casting the column to text destroys the index on this 10M+ row table.
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
  -- Products with stock (soh > 0) and no period sales (period_qty = 0).
  -- Uses DISTINCT ON to pin to the latest snapshot per EAN across the date range.
  -- total_qty  = SOH (how many units are sitting on the shelf)
  -- total_sales = SOH * sell_price (how much capital is tied up)
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
              s.ean                                                  AS ean,
              s.description                                          AS description,
              s.dept_name                                            AS dept_name,
              s.sub_dept_name                                        AS sub_dept_name,
              s.size                                                 AS size,
              s.unit                                                 AS unit,
              ROUND((s.soh * COALESCE(s.sell_price, 0))::numeric, 2) AS total_sales,
              s.soh::numeric                                         AS total_qty
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

  -- ── Movers branch (default) ───────────────────────────────────────────────
  -- Products that sold today (today_sales > 0).
  -- UNION of top-20-by-value + top-20-by-qty = up to 40 rows returned.
  -- Client picks which 20 to display based on moverMode without a second call.
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
