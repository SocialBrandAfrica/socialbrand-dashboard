-- =============================================================================
-- Phase 2c fix -- Add description + dept names to daily_aggregates
-- SB-AP-005 v1.1 -- 2026-05-17
--
-- Run in Supabase SQL Editor BEFORE triggering the re-push from the store server.
--
-- Why: The initial push wrote NULL dept_code and no description because
-- PLU_d.d_text and the Dgrp_d dept-name join were missing from the push script.
-- These columns are now added here so the re-push can populate them.
--
-- Order: run this SQL first, then re-run the push script on srsdelareyvilesvr.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 0 -- Create reference tables (safe to run if they already exist)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS departments (
    client_id  UUID        NOT NULL REFERENCES clients(id),
    dept_code  TEXT        NOT NULL,
    dept_name  TEXT,
    PRIMARY KEY (client_id, dept_code)
);

CREATE TABLE IF NOT EXISTS sub_departments (
    client_id     UUID        NOT NULL REFERENCES clients(id),
    sub_dept_code TEXT        NOT NULL,
    sub_dept_name TEXT,
    dept_code     TEXT,
    PRIMARY KEY (client_id, sub_dept_code)
);

-- Verify
SELECT 'departments'    AS tbl, COUNT(*) AS rows FROM departments
UNION ALL
SELECT 'sub_departments', COUNT(*) FROM sub_departments;


-- ---------------------------------------------------------------------------
-- STEP 1 -- Add metadata columns to daily_aggregates
-- ---------------------------------------------------------------------------

ALTER TABLE daily_aggregates ADD COLUMN IF NOT EXISTS description   TEXT;
ALTER TABLE daily_aggregates ADD COLUMN IF NOT EXISTS dept_name     TEXT;
ALTER TABLE daily_aggregates ADD COLUMN IF NOT EXISTS sub_dept_name TEXT;

-- Verify
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'daily_aggregates'
  AND column_name  IN ('description', 'dept_name', 'sub_dept_name')
ORDER BY column_name;


-- ---------------------------------------------------------------------------
-- STEP 2 -- Wipe existing rows for store 10116
-- EAN values may change if d_intnr yields real barcodes for some products.
-- Deleting first guarantees the re-push lands cleanly with no stale rows.
-- daily_snapshots is NOT touched.
-- ---------------------------------------------------------------------------

DELETE FROM daily_aggregates WHERE store_code = '10116';


-- ---------------------------------------------------------------------------
-- STEP 3 -- Update v_dept_by_date
-- Now reads dept_name directly from daily_aggregates -- no daily_snapshots join.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_dept_by_date AS
SELECT
  store_code,
  agg_date                                   AS snapshot_date,
  COALESCE(dept_name, dept_code, 'Unknown')  AS dept_name,
  ROUND(SUM(sales_inc_vat)::numeric, 2)      AS dept_sales,
  ROUND(SUM(cost_of_sales)::numeric, 2)      AS dept_cost,
  SUM(qty_sold)::numeric                      AS dept_qty
FROM daily_aggregates
WHERE sales_inc_vat > 0
GROUP BY store_code, agg_date, COALESCE(dept_name, dept_code, 'Unknown');

COMMENT ON VIEW v_dept_by_date IS
  'Phase 2c v1.1: dept_name read from daily_aggregates directly.';


-- ---------------------------------------------------------------------------
-- STEP 4 -- Update rpc_dept_summary
-- Reads from daily_aggregates directly -- no daily_snapshots join.
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
    SELECT
        COALESCE(dept_name, dept_code, 'Unknown')  AS dept_name,
        ROUND(SUM(sales_inc_vat)::numeric, 2)      AS total_sales,
        ROUND(SUM(cost_of_sales)::numeric, 2)      AS total_cost,
        SUM(qty_sold)::numeric                      AS total_qty
    FROM daily_aggregates
    WHERE store_code     = ANY(p_store_codes)
      AND agg_date::text = ANY(p_dates)
      AND sales_inc_vat  > 0
    GROUP BY COALESCE(dept_name, dept_code, 'Unknown')
    ORDER BY total_sales DESC;
$$;


-- ---------------------------------------------------------------------------
-- STEP 5 -- Update rpc_top20
-- Reads description + dept metadata from daily_aggregates directly.
-- size and unit are not in daily_aggregates -- returned as NULL (not rendered
-- by the current dashboard).
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
    WITH agg AS (
        SELECT
            ean,
            MAX(description)                         AS description,
            MAX(dept_name)                           AS dept_name,
            MAX(sub_dept_name)                       AS sub_dept_name,
            ROUND(SUM(sales_inc_vat)::numeric, 2)   AS total_sales,
            SUM(qty_sold)::numeric                   AS total_qty
        FROM daily_aggregates
        WHERE store_code     = ANY(p_store_codes)
          AND agg_date::text = ANY(p_dates)
          AND sales_inc_vat  > 0
          AND (p_dept    IS NULL OR dept_name     = p_dept)
          AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
        GROUP BY ean
    )
    (SELECT ean, description, dept_name, sub_dept_name,
            NULL::text AS size, NULL::text AS unit,
            total_sales, total_qty
     FROM agg ORDER BY total_sales DESC LIMIT 20)
    UNION
    (SELECT ean, description, dept_name, sub_dept_name,
            NULL::text AS size, NULL::text AS unit,
            total_sales, total_qty
     FROM agg ORDER BY total_qty DESC LIMIT 20);
$$;


-- ---------------------------------------------------------------------------
-- STEP 6 -- Post-repush verification (run after the store server re-push)
-- ---------------------------------------------------------------------------

-- Should show descriptions and dept names once re-push completes
SELECT agg_date, description, dept_name, sub_dept_name,
       sales_inc_vat, qty_sold
FROM daily_aggregates
WHERE store_code = '10116'
ORDER BY agg_date DESC, sales_inc_vat DESC
LIMIT 10;

-- Dept summary should show named rows
SELECT dept_name, total_sales
FROM rpc_dept_summary(ARRAY['10116'], ARRAY['2026-05-15'])
ORDER BY total_sales DESC
LIMIT 5;

-- Top 20 should show descriptions
SELECT ean, description, dept_name, total_sales
FROM rpc_top20(ARRAY['10116'], ARRAY['2026-05-15'])
ORDER BY total_sales DESC
LIMIT 5;
