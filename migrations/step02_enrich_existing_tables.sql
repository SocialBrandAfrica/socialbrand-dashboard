-- =============================================================================
-- SB-AP-002 Step 2 — Enrich existing tables with client_id and new columns
-- No existing columns or rows are removed. PRSSALE pipeline is unaffected.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2a. products — add new columns
-- -----------------------------------------------------------------------------
ALTER TABLE products ADD COLUMN IF NOT EXISTS client_id      UUID;
ALTER TABLE products ADD COLUMN IF NOT EXISTS dept_code      TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS sub_dept_code  TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS plu_code       TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS brand          TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS pack_size      TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS is_active      BOOLEAN DEFAULT true;
ALTER TABLE products ADD COLUMN IF NOT EXISTS last_seen_at   DATE;

-- -----------------------------------------------------------------------------
-- 2b. suppliers — add new columns
-- -----------------------------------------------------------------------------
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS client_id         UUID;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS sigma_kund_code   TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS contact_name      TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS contact_email     TEXT;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS is_active         BOOLEAN DEFAULT true;

-- -----------------------------------------------------------------------------
-- 2c. price_history — add new columns
-- -----------------------------------------------------------------------------
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS client_id   UUID;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS plu_code    TEXT;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS sell_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS cost_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS gp_pct      NUMERIC(5,2);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS changed_by  TEXT;

-- -----------------------------------------------------------------------------
-- 2d. daily_snapshots — add client_id only
-- The PRSSALE pipeline continues writing to this table unchanged.
-- -----------------------------------------------------------------------------
ALTER TABLE daily_snapshots ADD COLUMN IF NOT EXISTS client_id UUID;

-- -----------------------------------------------------------------------------
-- 2e. Backfill client_id on all existing rows in all four tables
-- Uses a subquery — no UUID hardcoded in this script.
-- -----------------------------------------------------------------------------
UPDATE products
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

UPDATE suppliers
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

UPDATE price_history
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

UPDATE daily_snapshots
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

-- -----------------------------------------------------------------------------
-- Verify — each table should show one non-null client_id group
-- -----------------------------------------------------------------------------
SELECT 'products'        AS tbl, client_id, COUNT(*) FROM products        GROUP BY client_id
UNION ALL
SELECT 'suppliers'       AS tbl, client_id, COUNT(*) FROM suppliers       GROUP BY client_id
UNION ALL
SELECT 'price_history'   AS tbl, client_id, COUNT(*) FROM price_history   GROUP BY client_id
UNION ALL
SELECT 'daily_snapshots' AS tbl, client_id, COUNT(*) FROM daily_snapshots GROUP BY client_id
ORDER BY tbl;
