-- =============================================================================
-- Phase 2c -- Migrate Pulse to daily_aggregates + stock_snapshots
-- SB-AP-005 v1.0 -- 2026-05-17
-- Run in Supabase SQL Editor (paste all at once).
--
-- What this does:
--   - Replaces v_kpi_by_date to read from daily_aggregates + stock_snapshots
--   - Refreshes mv_kpi_by_date (calendar date picker)
--   - Replaces rpc_dept_summary to read from daily_aggregates
--   - Replaces rpc_top20 to read from daily_aggregates
--   - Includes verification queries at the bottom
--
-- What this does NOT do:
--   - Does NOT drop daily_snapshots (PRSSALE pipeline keeps writing to it)
--   - Does NOT change any output column names or function signatures
--   - Does NOT touch any dashboard JavaScript
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Verify new data is present (run these first; inspect results)
-- ---------------------------------------------------------------------------

-- Dates and row counts for SPAR Delareyville
SELECT agg_date, COUNT(*) AS row_count
FROM daily_aggregates
WHERE store_code = '10116'
GROUP BY agg_date
ORDER BY agg_date DESC;

-- Total sales incl. VAT for the three most recent dates
SELECT agg_date, ROUND(SUM(sales_inc_vat)::numeric, 2) AS total_sales_incl_vat
FROM daily_aggregates
WHERE store_code = '10116'
GROUP BY agg_date
ORDER BY agg_date DESC
LIMIT 3;

-- Latest stock snapshot and SKU count
SELECT MAX(snapshot_at) AS last_snapshot, COUNT(*) AS sku_count
FROM stock_snapshots
WHERE store_code = '10116';


-- ---------------------------------------------------------------------------
-- STEP 2 -- Replace v_kpi_by_date
--
-- Output columns are UNCHANGED (dashboard JS reads by name):
--   store_code, store_name, snapshot_date (aliased from agg_date),
--   total_sales, total_cost, total_qty, neg_soh_count, slow_mover_count
--
-- neg_soh_count and slow_mover_count reflect the latest stock snapshot per
-- store (not per date). All date-rows for the same store show the same value.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_kpi_by_date AS
WITH
-- One row per (store_code, ean): the most recent SOH from stock_snapshots
latest_soh AS (
  SELECT DISTINCT ON (store_code, ean)
    store_code,
    ean,
    soh
  FROM stock_snapshots
  ORDER BY store_code, ean, snapshot_at DESC
),

-- Neg SOH count per store -- constant, reflects latest snapshot
neg_soh_by_store AS (
  SELECT store_code, COUNT(*) AS neg_soh_count
  FROM latest_soh
  WHERE soh < 0
  GROUP BY store_code
),

-- EANs with any sales in the rolling 21-day window per store
sold_21d AS (
  SELECT DISTINCT store_code, ean
  FROM daily_aggregates
  WHERE qty_sold > 0
    AND agg_date >= CURRENT_DATE - INTERVAL '21 days'
),

-- Slow movers: positive SOH AND no sales in the last 21 days (constant per store)
slow_movers_by_store AS (
  SELECT ls.store_code, COUNT(*) AS slow_mover_count
  FROM latest_soh ls
  WHERE ls.soh > 0
    AND NOT EXISTS (
      SELECT 1 FROM sold_21d s
      WHERE s.store_code = ls.store_code AND s.ean = ls.ean
    )
  GROUP BY ls.store_code
),

-- Sales totals per (store_code, agg_date)
daily_sales AS (
  SELECT
    store_code,
    agg_date,
    SUM(qty_sold)      AS total_qty,
    SUM(sales_inc_vat) AS total_sales,
    SUM(cost_of_sales) AS total_cost
  FROM daily_aggregates
  GROUP BY store_code, agg_date
)

SELECT
  ds.store_code,
  COALESCE(st.store_name, ds.store_code)    AS store_name,
  ds.agg_date                               AS snapshot_date,
  ROUND(ds.total_sales::numeric, 2)         AS total_sales,
  ROUND(ds.total_cost::numeric, 2)          AS total_cost,
  ds.total_qty::numeric                     AS total_qty,
  COALESCE(n.neg_soh_count,  0)::bigint     AS neg_soh_count,
  COALESCE(sm.slow_mover_count, 0)::bigint  AS slow_mover_count
FROM daily_sales ds
LEFT JOIN stores st             ON st.store_code = ds.store_code
LEFT JOIN neg_soh_by_store n    ON n.store_code  = ds.store_code
LEFT JOIN slow_movers_by_store sm ON sm.store_code = ds.store_code;

