-- =============================================================================
-- SB-AP-002 Step 9 — New views
-- v_department_sales, v_cashier_performance, v_payment_splits, v_push_health
-- Existing views (v_diwaais, v_slow_movers, v_negative_soh) are NOT modified.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_department_sales — daily sales by department and store
-- Used by Pulse for the department chart
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_department_sales AS
SELECT
  client_id,
  store_code,
  agg_date,
  dept_code,
  SUM(qty_sold)       AS total_qty,
  SUM(sales_inc_vat)  AS total_sales,
  SUM(gp_amount)      AS total_gp,
  AVG(gp_pct)         AS avg_gp_pct
FROM daily_aggregates
GROUP BY client_id, store_code, agg_date, dept_code;

-- -----------------------------------------------------------------------------
-- v_cashier_performance — transactions, items and value per cashier per day
-- Used by TillWatch
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cashier_performance AS
SELECT
  client_id,
  store_code,
  txn_date,
  cashier_code,
  COUNT(*)            AS txn_count,
  SUM(item_count)     AS items_scanned,
  SUM(total_amount)   AS sales_total,
  AVG(total_amount)   AS avg_basket
FROM transaction_headers
WHERE txn_type = 'SALE'
GROUP BY client_id, store_code, txn_date, cashier_code;

-- -----------------------------------------------------------------------------
-- v_payment_splits — payment method breakdown per store per day
-- Used by TillWatch and Pulse
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payment_splits AS
SELECT
  client_id,
  store_code,
  txn_date,
  payment_type,
  COUNT(DISTINCT txn_number) AS txn_count,
  SUM(amount)                AS total_amount
FROM transaction_payments
GROUP BY client_id, store_code, txn_date, payment_type;

-- -----------------------------------------------------------------------------
-- v_push_health — last successful push per store per table
-- Used by Pulse as a data freshness indicator
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_push_health AS
WITH latest AS (
  SELECT DISTINCT ON (store_code, table_name)
    store_code,
    table_name,
    completed_at  AS last_success_at,
    rows_pushed   AS last_rows_pushed
  FROM push_log
  WHERE status = 'SUCCESS'
  ORDER BY store_code, table_name, completed_at DESC
)
SELECT
  store_code,
  table_name,
  last_success_at,
  last_rows_pushed,
  CASE
    WHEN last_success_at > now() - INTERVAL '25 hours' THEN 'OK'
    WHEN last_success_at > now() - INTERVAL '49 hours' THEN 'STALE'
    ELSE 'MISSING'
  END AS freshness
FROM latest
ORDER BY store_code, table_name;

-- -----------------------------------------------------------------------------
-- Verify — all 4 new views must appear
-- -----------------------------------------------------------------------------
SELECT table_name AS view_name
FROM information_schema.views
WHERE table_schema = 'public'
  AND table_name IN ('v_department_sales', 'v_cashier_performance', 'v_payment_splits', 'v_push_health')
ORDER BY table_name;
