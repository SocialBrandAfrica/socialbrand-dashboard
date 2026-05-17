-- =============================================================================
-- SB-AP-002 Step 6 — Promotion and pricing tables
-- promotions, promotion_lines + enrich price_history
-- =============================================================================

-- -----------------------------------------------------------------------------
-- promotions — from Sigma npos.Promo_hd
-- One row per promotion
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS promotions (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  promo_code     TEXT NOT NULL,
  promo_name     TEXT,
  promo_type     TEXT,
  valid_from     DATE,
  valid_to       DATE,
  is_active      BOOLEAN DEFAULT true,
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, promo_code)
);

-- -----------------------------------------------------------------------------
-- promotion_lines — from Sigma npos.Promo_price
-- One row per product in a promotion
-- Note: Promo_det is the trigger/condition table, not the product list.
-- Phase 1: Promo_hd only. Promo_price sampling deferred to Phase 2.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS promotion_lines (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  promo_code     TEXT NOT NULL,
  ean            TEXT NOT NULL,
  plu_code       TEXT,
  promo_price    NUMERIC(10,4),
  normal_price   NUMERIC(10,4),
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, promo_code, ean)
);

-- -----------------------------------------------------------------------------
-- price_history — enrich existing stub table
-- Adds meaningful columns from Sigma npos.PLU_p
-- -----------------------------------------------------------------------------
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS client_id   UUID;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS plu_code    TEXT;
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS sell_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS cost_price  NUMERIC(10,4);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS gp_pct      NUMERIC(5,2);
ALTER TABLE price_history ADD COLUMN IF NOT EXISTS changed_by  TEXT;

-- -----------------------------------------------------------------------------
-- Verify
-- -----------------------------------------------------------------------------
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('promotions', 'promotion_lines')
ORDER BY table_name;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'price_history'
  AND column_name IN ('client_id', 'plu_code', 'sell_price', 'cost_price', 'gp_pct', 'changed_by')
ORDER BY column_name;
