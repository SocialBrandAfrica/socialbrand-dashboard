-- =============================================================================
-- SB-AP-002 Step 8 — Operations and audit tables
-- push_log, push_errors
-- Every push operation is recorded here. Never exit without writing a log row.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- push_log — one row per push operation
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS push_log (
  push_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id       UUID,
  store_code      TEXT NOT NULL,
  push_type       TEXT NOT NULL,
  table_name      TEXT NOT NULL,
  started_at      TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  rows_pushed     INT DEFAULT 0,
  rows_failed     INT DEFAULT 0,
  status          TEXT,
  error_message   TEXT,
  script_version  TEXT
);

CREATE INDEX IF NOT EXISTS idx_push_log_store
  ON push_log (store_code, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_push_log_status
  ON push_log (status, started_at DESC);

-- -----------------------------------------------------------------------------
-- push_errors — one row per failed row during a push
-- Stores the raw data so the row can be retried.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS push_errors (
  error_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  push_id         UUID REFERENCES push_log(push_id),
  store_code      TEXT,
  table_name      TEXT,
  row_data        JSONB,
  error_message   TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Verify
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('push_log', 'push_errors')
ORDER BY table_name;
