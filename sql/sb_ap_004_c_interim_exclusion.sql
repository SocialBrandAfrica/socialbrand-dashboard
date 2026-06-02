-- =============================================================================
-- SB-AP-004 Option C -- Interim exclusion of ghost and production stock
-- from Capital Tied, Top 20, and routes excluded lines to Reports.
--
-- BRIDGE DECISION (2026-06-02):
--   The dArtNr-to-daily_snapshots bridge is not available for PLU/scale items
--   (PRODUCTION, NON_STOCK) via any persistent server table. The correct path
--   is the SQL pipeline (Option B), which will replace PRSSALE with direct
--   dw220sdb reads where daily_snapshots is keyed on dArtNr natively.
--   Until that day, this file implements Option C: apply the funnel's
--   structural classification rules directly to daily_snapshots.dept_name
--   and sub_dept_name -- the same fields the funnel uses, already present in
--   daily_snapshots from PRSSALE. Self-contained, fully automated, no manual
--   dependency. INTERIM marker on the tooltip.
--
-- SUPERSEDES: sb_ap_003_a3_capital_exclusion.sql (product_classification JOIN).
--   That approach is retired until the dArtNr bridge is available (Option B).
--
-- WHAT CHANGES:
--   classify_snapshot_item()   -- new helper: PRODUCTION/NON_STOCK/RECEIPTING_BREAK
--   is_fresh_perishable()      -- new helper: perishable sub-category structural check
--   v_kpi_by_date              -- capital_tied + ghost_stock_value use classify fn
--   mv_kpi_by_date             -- same (DROP + recreate)
--   rpc_kpi_dept_counts        -- slow_mover_count excludes classified items
--   rpc_top20                  -- non-movers exclude classified items
--   rpc_ghost_stock_report     -- rebuilt on classify fn (no product_classification)
--   rpc_stock_integrity_report -- new: RECEIPTING_BREAK + fresh impossible-stock
--
-- OPTION B REPLACE (when SQL pipeline ships):
--   Replace classify_snapshot_item() calls with:
--     LEFT JOIN product_classification pc ON pc.store_code = ds.store_code
--                                        AND pc.ean = ds.ean
--   And restore the COALESCE(pc.band,'STOCK') != 'AUTO_EXCLUDE' pattern.
--   The product_classification table and RPC remain in place -- just reconnect.
--
-- DEPLOYMENT ORDER:
--   1. Run STEP 0 (functions) -- no risk.
--   2. Run STEP 1 (v_kpi_by_date) -- live immediately.
--   3. Run STEP 2 (mv_kpi_by_date) -- during low traffic; DROP + recreate.
--   4. Run STEP 3 (rpc_kpi_dept_counts).
--   5. Run STEP 4 (rpc_top20).
--   6. Run STEP 5 (rpc_ghost_stock_report).
--   7. Run STEP 6 (rpc_stock_integrity_report).
--   8. Run the RECONCILE block at the bottom -- record before/after for PM.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0A -- classify_snapshot_item()
--
-- Returns the exclusion class for an item based on dept/sub-dept structure
-- and SOH. NULL = normal retail stock, included in Capital Tied as-is.
--
-- Rules mirror store_funnel.py (SB-AP-004 A1) applied to daily_snapshots
-- fields. Order is load-bearing.
--
-- PRODUCTION sub-dept keywords (signals: unambiguous in-store production):
--   PRODUCTION, INGREDIENTS, CATERING, SCALE PRODUCT, WASTAGE, (PRODUCTI
--   Note: BUY OUT is deliberately excluded -- bought-in items, NOT production.
--
-- NON_STOCK dept/sub-dept (consumed by store, never a retail unit):
--   Dept-level: EXPENSES, FRONTEND PACK, NON SCAN SALES, AIRTIME, etc.
--   Sub-dept: PACKAGING, CRATE, ADVERTISING, PACK & WRAP, FUTURE USE.
--   Note: STATIONERY, CLEANING, HARDWARE are retail depts -- NOT included.
--
-- RECEIPTING_BREAK: SOH < -50. Data integrity; fix at source in Sigma.
--   (These are already outside the capital_tied soh>0 bucket, but flagged
--   here for the Stock Integrity report.)
--
-- IMMUTABLE: no dependency on current time or any table. PostgreSQL can
-- inline or cache results. All date-dependent logic (fresh alerts) is
-- handled separately in is_fresh_perishable() + inline CURRENT_DATE checks.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.classify_snapshot_item(
    p_dept    text,
    p_subdept text,
    p_soh     numeric
)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE

        -- ------------------------------------------------------------------
        -- NON_STOCK: entire dept is non-stock (store expense / admin).
        -- UPPER() handles the one mixed-case outlier "Department Overs/Unders".
        -- ------------------------------------------------------------------
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'EXPENSES',
            'FRONTEND PACK',
            'NON SCAN SALES',
            'AIRTIME',
            'SPAR MOBILE',
            'ONLINE VAS PRODUCTS',
            'ONLINE TRANSACTIONS',
            'DC - SPECIAL PROMOTIONS',
            'DEPARTMENT OVERS/UNDERS'
        ) THEN 'NON_STOCK'

        -- ------------------------------------------------------------------
        -- NON_STOCK: sub-dept keyword signals (store-use, unambiguous).
        -- These appear inside production/grocery depts too (BAKERY PACKAGING).
        -- ------------------------------------------------------------------
        WHEN COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
          OR COALESCE(p_subdept, '') ILIKE '%CRATE%'
          OR COALESCE(p_subdept, '') ILIKE '%ADVERTISING%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK & WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK&WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        THEN 'NON_STOCK'

        -- ------------------------------------------------------------------
        -- PRODUCTION: production dept + sub-dept structural signals.
        -- BUY OUT is explicitly excluded: bought-in product, not in-house.
        -- ------------------------------------------------------------------
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND (
               COALESCE(p_subdept, '') ILIKE '%PRODUCTION%'
            OR COALESCE(p_subdept, '') ILIKE '%(PRODUCTI%'
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%CATERING%'
            OR COALESCE(p_subdept, '') ILIKE '%SCALE PRODUCT%'
            OR COALESCE(p_subdept, '') ILIKE '%WASTAGE%'
         )
        THEN 'PRODUCTION'

        -- ------------------------------------------------------------------
        -- RECEIPTING_BREAK: large negative SOH. Already outside capital_tied
        -- (which requires soh > 0), but flagged for Stock Integrity report.
        -- ------------------------------------------------------------------
        WHEN COALESCE(p_soh, 0) < -50 THEN 'RECEIPTING_BREAK'

        ELSE NULL

    END;
