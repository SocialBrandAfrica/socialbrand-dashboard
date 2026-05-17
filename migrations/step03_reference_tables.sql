-- =============================================================================
-- SB-AP-002 Step 3 — Reference tables
-- departments, sub_departments, supplier_terms, employees
-- All new tables. Will be populated by the first push from the store server.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- departments — from Sigma npos.Dgrp_d
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS departments (
  dept_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL,
  store_code    TEXT NOT NULL,
  dept_code     TEXT NOT NULL,
  dept_name     TEXT NOT NULL,
  UNIQUE(client_id, store_code, dept_code)
);

-- -----------------------------------------------------------------------------
-- sub_departments — from Sigma npos.Wgr_d
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sub_departments (
  sub_dept_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID NOT NULL,
  store_code    TEXT NOT NULL,
  sub_dept_code TEXT NOT NULL,
  sub_dept_name TEXT NOT NULL,
  dept_code     TEXT,
  UNIQUE(client_id, store_code, sub_dept_code)
);

-- -----------------------------------------------------------------------------
-- supplier_terms — from Sigma DW220sDB.DBKOND
-- Phase 1: raw staging approach (see F9 in SIGMA_COLUMN_MAPPING.md)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS supplier_terms (
  term_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id            UUID NOT NULL,
  store_code           TEXT NOT NULL,
  supplier_code        TEXT NOT NULL,
  settlement_days      INT,
  settlement_discount  NUMERIC(5,2),
  buying_discount      NUMERIC(5,2),
  rebate_pct           NUMERIC(5,2),
  valid_from           DATE,
  valid_to             DATE,
  UNIQUE(client_id, store_code, supplier_code, valid_from)
);

-- -----------------------------------------------------------------------------
-- employees — from Sigma npos.Empl_d
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS employees (
  client_id      UUID NOT NULL,
  store_code     TEXT NOT NULL,
  empl_code      TEXT NOT NULL,
  empl_name      TEXT,
  role_code      TEXT,
  is_active      BOOLEAN DEFAULT true,
  pushed_at      TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, store_code, empl_code)
);

-- -----------------------------------------------------------------------------
-- Verify — all 4 tables must appear
-- -----------------------------------------------------------------------------
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('departments', 'sub_departments', 'supplier_terms', 'employees')
ORDER BY table_name;
