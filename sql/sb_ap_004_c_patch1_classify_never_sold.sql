-- =============================================================================
-- SB-AP-004 Option C -- Patch 1: add never-sold signal to classify_snapshot_item
--
-- PROBLEM:  The initial classify_snapshot_item matched only sub_dept keywords
--   (INGREDIENTS, (PRODUCTI, CATERING, etc.).  The bulk of the ghost stock --
--   BEEF FOREQUARTER (R3.0M), BEEF HINDQUARTER (R2.2M), BUTCHERY PORK (R851K),
--   BUTCHERY LAMB (R1.4M), HMR HOT MEALS, SAUSAGES (PROD... truncated) --
--   uses end-consumer sub_dept names with no production keyword.
--   Total missed: ~R7.85M.  ghost_stock_value showed only R614.
--
-- FIX:  Mirror the Python funnel's Bucket 3b rule:
--   "received-but-never-sold in a production dept = production ghost stock".
--   Signal: last_sales_date_iso IS NULL (never scanned at a till) in a
--   production dept.  Also fixes the Sigma 30-char truncation "(PROD" pattern.
--
-- PRECONDITION:  sb_ap_004_c_interim_exclusion.sql must already have run
--   (functions + views + RPCs must exist).
--
-- DEPLOYMENT:  Run this full file in Supabase SQL Editor.
--   Steps 0A-0B update the functions.
--   Steps 1-6 rebuild all objects that call classify_snapshot_item.
--   Run the RECONCILE block at the end and report the numbers to PM.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0A -- classify_snapshot_item (updated)
--
-- New 4th parameter: p_last_sold date DEFAULT NULL
--   Pass daily_snapshots.last_sales_date_iso to get the full benefit.
--   Calling with 3 args still works (defaults to NULL = no never-sold check).
--
-- New rules added (in priority order before the existing ones):
--   3c. Production dept + never sold (last_sales_date_iso IS NULL)
--       = whole carcasses / bulk ingredients received but never sold at till.
--       Captures: BEEF FOREQUARTER, HINDQUARTER, BUTCHERY PORK/LAMB,
--                 HMR HOT MEALS, HMR SUSHI, SAUSAGES (PROD... truncated), etc.
--       Low false-positive risk: any item truly never sold in a production dept
--       with positive SOH is overwhelmingly a production input, not a new listing.
--
-- Also adds %(PROD% pattern to catch Sigma's 30-char truncations:
--   "SAUSAGES, B/WORS & MINCE (PROD" -- truncated from "(PRODUCTION)"
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.classify_snapshot_item(
    p_dept      text,
    p_subdept   text,
    p_soh       numeric,
    p_last_sold date DEFAULT NULL
)
RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE

        -- ---- NON_STOCK: entire dept is non-stock -------------------------
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'EXPENSES', 'FRONTEND PACK', 'NON SCAN SALES', 'AIRTIME',
            'SPAR MOBILE', 'ONLINE VAS PRODUCTS', 'ONLINE TRANSACTIONS',
            'DC - SPECIAL PROMOTIONS', 'DEPARTMENT OVERS/UNDERS'
        ) THEN 'NON_STOCK'

        -- ---- NON_STOCK: sub-dept keyword (store-use, unambiguous) --------
        WHEN COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
          OR COALESCE(p_subdept, '') ILIKE '%CRATE%'
          OR COALESCE(p_subdept, '') ILIKE '%ADVERTISING%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK & WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK&WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        THEN 'NON_STOCK'

        -- ---- PRODUCTION: sub-dept keyword signal -------------------------
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND (
               COALESCE(p_subdept, '') ILIKE '%PRODUCTION%'
            OR COALESCE(p_subdept, '') ILIKE '%(PRODUCTI%'
            OR COALESCE(p_subdept, '') ILIKE '%(PROD%'       -- catches 30-char truncations
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%CATERING%'
            OR COALESCE(p_subdept, '') ILIKE '%SCALE PRODUCT%'
            OR COALESCE(p_subdept, '') ILIKE '%WASTAGE%'
         )
        THEN 'PRODUCTION'

        -- ---- PRODUCTION: never-sold in a production dept (Bucket 3b) ----
        -- Whole carcasses, bulk ingredients, and in-store prepared lines
        -- that were received and stocked but never scanned at a till.
        -- Sub-dept names like BEEF FOREQUARTER, HMR HOT MEALS, BUTCHERY PORK
        -- have no production keyword -- the never-sold signal catches them.
        -- p_last_sold IS NULL = literally zero sales in the system ever.
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND p_last_sold IS NULL
        THEN 'PRODUCTION'

        -- ---- RECEIPTING_BREAK: large negative SOH ------------------------
        WHEN COALESCE(p_soh, 0) < -50 THEN 'RECEIPTING_BREAK'

        ELSE NULL

    END;
$$;

GRANT EXECUTE ON FUNCTION public.classify_snapshot_item(text, text, numeric, date)
    TO anon, authenticated;

-- Keep 3-arg overload for callers that don't pass last_sold
-- (PostgreSQL will match the 4-arg version when last_sold is passed)


-- ---------------------------------------------------------------------------
-- STEP 1 -- v_kpi_by_date (pass last_sales_date_iso as 4th arg)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_kpi_by_date AS
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,

    SUM(ds.today_sales)                                                      AS total_sales,
    SUM(ds.today_cost)                                                       AS total_cost,
    SUM(ds.today_qty)                                                        AS total_qty,
    COUNT(*) FILTER (WHERE ds.soh < 0)                                       AS neg_soh_count,

    COUNT(*) FILTER (
        WHERE ds.period_qty     = 0
          AND ds.soh            > 0
          AND ds.is_placeholder = FALSE
          AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                     ds.soh, ds.last_sales_date_iso) IS NULL
          AND NOT (
              is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
              AND (ds.last_sales_date_iso IS NULL
                   OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
          )
    )                                                                        AS slow_mover_count,

    -- Capital Tied: exclude ghost/production/non-stock. INTERIM -- Option B replaces.
    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso) IS NULL
             AND NOT (
                 is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                 AND (ds.last_sales_date_iso IS NULL
                      OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
             )
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS capital_tied,

    ROUND(SUM(
        ds.today_sales / (1.0 + COALESCE(ds.vat_pct, 15) / 100.0)
    )::numeric, 2)                                                           AS total_sales_ex_vat,

    -- Ghost stock value: capital removed from Capital Tied.
    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND (
                 classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso)
                     IN ('PRODUCTION', 'NON_STOCK')
                 OR (
                     is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                     AND (ds.last_sales_date_iso IS NULL
                          OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
                 )
             )
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS ghost_stock_value

FROM daily_snapshots ds
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date;

GRANT SELECT ON public.v_kpi_by_date TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 2 -- mv_kpi_by_date (DROP + recreate with last_sales_date_iso)
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_by_date CASCADE;

CREATE MATERIALIZED VIEW public.mv_kpi_by_date AS
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,

    SUM(ds.today_sales)                                                      AS total_sales,
    ROUND(SUM(
        ds.today_sales / (1.0 + COALESCE(ds.vat_pct, 15) / 100.0)
    )::numeric, 2)                                                           AS total_sales_ex_vat,
    SUM(ds.today_cost)                                                       AS total_cost,
    SUM(ds.today_qty)                                                        AS total_qty,
    COUNT(*) FILTER (WHERE ds.soh < 0)                                       AS neg_soh_count,

    COUNT(*) FILTER (
        WHERE ds.period_qty     = 0
          AND ds.soh            > 0
          AND ds.is_placeholder = FALSE
          AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                     ds.soh, ds.last_sales_date_iso) IS NULL
    )                                                                        AS slow_mover_count,

    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso) IS NULL
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS capital_tied,

    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso)
                 IN ('PRODUCTION', 'NON_STOCK')
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS ghost_stock_value

