-- =============================================================================
-- Non-Movers definition v2
--
-- Problem with v1 (fix_non_movers_definition.sql):
--   1. last_sales_date_iso is a DATE column, not text. The NULLIF(col, '')::date
--      cast is invalid on a date column — comparing date to '' throws a type
--      error in PostgreSQL. In plpgsql this caused silent empty returns.
--   2. period_qty = 0 is Sigma's month-to-date counter. A product that sold
--      on the 1st of the month but not since shows period_qty > 0 even though
--      it hasn't moved in weeks. Wrong metric for "no sales in 4 weeks".
--
-- New definition (per PM brief):
--   A Non-Mover is a product that:
--     - Has stock on hand (soh > 0)
--     - Has a positive rate of sale — sold at least once (last_sales_date_iso IS NOT NULL)
--     - Sold within the last year (last_sales_date_iso >= CURRENT_DATE - 365 days)
--     - Has NOT sold in the last 4 weeks (last_sales_date_iso <= CURRENT_DATE - 28 days)
--
--   These four conditions collapse to one BETWEEN check on a date column:
--     last_sales_date_iso BETWEEN (CURRENT_DATE - INTERVAL '365 days')
--                              AND (CURRENT_DATE - INTERVAL '28 days')
--
-- Verified: 1,336,612 rows qualify across all stores (diagnostic 2026-05-21).
--
-- Movers branch is UNCHANGED.
-- Signature is UNCHANGED — still 7 params.
--
-- Follow Rule 3: DROP CASCADE then CREATE FUNCTION (never CREATE OR REPLACE).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Nuke ALL overloads
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate with corrected non_movers definition
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
  -- A Non-Mover = in stock (soh > 0) AND sold at least once but not in the
  -- last 4 weeks AND sold within the last year.
  --
  -- last_sales_date_iso is a DATE column. BETWEEN is index-friendly and handles
  -- NULLs correctly (NULL IS NOT BETWEEN anything, so never-sold items are
  -- excluded automatically — no explicit IS NOT NULL needed).
  --
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
