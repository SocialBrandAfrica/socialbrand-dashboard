-- =============================================================================
-- create_daily_snapshots.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for daily_snapshots.
-- The PRIMARY PRSSALE table (~18M rows) had NO committed CREATE -- only migration
-- fragments (migrate_daily_aggregates_to_snapshots.sql, add_unique_constraint_*).
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. id nextval->bigserial.
-- IF NOT EXISTS => safe no-op against live. Loaded by the nightly PRSSALE push;
-- 16-month rolling retention via purge_old_snapshots(). client_id uuid (legacy layer).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.daily_snapshots (
  id bigserial NOT NULL,
  store_code text NOT NULL,
  store_name text NOT NULL,
  file_date text NOT NULL,
  snapshot_date date,
  ean text NOT NULL,
  description text,
  size text,
  unit text,
  sell_price numeric(10,4),
  vat_pct numeric(5,2),
  today_qty numeric(10,4),
  today_cost numeric(12,4),
  today_sales numeric(12,4),
  period_qty numeric(10,4),
  period_cost numeric(12,4),
  period_sales numeric(12,4),
  soh numeric(10,4),
  dept_code text,
  dept_name text,
  sub_dept_code text,
  sub_dept_name text,
  internal_ref text,
  status text,
  promo text,
  last_sales_date_raw text,
  last_sales_date_iso date,
  unit_cost numeric(10,4),
  is_placeholder boolean NOT NULL DEFAULT false,
  client_id uuid,
  CONSTRAINT daily_snapshots_store_code_file_date_ean_key UNIQUE (store_code, file_date, ean),
  CONSTRAINT daily_snapshots_store_date_ean_key UNIQUE (store_code, snapshot_date, ean),
  CONSTRAINT daily_snapshots_pkey PRIMARY KEY (id)
);