$$;

GRANT EXECUTE ON FUNCTION public.classify_snapshot_item(text, text, numeric)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 0B -- is_fresh_perishable()
--
-- Returns TRUE if an item is in a short-shelf-life fresh dept and sub-dept
-- (i.e. it physically cannot hold stock for 30+ days without sale).
-- IMMUTABLE: purely structural (dept/sub-dept names only, no date).
--
-- Fresh depts (short shelf life):
--   BAKERY, BUTCHERY, HMR, DELI, PRODUCE, PERISHABLES, FISH SHOP, SEAFOOD,
--   FLOWERS, COFFEE SHOP.
--
-- Sub-dept exclusions (long shelf life even within fresh depts):
--   FROZEN, ICE CREAM, LONG LIFE, CANNED, TINNED, PACKAGING, INGREDIENTS,
--   BUY OUT, PREPACKED, CONFECTIONARY, RUSKS, BISCUITS, FUTURE USE.
--
-- Usage in queries:
--   is_fresh_perishable(dept, subdept)
--   AND soh > 0
--   AND (last_sales_date_iso IS NULL
--        OR last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_fresh_perishable(
    p_dept    text,
    p_subdept text
)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT
        UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'PRODUCE', 'PERISHABLES', 'FISH SHOP', 'FISH', 'SEAFOOD',
            'FLOWERS', 'COFFEE SHOP'
        )
        AND NOT (
               COALESCE(p_subdept, '') ILIKE '%FROZEN%'
            OR COALESCE(p_subdept, '') ILIKE '%ICE CREAM%'
            OR COALESCE(p_subdept, '') ILIKE '%LONG LIFE%'
            OR COALESCE(p_subdept, '') ILIKE '%CANNED%'
            OR COALESCE(p_subdept, '') ILIKE '%TINNED%'
            OR COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%BUY OUT%'
            OR COALESCE(p_subdept, '') ILIKE '%PREPACKED%'
            OR COALESCE(p_subdept, '') ILIKE '%CONFECTIONARY%'
            OR COALESCE(p_subdept, '') ILIKE '%RUSKS%'
            OR COALESCE(p_subdept, '') ILIKE '%BISCUITS%'
            OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        );
$$;