FROM daily_snapshots ds
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date
ORDER BY ds.store_code, ds.snapshot_date DESC;

CREATE UNIQUE INDEX idx_mv_kpi_store_date ON mv_kpi_by_date (store_code, snapshot_date);
GRANT SELECT ON public.mv_kpi_by_date TO anon, authenticated;

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_kpi_by_date;


-- ---------------------------------------------------------------------------
-- STEP 3 -- rpc_kpi_dept_counts
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_kpi_dept_counts CASCADE;

CREATE FUNCTION public.rpc_kpi_dept_counts(
    p_store_codes  text[],
    p_dates        text[],
    p_subdept      text    DEFAULT NULL,
    p_eans         text[]  DEFAULT NULL
)
RETURNS TABLE(
    dept_name        text,
    neg_soh_count    bigint,
    slow_mover_count bigint
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ds.dept_name,
        COUNT(*) FILTER (WHERE ds.soh < 0)                                   AS neg_soh_count,
        COUNT(*) FILTER (
            WHERE ds.period_qty     = 0
              AND ds.soh            > 0
              AND ds.is_placeholder = FALSE
              AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                         ds.soh, ds.last_sales_date_iso) IS NULL
              AND NOT (
                  is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                  AND (ds.last_sales_date_iso IS NULL
                       OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
              )
        )                                                                     AS slow_mover_count
    FROM  daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = ANY(p_dates::date[])
      AND (p_subdept IS NULL OR ds.sub_dept_name = p_subdept)
      AND (p_eans    IS NULL OR ds.ean            = ANY(p_eans))
    GROUP BY ds.dept_name
    ORDER BY ds.dept_name;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_kpi_dept_counts(text[], text[], text, text[])
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 4 -- rpc_top20
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_top20 CASCADE;

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

  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    RETURN QUERY
      SELECT latest.ean, latest.description, latest.dept_name,
             latest.sub_dept_name, latest.size, latest.unit,
             latest.total_sales, latest.total_qty
      FROM (
          SELECT DISTINCT ON (s.ean)
              s.ean, s.description, s.dept_name, s.sub_dept_name,
              s.size, s.unit,
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
            AND classify_snapshot_item(s.dept_name, s.sub_dept_name,
                                       s.soh, s.last_sales_date_iso) IS NULL
            AND NOT (
                is_fresh_perishable(s.dept_name, s.sub_dept_name)
                AND (s.last_sales_date_iso IS NULL
                     OR s.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
            )
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

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

GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[], text, boolean)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 5 -- rpc_ghost_stock_report (pass last_sales_date_iso)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_ghost_stock_report CASCADE;

CREATE FUNCTION public.rpc_ghost_stock_report(
    p_store_codes  text[],
    p_date         text
)
RETURNS TABLE(
    store_code      text,
    store_name      text,
    ean             text,
    description     text,
    dept_name       text,
    sub_dept_name   text,
    soh             numeric,
    unit_cost       numeric,
    ghost_value     numeric,
    exclusion_class text,
    score           int,
    why_flagged     text,
    confirmed_by    text
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    -- PRODUCTION and NON_STOCK slow-movers (incl. never-sold production inputs)
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.unit_cost)                                                    AS unit_cost,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.unit_cost), 0))::numeric, 2)   AS ghost_value,
        MAX(classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                   ds.soh, ds.last_sales_date_iso))         AS exclusion_class,
        NULL::int                                                            AS score,
        MAX(
            CASE classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                        ds.soh, ds.last_sales_date_iso)
                WHEN 'PRODUCTION' THEN
                    'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
                    || CASE WHEN ds.last_sales_date_iso IS NULL
                            THEN ' | never-sold production input'
                            ELSE ' | production sub-dept keyword'
                       END
                WHEN 'NON_STOCK' THEN
                    'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
                    || ' | non-stock/store-use'
                ELSE NULL
            END
        )                                                                    AS why_flagged,
        NULL::text                                                           AS confirmed_by
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND ds.period_qty     = 0
      AND ds.is_placeholder = FALSE
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                 ds.soh, ds.last_sales_date_iso)
          IN ('PRODUCTION', 'NON_STOCK')
    GROUP BY ds.store_code, ds.ean

    UNION ALL

    -- Fresh impossible-stock slow-movers
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.unit_cost)                                                    AS unit_cost,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.unit_cost), 0))::numeric, 2)   AS ghost_value,
        'FRESH_ALERT'::text                                                  AS exclusion_class,
        NULL::int                                                            AS score,
        MAX('dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'')
            || ' | fresh perishable, no sale '
            || COALESCE((CURRENT_DATE - ds.last_sales_date_iso)::text, 'ever')
            || 'd')                                                          AS why_flagged,
        NULL::text                                                           AS confirmed_by
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND ds.period_qty     = 0
      AND ds.is_placeholder = FALSE
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                 ds.soh, ds.last_sales_date_iso) IS NULL
      AND is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
      AND (ds.last_sales_date_iso IS NULL
           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
    GROUP BY ds.store_code, ds.ean, ds.last_sales_date_iso

    ORDER BY ghost_value DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_ghost_stock_report(text[], text)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 6 -- rpc_stock_integrity_report (unchanged -- no classify call)
-- ---------------------------------------------------------------------------
-- No change needed. Already uses soh < -50 and is_fresh_perishable directly.
-- If it returned 0 rows, either no receipting breaks or all fresh items
-- last_sales_date_iso > 30 days ago. Run separately to check.


-- ---------------------------------------------------------------------------
-- STEP 7 -- rpc_dept_summary (SEL-001 P3) -- pass last_sales_date_iso
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text, text[]);