COMMENT ON VIEW v_kpi_by_date IS
  'Phase 2c: reads from daily_aggregates (sales/cost/qty) and stock_snapshots (SOH). Replaces daily_snapshots source from Phase 3.';


-- ---------------------------------------------------------------------------
-- STEP 2b -- Replace v_dept_by_date
--
-- Used by DeptTable.jsx (.from('v_dept_by_date').eq('snapshot_date', date)).
-- Output columns UNCHANGED: store_code, snapshot_date, dept_name,
--   dept_sales, dept_cost, dept_qty
-- dept_code -> dept_name is looked up from daily_snapshots (same pattern as
-- rpc_dept_summary below).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_dept_by_date AS
WITH dept_lookup AS (
  SELECT DISTINCT ON (store_code, dept_code)
    store_code,
    dept_code,
    dept_name
  FROM daily_snapshots
  ORDER BY store_code, dept_code, snapshot_date DESC
)
SELECT
  da.store_code,
  da.agg_date                                AS snapshot_date,
  COALESCE(dl.dept_name, da.dept_code)       AS dept_name,
  ROUND(SUM(da.sales_inc_vat)::numeric, 2)   AS dept_sales,
  ROUND(SUM(da.cost_of_sales)::numeric, 2)   AS dept_cost,
  SUM(da.qty_sold)::numeric                   AS dept_qty
FROM daily_aggregates da
LEFT JOIN dept_lookup dl
       ON dl.store_code = da.store_code
      AND dl.dept_code  = da.dept_code
WHERE da.sales_inc_vat > 0
GROUP BY da.store_code, da.agg_date, COALESCE(dl.dept_name, da.dept_code);

COMMENT ON VIEW v_dept_by_date IS
  'Phase 2c: reads from daily_aggregates. dept_name looked up from daily_snapshots.';


-- ---------------------------------------------------------------------------
-- STEP 3 -- Refresh mv_kpi_by_date
--
-- The calendar uses this materialised view for date discovery. Without the
-- refresh, 2026-05-16 and 2026-05-17 will not appear in the calendar even
-- though v_kpi_by_date is now correct.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_matviews
    WHERE schemaname = 'public' AND matviewname = 'mv_kpi_by_date'
  ) THEN
    REFRESH MATERIALIZED VIEW mv_kpi_by_date;
    RAISE NOTICE 'mv_kpi_by_date refreshed.';
  ELSE
    RAISE NOTICE 'mv_kpi_by_date does not exist -- skipping refresh.';
  END IF;
END $$;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Replace rpc_dept_summary
--
-- Signature UNCHANGED: p_store_codes text[], p_dates text[]
-- Returns UNCHANGED:   dept_name text, total_sales numeric, total_cost numeric, total_qty numeric
--
-- dept_code -> dept_name is looked up from daily_snapshots (which always has
-- names). Falls back to dept_code if no match (new depts not yet in snapshots).
-- No is_placeholder filter -- matches v_kpi_by_date which includes all rows,
-- ensuring service depts (HMR, Deli, Butchery) appear as chips.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    dept_name   text,
    total_sales numeric,
    total_cost  numeric,
    total_qty   numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH dept_lookup AS (
        -- Most recent dept_code -> dept_name mapping per store from daily_snapshots
        SELECT DISTINCT ON (store_code, dept_code)
            store_code,
            dept_code,
            dept_name
        FROM daily_snapshots
        WHERE store_code = ANY(p_store_codes)
        ORDER BY store_code, dept_code, snapshot_date DESC
    )
    SELECT
        COALESCE(dl.dept_name, da.dept_code)       AS dept_name,
        ROUND(SUM(da.sales_inc_vat)::numeric, 2)   AS total_sales,
        ROUND(SUM(da.cost_of_sales)::numeric, 2)   AS total_cost,
        SUM(da.qty_sold)::numeric                   AS total_qty
    FROM daily_aggregates da
    LEFT JOIN dept_lookup dl
           ON dl.store_code = da.store_code
          AND dl.dept_code  = da.dept_code
    WHERE da.store_code     = ANY(p_store_codes)
      AND da.agg_date::text = ANY(p_dates)
      AND da.sales_inc_vat  > 0
    GROUP BY COALESCE(dl.dept_name, da.dept_code)
    ORDER BY total_sales DESC;
$$;


