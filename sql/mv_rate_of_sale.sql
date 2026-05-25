-- =============================================================================
-- mv_rate_of_sale  --  materialized view replacing v_rate_of_sale
--
-- v_rate_of_sale was a live VIEW that triggered a full 18M-row scan on every
-- query. PostgREST's statement_timeout killed any real-time lookup. Converting
-- to a materialized view drops query time to milliseconds.
--
-- Steps:
--   1. DROP v_rate_of_sale (must go first -- mv name must not conflict)
--   2. CREATE MATERIALIZED VIEW mv_rate_of_sale
--   3. Add indexes for fast EAN / store_code lookups
--   4. Register pg_cron refresh (22:30 UTC nightly, after push + kpi jobs)
--   5. Initial REFRESH
--   6. Grant anon SELECT
--
-- Run in Supabase SQL Editor (Database → SQL Editor → New query).
-- =============================================================================

-- 1. Drop the old live view (no dependents -- safe)
DROP VIEW IF EXISTS public.v_rate_of_sale;

-- 2. Create the materialized view
CREATE MATERIALIZED VIEW public.mv_rate_of_sale AS
WITH store_max_date AS (
  SELECT store_code, MAX(snapshot_date) AS max_date
  FROM public.daily_snapshots
  GROUP BY store_code
),
ros_window AS (
  SELECT
    ds.ean,
    ds.store_code,
    SUM(ds.today_qty) AS total_qty_91d
  FROM public.daily_snapshots ds
  JOIN store_max_date smd ON ds.store_code = smd.store_code
  WHERE ds.snapshot_date >= (smd.max_date::date - INTERVAL '90 days')
    AND ds.snapshot_date <= smd.max_date
    AND ds.is_placeholder = FALSE
  GROUP BY ds.ean, ds.store_code
),
latest AS (
  SELECT DISTINCT ON (ds.store_code, ds.ean)
    ds.store_code,
    ds.store_name,
    ds.ean,
    ds.description,
    ds.dept_name,
    ds.sub_dept_name,
    ds.dept_code,
    ds.sub_dept_code,
    ds.soh,
    ds.sell_price,
    ds.unit_cost,
    ds.status,
    ds.internal_ref
  FROM public.daily_snapshots ds
  JOIN store_max_date smd
    ON ds.store_code = smd.store_code
   AND ds.snapshot_date = smd.max_date
  ORDER BY ds.store_code, ds.ean
)
SELECT
  l.store_code,
  l.store_name,
  l.ean,
  l.description,
  l.dept_name,
  l.sub_dept_name,
  l.dept_code,
  l.sub_dept_code,
  l.soh,
  l.sell_price,
  l.unit_cost,
  l.status,
  l.internal_ref,
  ROUND((COALESCE(r.total_qty_91d, 0) / 91.0)::NUMERIC, 4) AS daily_ros,
  CASE
    WHEN COALESCE(r.total_qty_91d, 0) = 0 THEN NULL
    ELSE ROUND((l.soh / (r.total_qty_91d / 91.0))::NUMERIC, 1)
  END AS days_cover
FROM latest l
LEFT JOIN ros_window r ON l.ean = r.ean AND l.store_code = r.store_code;

-- 3. Indexes for fast PostgREST lookups
CREATE UNIQUE INDEX mv_rate_of_sale_pk  ON public.mv_rate_of_sale (store_code, ean);
CREATE INDEX        mv_rate_of_sale_ean ON public.mv_rate_of_sale (ean);

-- 4. pg_cron: refresh nightly at 22:30 UTC (after push at 20:00 + kpi-refresh at 22:00)
SELECT cron.schedule(
  'nightly-ros-refresh',
  '30 22 * * *',
  $$REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_rate_of_sale;$$
);

-- 5. Initial populate (runs once now -- takes ~30s on 18M rows; safe to run)
REFRESH MATERIALIZED VIEW public.mv_rate_of_sale;

-- 6. Grant anon SELECT (PostgREST uses anon role for dashboard queries)
GRANT SELECT ON public.mv_rate_of_sale TO anon;

-- Verify
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT store_code) AS stores,
       COUNT(DISTINCT ean) AS eans
FROM public.mv_rate_of_sale;
-- Expected: ~60k-100k rows, 5 stores, many EANs
