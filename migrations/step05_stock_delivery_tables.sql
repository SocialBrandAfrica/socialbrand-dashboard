-- =============================================================================
-- SB-AP-002 Step 5 — Stock, delivery and supplier invoice tables
-- stock_snapshots, deliveries, supplier_invoices + all indexes
-- New tables only. Do NOT populate yet — wait for the push script.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- stock_snapshots — from Sigma npos.PLU_s
-- Live SOH at a point in time. Replaces SOH column in daily_snapshots.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stock_snapshots (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  snapshot_at    TIMESTAMPTZ NOT NULL,
  ean            TEXT NOT NULL,
  plu_code       TEXT,
  soh            NUMERIC(10,3),
  reserved_qty   NUMERIC(10,3),
  available_qty  NUMERIC(10,3),
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, snapshot_at, ean)
);

CREATE INDEX IF NOT EXISTS idx_stock_snapshots_store
  ON stock_snapshots (store_code, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_snapshots_ean
  ON stock_snapshots (ean, store_code, snapshot_at DESC);

-- -----------------------------------------------------------------------------
-- deliveries — from Sigma DW220sDB.DBArlf
-- One row per product per delivery document
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS deliveries (
  client_id       UUID NOT NULL,
  store_code      TEXT NOT NULL,
  delivery_ref    TEXT NOT NULL,
  delivery_date   DATE NOT NULL,
  supplier_code   TEXT,
  ean             TEXT NOT NULL,
  plu_code        TEXT,
  description     TEXT,
  qty_ordered     NUMERIC(10,3),
  qty_received    NUMERIC(10,3),
  qty_variance    NUMERIC(10,3),
  unit_cost       NUMERIC(10,4),
  line_value      NUMERIC(12,2),
  pushed_at       TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, delivery_ref, ean)
);

CREATE INDEX IF NOT EXISTS idx_deliveries_store_date
  ON deliveries (store_code, delivery_date DESC);
CREATE INDEX IF NOT EXISTS idx_deliveries_supplier
  ON deliveries (supplier_code, store_code);

-- -----------------------------------------------------------------------------
-- supplier_invoices — from Sigma DW220sDB.DBInvD / DBInvK / DBInvP
-- One row per supplier invoice
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS supplier_invoices (
  client_id       UUID NOT NULL,
  store_code      TEXT NOT NULL,
  invoice_number  TEXT NOT NULL,
  supplier_code   TEXT,
  invoice_date    DATE,
  invoice_total   NUMERIC(14,2),
  vat_amount      NUMERIC(12,2),
  status          TEXT,
  delivery_ref    TEXT,
  pushed_at       TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, invoice_number)
);

-- -----------------------------------------------------------------------------
-- Verify — all 3 tables must appear
-- -----------------------------------------------------------------------------
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('stock_snapshots', 'deliveries', 'supplier_invoices')
ORDER BY table_name;
