-- =============================================================================
-- SB-AP-002 Step 2a — DDL only: add new columns to existing tables
-- Fast — no row updates. Safe to re-run (IF NOT EXISTS).
-- =============================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS client_id      UUID;
ALTER TABLE products ADD COLUMN IF NOT EXISTS dept_code      TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS sub_dept_code  TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS plu_code       TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS brand          TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS pack_size      TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS is_active      BOOLEAN DEFAULT true;
ALTER TABLE products ADD COLUMN IF NOT EXISTS last_seen_at   DATE;

ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS client_id         UUID;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS sigma_kund_code   TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS contact_name      TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS contact_email     TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS is_active         BOOLEAN DEFAULT true;

ALTER TABLE price_history ADD COLUMN IF NOT EXISTS client_id   UUID;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS plu_code    TEXT;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS sell_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS cost_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS gp_pct      NUMERIC(5,2);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS changed_by  TEXT;

ALTER TABLE daily_snapshots ADD COLUMN IF NOT EXISTS client_id UUID;

-- Verify columns were added
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('products', 'suppliers', 'price_history', 'daily_snapshots')
  AND column_name = 'client_id'
ORDER BY table_name;