GRANT EXECUTE ON FUNCTION public.is_fresh_perishable(text, text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- STEP 1 -- v_kpi_by_date
--
-- Capital Tied now excludes:
--   a) classify_snapshot_item() != NULL  (PRODUCTION, NON_STOCK)
--   b) is_fresh_perishable() with stale stock (30+ days no sale)
--
-- ghost_stock_value = rand value of all excluded items in the slow-mover
-- bucket. Reconciles: capital_tied + ghost_stock_value = pre-exclusion total.
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

    -- Slow movers: genuine dead stock only (exclude ghost and non-stock)
    COUNT(*) FILTER (
        WHERE ds.period_qty     = 0
          AND ds.soh            > 0
          AND ds.is_placeholder = FALSE
          AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
              IS NULL
          AND NOT (
              is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
              AND (ds.last_sales_date_iso IS NULL
                   OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
          )
    )                                                                        AS slow_mover_count,

    -- Capital Tied: slow-mover bucket, ghost/production/non-stock removed.
    -- INTERIM: exclusion is by dept/sub-dept rule.
    -- Option B (SQL pipeline): replace with product_classification verdict join.
    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                 IS NULL
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

    -- Ghost stock value: rand value removed from Capital Tied.
    -- = PRODUCTION + NON_STOCK + fresh-impossible items in the slow-mover bucket.
    -- capital_tied + ghost_stock_value = pre-exclusion Capital Tied.
    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND (
                 classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
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

-- Quick verify (should show ghost_stock_value > 0 for store 10116):
-- SELECT store_code, snapshot_date, capital_tied, ghost_stock_value,
--        capital_tied + ghost_stock_value AS capital_was
-- FROM   v_kpi_by_date
-- WHERE  store_code = '10116'
-- ORDER  BY snapshot_date DESC LIMIT 3;


-- ---------------------------------------------------------------------------
-- STEP 2 -- mv_kpi_by_date (must DROP + recreate)
--
-- MV cannot use CURRENT_DATE (it would be stale after refresh).
-- Fresh-stock alert requires CURRENT_DATE, so fresh exclusion is NOT in the MV.
-- The MV excludes PRODUCTION + NON_STOCK only (structural, time-independent).
-- v_kpi_by_date (single-date, live queries) applies the full fresh exclusion.
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
          AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
              IS NULL
    )                                                                        AS slow_mover_count,

    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                 IS NULL
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS capital_tied,

    -- ghost_stock_value in MV: PRODUCTION + NON_STOCK only (no fresh: time-dep)
    ROUND(SUM(
        CASE
            WHEN ds.period_qty     = 0
             AND ds.soh            > 0
             AND ds.is_placeholder = FALSE
             AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                 IN ('PRODUCTION', 'NON_STOCK')
            THEN ds.soh * COALESCE(ds.unit_cost, 0)
            ELSE 0
        END
    )::numeric, 2)                                                           AS ghost_stock_value

FROM daily_snapshots ds
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date
ORDER  BY ds.store_code, ds.snapshot_date DESC;

CREATE UNIQUE INDEX idx_mv_kpi_store_date ON mv_kpi_by_date (store_code, snapshot_date);
GRANT SELECT ON public.mv_kpi_by_date TO anon, authenticated;

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_kpi_by_date;

-- Verify: 5 rows, one per store
-- SELECT store_code, MAX(snapshot_date) AS latest_date, COUNT(*) AS dates
-- FROM   mv_kpi_by_date GROUP BY store_code ORDER BY store_code;


-- ---------------------------------------------------------------------------
-- STEP 3 -- rpc_kpi_dept_counts
-- Exclude classified items from slow_mover_count at the dept level.
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
              AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                  IS NULL
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
-- Non-movers branch: exclude ghost and non-stock items from slow-mover list.
-- Movers branch (today_sales > 0) is unchanged.
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

  -- ---- Non-Movers branch --------------------------------------------------
  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    RETURN QUERY
      SELECT
          latest.ean, latest.description, latest.dept_name,
          latest.sub_dept_name, latest.size, latest.unit,
          latest.total_sales, latest.total_qty
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
          WHERE s.store_code     = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.soh             > 0
            AND s.period_qty      = 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
            -- Exclude ghost/non-stock
            AND classify_snapshot_item(s.dept_name, s.sub_dept_name, s.soh) IS NULL
            -- Exclude fresh impossible-stock
            AND NOT (
                is_fresh_perishable(s.dept_name, s.sub_dept_name)
                AND (s.last_sales_date_iso IS NULL
                     OR s.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
            )
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  -- ---- Movers branch (unchanged) ------------------------------------------
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
-- STEP 5 -- rpc_ghost_stock_report
--
-- Lists PRODUCTION and NON_STOCK items in the slow-mover bucket for the
-- latest date. These are the lines removed from Capital Tied.
-- The total ghost_value here reconciles against capital_tied reduction.
-- Report goes to the Ghost Stock panel in the Reports drawer.
--
-- No longer uses product_classification (Option C).
-- Signature unchanged from SB-AP-003 so frontend requires no change.
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
    exclusion_class text,   -- PRODUCTION | NON_STOCK | FRESH_ALERT
    score           int,    -- NULL (no classifier score in Option C)
    why_flagged     text,   -- human-readable rule that fired
    confirmed_by    text    -- always NULL in Option C (auto-classified)
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    -- PRODUCTION and NON_STOCK slow-movers
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
        MAX(classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)) AS exclusion_class,
        NULL::int                                                            AS score,
        MAX(
            CASE classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                WHEN 'PRODUCTION' THEN 'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'') || ' | production input'
                WHEN 'NON_STOCK'  THEN 'dept=' || ds.dept_name || ' sub=' || COALESCE(ds.sub_dept_name,'') || ' | non-stock / store-use'
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
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
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
      AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh) IS NULL
      AND is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
      AND (ds.last_sales_date_iso IS NULL
           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
    GROUP BY ds.store_code, ds.ean, ds.last_sales_date_iso

    ORDER BY ghost_value DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_ghost_stock_report(text[], text)
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- STEP 6 -- rpc_stock_integrity_report
--
-- Lists items routed to the Stock Integrity report:
--   a) RECEIPTING_BREAK: soh < -50 (data integrity, fix at source in Sigma)
--   b) FRESH impossible-stock: perishable + positive SOH + no movement 30+ days
--      (already in Ghost Stock report; shown here again for the store manager
--       because it is a physical impossibility, not just a classification choice)
--
-- Note: RECEIPTING_BREAK items are NOT removed from capital_tied (soh < 0
-- is already outside the soh > 0 capital bucket). They appear here for the
-- store manager to investigate and correct.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_stock_integrity_report CASCADE;

