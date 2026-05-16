-- v_rate_of_sale
-- Run this once in the Supabase SQL editor (Database → SQL Editor → New query).
--
-- daily_ros  = total units sold (today_qty) in the last 91 days / 91
--              (today_qty is the per-day figure; period_qty is a cumulative period total
--               so we do NOT sum period_qty across rows)
-- days_cover = current SOH / daily_ros  (NULL when ROS = 0 to avoid div-by-zero)

CREATE OR REPLACE VIEW v_rate_of_sale AS
WITH store_max_date AS (
  -- Most recent snapshot date per store
  SELECT store_code, MAX(snapshot_date) AS max_date
  FROM daily_snapshots
  GROUP BY store_code
),
ros_window AS (
  -- Sum today_qty over the 91-day window ending on the latest snapshot date
  SELECT
    ds.ean,
    ds.store_code,
    SUM(ds.today_qty) AS total_qty_91d
  FROM daily_snapshots ds
  JOIN store_max_date smd ON ds.store_code = smd.store_code
  WHERE ds.snapshot_date >= (smd.max_date::date - INTERVAL '90 days')
    AND ds.snapshot_date <= smd.max_date
    AND ds.is_placeholder = FALSE
  GROUP BY ds.ean, ds.store_code
),
latest AS (
  -- One row per EAN × store from the most recent snapshot
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
  FROM daily_snapshots ds
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
