-- =============================================================================
-- create_sub_departments.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sub_departments.
-- DDL previously lived only inside fresh_start_schema.sql + phase2c_* (sediment).
-- Rebuilt from LIVE 2026-06-17. IF NOT EXISTS => safe no-op against live.
-- DEPLOY ORDER: after clients (FK target).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sub_departments (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  sub_dept_code text NOT NULL,
  sub_dept_name text,
  dept_code text,
  CONSTRAINT sub_departments_pkey PRIMARY KEY (client_id, store_code, sub_dept_code),
  CONSTRAINT sub_departments_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(client_id)
);
