-- =============================================================================
-- SB-AP-003 Actions A3 + A4 — Exclude production (ghost) stock from
--   Capital Tied, slow_mover_count, and Top 20 non-movers.
--   Surface ghost_stock_value as a separate reported figure (A4).
--
-- WHAT CHANGES:
--   v_kpi_by_date      — LEFT JOIN product_classification; exclude AUTO_EXCLUDE
--                         from capital_tied + slow_mover_count; add ghost_stock_value.
--   mv_kpi_by_date     — Same. DROP + recreate (MV columns cannot be added).
--   rpc_kpi_dept_counts — Exclude AUTO_EXCLUDE from slow_mover_count (dept view).
--   rpc_top20 non-movers — Exclude AUTO_EXCLUDE lines from the non-mover list.
--
-- LEFT JOIN SAFETY:
--   Items with no row in product_classification (stores not yet classified,
--   or EANs added after the last classifier run) default to band NULL which
--   is treated as STOCK — they are included in Capital Tied normally.
--   This means stores 80175, 21355, 80176, 80579 are unaffected until loaded.
--
-- DEPLOYMENT ORDER:
--   1. Confirm product_classification is loaded (A1 + A2 complete):
--         SELECT band, COUNT(*) FROM product_classification
--         WHERE store_code = '10116' GROUP BY band;
--         -- Must show AUTO_EXCLUDE=249  REVIEW=742  STOCK=12345
--   2. Run Step 1 (v_kpi_by_date) — live immediately.
--   3. Run Step 2 (mv_kpi_by_date) — DROP + recreate; brief downtime.
--      Run during low-traffic window. Run REFRESH after.
--   4. Run Step 3 (rpc_kpi_dept_counts) — live immediately.
--   5. Run Step 4 (rpc_top20 non-movers) — live immediately.
--   6. Deploy frontend (Step 5) after all SQL confirmed.
--
-- Unblocks: AUD-010, SEL-P3.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 — v_kpi_by_date (live view, single-date KPI queries)
--
-- New columns added at the END (CREATE OR REPLACE requires append-only):
--   ghost_stock_value = capital of AUTO_EXCLUDE items in the slow-mover bucket.
--
-- Note: capital_tied is deliberately limited to the slow-mover bucket
-- (period_qty=0, soh>0) matching the historical definition. A full-range
-- capital_tied (all active lines) is a future change — not in this brief.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_by_date AS
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,

    SUM(ds.today_sales)                                                            AS total_sales,
    SUM(ds.today_cost)                                                             AS total_cost,
    SUM(ds.today_qty)                                                              AS total_qty,

    COUNT(*) FILTER (WHERE ds.soh < 0)                                            AS neg_soh_count,

    -- Slow movers: exclude AUTO_EXCLUDE (production items masquerading as unsold stock)
    COUNT(*) FILTER (
        WHERE ds.period_qty = 0
          AND ds.soh > 0
          AND ds.is_placeholder = FALSE
          AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
    )                                                                              AS slow_mover_count,

    -- Capital Tied: slow-mover bucket, production items removed
    ROUND(SUM(
        CASE WHEN ds.period_qty = 0
              AND ds.soh > 0
              AND ds.is_placeholder = FALSE
              AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                 AS capital_tied,

    -- ex-VAT sales (appended last — CREATE OR REPLACE is position-sensitive)
    ROUND(SUM(
        ds.today_sales / (1.0 + COALESCE(ds.vat_pct, 15) / 100.0)
    )::numeric, 2)                                                                 AS total_sales_ex_vat,

    -- Ghost stock value: what was removed from Capital Tied for this store+date.
    -- = rand value of AUTO_EXCLUDE items that were in the slow-mover bucket.
    -- Surface this in the KPI card footnote and ghost stock report.
    ROUND(SUM(
        CASE WHEN COALESCE(pc.band, 'STOCK') = 'AUTO_EXCLUDE'
              AND ds.period_qty = 0
              AND ds.soh > 0
              AND ds.is_placeholder = FALSE
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                 AS ghost_stock_value

FROM daily_snapshots ds
LEFT JOIN product_classification pc
       ON pc.store_code = ds.store_code
      AND pc.ean        = ds.ean
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date;

GRANT SELECT ON v_kpi_by_date TO anon, authenticated;

-- Quick verify
SELECT store_code, snapshot_date, capital_tied, ghost_stock_value,
       capital_tied + ghost_stock_value AS capital_was
FROM   v_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;
-- Expected for store 10116 after loading 249 AUTO_EXCLUDE rows:
--   ghost_stock_value > 0, capital_tied < capital_was.


-- ---------------------------------------------------------------------------
-- STEP 2 — mv_kpi_by_date (materialized view, multi-date / trend queries)
--
-- Must DROP and recreate — MV columns cannot be altered in place.
-- Run during a low-traffic window. The dashboard shows loading state briefly.
-- REFRESH immediately after; pg_cron job at 18:30 UTC handles nightly refresh.
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_by_date CASCADE;

CREATE MATERIALIZED VIEW mv_kpi_by_date AS
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,

    SUM(ds.today_sales)                                                            AS total_sales,
    ROUND(SUM(
        ds.today_sales / (1.0 + COALESCE(ds.vat_pct, 15) / 100.0)
    )::numeric, 2)                                                                 AS total_sales_ex_vat,
    SUM(ds.today_cost)                                                             AS total_cost,
    SUM(ds.today_qty)                                                              AS total_qty,

    COUNT(*) FILTER (WHERE ds.soh < 0)                                            AS neg_soh_count,

    COUNT(*) FILTER (
        WHERE ds.period_qty = 0
          AND ds.soh > 0
          AND ds.is_placeholder = FALSE
          AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
    )                                                                              AS slow_mover_count,

    ROUND(SUM(
        CASE WHEN ds.period_qty = 0
              AND ds.soh > 0
              AND ds.is_placeholder = FALSE
              AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                 AS capital_tied,

    ROUND(SUM(
        CASE WHEN COALESCE(pc.band, 'STOCK') = 'AUTO_EXCLUDE'
              AND ds.period_qty = 0
              AND ds.soh > 0
              AND ds.is_placeholder = FALSE
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                 AS ghost_stock_value

FROM daily_snapshots ds
LEFT JOIN product_classification pc
       ON pc.store_code = ds.store_code
      AND pc.ean        = ds.ean
GROUP BY ds.store_code, ds.store_name, ds.snapshot_date
ORDER BY ds.store_code, ds.snapshot_date DESC;

CREATE UNIQUE INDEX idx_mv_kpi_store_date ON mv_kpi_by_date (store_code, snapshot_date);
GRANT SELECT ON mv_kpi_by_date TO anon, authenticated;

REFRESH MATERIALIZED VIEW mv_kpi_by_date;

-- Verify
SELECT store_code, MAX(snapshot_date) AS latest_date, COUNT(*) AS row_count
FROM   mv_kpi_by_date
GROUP  BY store_code
ORDER  BY store_code;
-- Expected: 5 rows, one per store, each with the same latest_date.


-- ---------------------------------------------------------------------------
-- STEP 3 — rpc_kpi_dept_counts
-- Exclude AUTO_EXCLUDE items from slow_mover_count at the dept level.
-- (Called when a dept/sub-dept filter is active on the dashboard.)
-- ---------------------------------------------------------------------------
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'rpc_kpi_dept_counts';
-- Must return exactly 1 row before proceeding.

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
        COUNT(*) FILTER (WHERE ds.soh < 0)                                              AS neg_soh_count,
        COUNT(*) FILTER (
            WHERE ds.period_qty = 0
              AND ds.soh > 0
              AND ds.is_placeholder = FALSE
              AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
        )                                                                               AS slow_mover_count
    FROM  daily_snapshots ds
    LEFT JOIN product_classification pc
           ON pc.store_code = ds.store_code
          AND pc.ean        = ds.ean
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
-- STEP 4 — rpc_top20 non-movers: exclude AUTO_EXCLUDE lines
--
-- Non-movers show items with soh>0 and period_qty=0 — exactly the ghost-stock
-- bucket. Without exclusion, production lines dominate the non-mover list.
-- The movers branch is unchanged (it filters by today_sales > 0, so production
-- lines that aren't selling already don't appear there).
--
-- Strategy: LEFT JOIN product_classification in the non_movers subquery;
-- add AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'.
-- The movers branch (ELSE) is reproduced verbatim — do not change it.
--
-- Per Function Change Protocol: check overloads, drop all, recreate.
-- ---------------------------------------------------------------------------
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'rpc_top20';
-- Must return exactly 1 row before proceeding.

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
  -- Exclude AUTO_EXCLUDE (ghost stock) from the list.
  -- DISTINCT ON pins to the latest snapshot per EAN.
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
          LEFT JOIN product_classification pc
                 ON pc.store_code = s.store_code
                AND pc.ean        = s.ean
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.soh             > 0
            AND s.period_qty      = 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR s.dept_name     = p_dept)
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
            AND COALESCE(pc.band, 'STOCK') != 'AUTO_EXCLUDE'
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  -- ---- Movers branch (default) — unchanged --------------------------------
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

SELECT pg_notify('pgrst', 'reload schema');

-- Verify rpc_top20: still exactly 1 overload.
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'rpc_top20';
-- Expected: 1 row.