CREATE FUNCTION public.rpc_stock_integrity_report(
    p_store_codes  text[],
    p_date         text
)
RETURNS TABLE(
    store_code     text,
    store_name     text,
    ean            text,
    description    text,
    dept_name      text,
    sub_dept_name  text,
    soh            numeric,
    sell_price     numeric,
    integrity_type text,    -- RECEIPTING_BREAK | FRESH_IMPOSSIBLE
    days_no_sale   int,     -- NULL for RECEIPTING_BREAK
    value_at_risk  numeric  -- |soh| * sell_price
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    -- RECEIPTING_BREAK: large negative SOH
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.sell_price)                                                   AS sell_price,
        'RECEIPTING_BREAK'::text                                             AS integrity_type,
        NULL::int                                                            AS days_no_sale,
        ROUND((ABS(MAX(ds.soh)) * COALESCE(MAX(ds.sell_price), 0))::numeric, 2) AS value_at_risk
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            < -50
    GROUP BY ds.store_code, ds.ean

    UNION ALL

    -- FRESH impossible-stock
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                   AS store_name,
        ds.ean,
        MAX(ds.description)                                                  AS description,
        MAX(ds.dept_name)                                                    AS dept_name,
        MAX(ds.sub_dept_name)                                                AS sub_dept_name,
        MAX(ds.soh)                                                          AS soh,
        MAX(ds.sell_price)                                                   AS sell_price,
        'FRESH_IMPOSSIBLE'::text                                             AS integrity_type,
        MAX(CASE
            WHEN ds.last_sales_date_iso IS NULL THEN NULL
            ELSE (CURRENT_DATE - ds.last_sales_date_iso)::int
        END)                                                                 AS days_no_sale,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.sell_price), 0))::numeric, 2)  AS value_at_risk
    FROM daily_snapshots ds
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND ds.soh            > 0
      AND is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
      AND (ds.last_sales_date_iso IS NULL
           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
    GROUP BY ds.store_code, ds.ean

    ORDER BY integrity_type, value_at_risk DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_stock_integrity_report(text[], text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- =============================================================================
-- RECONCILE -- run after all steps to confirm before/after headline for PM.
-- Expected: capital_tied ~R1M, ghost_stock_value ~R7.9M for store 10116.
-- Capital_tied + ghost_stock_value = pre-exclusion total (~R8.97M).
-- =============================================================================

-- Before/after Capital Tied for store 10116 (latest date):
SELECT
    store_code,
    snapshot_date,
    capital_tied,
    ghost_stock_value,
    capital_tied + ghost_stock_value AS capital_before_exclusion
FROM   v_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;

-- Ghost Stock line count and total:
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

-- Stock Integrity line count:
SELECT
    integrity_type,
    COUNT(*)             AS lines,
    SUM(value_at_risk)   AS total_value_at_risk
FROM rpc_stock_integrity_report(
    ARRAY['10116'],
    (SELECT MAX(snapshot_date)::text FROM daily_snapshots WHERE store_code = '10116')
)
GROUP BY integrity_type;
