-- =============================================================================
-- SB-AP-002 Step 7 — Daily aggregates table
-- daily_aggregates — from Sigma DW220sDB.DBAUms
-- Pre-aggregated daily sales by product. Pulse reads this for historical
-- charts without scanning all of transaction_lines.
-- =============================================================================

CREATE TABLE IF NOT EXISTS daily_aggregates (
  client_id       UUID NOT NULL,
  store_code      TEXT NOT NULL,
  agg_date        DATE NOT NULL,
  ean             TEXT NOT NULL,
  plu_code        TEXT,
  dept_code       TEXT,
  sub_dept_code   TEXT,
  qty_sold        NUMERIC(10,3),
  sales_ex_vat    NUMERIC(12,2),
  sales_inc_vat   NUMERIC(12,2),
  cost_of_sales   NUMERIC(12,2),
  gp_amount       NUMERIC(12,2),
  gp_pct          NUMERIC(5,2),
  pushed_at       TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, agg_date, ean)
);

CREATE INDEX IF NOT EXISTS idx_daily_agg_store_date
  ON daily_aggregates (store_code, agg_date DESC);
CREATE INDEX IF NOT EXISTS idx_daily_agg_dept
  ON daily_aggregates (dept_code, store_code, agg_date DESC);

-- Verify
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name = 'daily_aggregates';