CREATE FUNCTION public.rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_subdept     text   DEFAULT NULL,
    p_eans        text[] DEFAULT NULL
)
RETURNS TABLE(
    dept_name    text,
    total_sales  numeric,
    total_cost   numeric,
    total_qty    numeric,
    capital_tied numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH latest AS (
        SELECT store_code, MAX(snapshot_date) AS d
        FROM   daily_snapshots
        WHERE  store_code    = ANY(p_store_codes)
          AND  snapshot_date = ANY(p_dates::date[])
        GROUP  BY store_code
    )
    SELECT
        ds.dept_name,
        ROUND(SUM(ds.today_sales)::numeric, 2)  AS total_sales,
        ROUND(SUM(ds.today_cost)::numeric,  2)  AS total_cost,
        SUM(ds.today_qty)::numeric              AS total_qty,
        ROUND(SUM(
            CASE WHEN ds.snapshot_date = l.d
                  AND ds.period_qty     = 0
                  AND ds.soh            > 0
                  AND ds.is_placeholder = FALSE
                  AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name,
                                             ds.soh, ds.last_sales_date_iso) IS NULL
                  AND NOT (
                      is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                      AND (ds.last_sales_date_iso IS NULL
                           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
                  )
                 THEN ds.soh * COALESCE(ds.unit_cost, 0)
                 ELSE 0
            END
        )::numeric, 2)                          AS capital_tied
    FROM   daily_snapshots ds
    JOIN   latest l ON l.store_code = ds.store_code
    WHERE  ds.store_code    = ANY(p_store_codes)
      AND  ds.snapshot_date = ANY(p_dates::date[])
      AND  (p_subdept IS NULL OR ds.sub_dept_name = p_subdept)
      AND  (p_eans    IS NULL OR ds.ean            = ANY(p_eans))
    GROUP  BY ds.dept_name
    ORDER  BY ds.dept_name;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text, text[])
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- =============================================================================
-- RECONCILE -- run after all steps
-- Expected: capital_tied drops from ~R8.97M to ~R1M for store 10116.
-- ghost_stock_value should be ~R7.9M+.
-- =============================================================================

-- Step A: live Capital Tied (v_kpi_by_date, uses CURRENT_DATE for fresh filter)
SELECT
    store_code,
    snapshot_date,
    capital_tied,
    ghost_stock_value,
    capital_tied + ghost_stock_value AS capital_before_excl
FROM   v_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;

-- Step B: ghost stock report line count and totals
SELECT
    exclusion_class,
    COUNT(*)          AS lines,
    SUM(ghost_value)  AS total_rand
FROM rpc_ghost_stock_report(
    ARRAY['10116'],
    (SELECT MAX(snapshot_date)::text FROM daily_snapshots WHERE store_code = '10116')
)
GROUP BY exclusion_class
ORDER BY total_rand DESC;
