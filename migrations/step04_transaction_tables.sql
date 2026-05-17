-- =============================================================================
-- SB-AP-002 Step 4 — Transaction tables
-- transaction_headers, transaction_lines, transaction_payments + all indexes
-- New tables only. Do NOT populate yet — wait for the push script.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- transaction_headers — from Sigma npos.T_h1
-- One row per transaction
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transaction_headers (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  txn_number     BIGINT NOT NULL,
  txn_date       DATE NOT NULL,
  txn_time       TIME,
  till_number    SMALLINT,
  cashier_code   TEXT,
  total_amount   NUMERIC(12,2),
  item_count     INT,
  txn_type       TEXT,
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, txn_date, txn_number)
);

CREATE INDEX IF NOT EXISTS idx_txn_headers_store_date
  ON transaction_headers (store_code, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_txn_headers_cashier
  ON transaction_headers (cashier_code, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_txn_headers_till
  ON transaction_headers (till_number, txn_date DESC);

-- -----------------------------------------------------------------------------
-- transaction_lines — from Sigma npos.T_l1
-- One row per product per transaction. Largest table in the system.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transaction_lines (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  txn_number     BIGINT NOT NULL,
  txn_date       DATE NOT NULL,
  line_seq       SMALLINT NOT NULL,
  ean            TEXT NOT NULL,
  plu_code       TEXT,
  description    TEXT,
  qty            NUMERIC(10,3),
  unit_price     NUMERIC(10,4),
  line_total     NUMERIC(12,2),
  dept_code      TEXT,
  sub_dept_code  TEXT,
  is_promotion   BOOLEAN DEFAULT false,
  promotion_code TEXT,
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, txn_date, txn_number, line_seq)
);

CREATE INDEX IF NOT EXISTS idx_txn_lines_store_date
  ON transaction_lines (store_code, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_txn_lines_ean
  ON transaction_lines (ean, store_code, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_txn_lines_dept
  ON transaction_lines (dept_code, store_code, txn_date DESC);

-- -----------------------------------------------------------------------------
-- transaction_payments — from Sigma npos.T_pay
-- One row per payment method per transaction
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transaction_payments (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  txn_number     BIGINT NOT NULL,
  txn_date       DATE NOT NULL,
  payment_type   TEXT NOT NULL,
  amount         NUMERIC(12,2),
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, txn_date, txn_number, payment_type)
);

-- -----------------------------------------------------------------------------
-- Verify — all 3 tables must appear
-- -----------------------------------------------------------------------------
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('transaction_headers', 'transaction_lines', 'transaction_payments')
ORDER BY table_name;