-- ---------------------------------------------------------------------------
-- STEP 5 -- Replace rpc_top20
--
-- Signature UNCHANGED: p_store_codes, p_dates, p_dept, p_subdept
-- Returns UNCHANGED:   ean, description, dept_name, sub_dept_name, size, unit,
--                      total_sales, total_qty
--
-- Product metadata (description, dept_name, sub_dept_name, size, unit) is
-- looked up from daily_snapshots because daily_aggregates carries no names.
-- is_placeholder = FALSE filter is preserved (via the metadata join).
-- dept and sub-dept filters use names (not codes) to match existing behaviour.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rpc_top20(
    p_store_codes  text[],
    p_dates        text[],
    p_dept         text DEFAULT NULL,
    p_subdept      text DEFAULT NULL
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
    WITH
    -- Most recent product metadata per (store_code, ean) from daily_snapshots
    meta AS (
        SELECT DISTINCT ON (store_code, ean)
            store_code,
            ean,
            description,
            dept_name,
            sub_dept_name,
            size,
            unit,
            is_placeholder
        FROM daily_snapshots
        WHERE store_code = ANY(p_store_codes)
        ORDER BY store_code, ean, snapshot_date DESC
    ),
    agg AS (
        SELECT
            da.ean,
            MAX(m.description)                       AS description,
            MAX(m.dept_name)                         AS dept_name,
            MAX(m.sub_dept_name)                     AS sub_dept_name,
            MAX(m.size)                              AS size,
            MAX(m.unit)                              AS unit,
            ROUND(SUM(da.sales_inc_vat)::numeric, 2) AS total_sales,
            SUM(da.qty_sold)::numeric                AS total_qty
        FROM daily_aggregates da
        LEFT JOIN meta m ON m.store_code = da.store_code AND m.ean = da.ean
        WHERE da.store_code     = ANY(p_store_codes)
          AND da.agg_date::text = ANY(p_dates)
          AND da.sales_inc_vat  > 0
          AND (m.is_placeholder IS NULL OR m.is_placeholder = FALSE)
          AND (p_dept    IS NULL OR m.dept_name     = p_dept)
          AND (p_subdept IS NULL OR m.sub_dept_name = p_subdept)
        GROUP BY da.ean
    )
    (SELECT * FROM agg ORDER BY total_sales DESC LIMIT 20)
    UNION
    (SELECT * FROM agg ORDER BY total_qty DESC LIMIT 20);
$$;


-- ---------------------------------------------------------------------------
-- STEP 6 -- Validate: compare old and new totals for a shared date
--
-- A variance of up to 2% is acceptable (rounding, timing).
-- More than 5% needs investigation before proceeding.
-- Adjust the date if 2026-05-15 is not in both tables.
-- ---------------------------------------------------------------------------

-- Old pipeline total for 2026-05-15 (today_sales = sales incl. VAT in daily_snapshots)
SELECT 'daily_snapshots' AS source,
       ROUND(SUM(today_sales)::numeric, 2) AS total_sales_incl_vat
FROM daily_snapshots
WHERE store_code   = '10116'
  AND snapshot_date = '2026-05-15';

-- New pipeline total for the same date
SELECT 'daily_aggregates' AS source,
       ROUND(SUM(sales_inc_vat)::numeric, 2) AS total_sales_incl_vat
FROM daily_aggregates
WHERE store_code = '10116'
  AND agg_date   = '2026-05-15';

-- v_kpi_by_date spot check: should show new dates 2026-05-16 and 2026-05-17
SELECT snapshot_date, total_sales, total_qty, neg_soh_count, slow_mover_count
FROM v_kpi_by_date
WHERE store_code = '10116'
ORDER BY snapshot_date DESC
LIMIT 7;

-- v_dept_by_date spot check (powers DeptTable.jsx)
SELECT snapshot_date, dept_name, dept_sales, dept_cost, dept_qty
FROM v_dept_by_date
WHERE store_code = '10116'
  AND snapshot_date = '2026-05-17'
ORDER BY dept_sales DESC;

-- rpc_dept_summary spot check for 2026-05-17 (powers dept filter chips)
SELECT dept_name, total_sales, total_cost, total_qty
FROM rpc_dept_summary(ARRAY['10116'], ARRAY['2026-05-17'])
ORDER BY total_sales DESC
LIMIT 10;

-- rpc_top20 spot check for 2026-05-17 (top 10 by value)
SELECT ean, description, dept_name, total_sales, total_qty
FROM rpc_top20(ARRAY['10116'], ARRAY['2026-05-17'])
ORDER BY total_sales DESC
LIMIT 10;
