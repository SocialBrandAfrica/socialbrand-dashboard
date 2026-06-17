-- =============================================================================
-- create_departments.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for departments.
-- DDL previously lived only inside fresh_start_schema.sql + phase2c_* (sediment).
-- Rebuilt from LIVE 2026-06-17. IF NOT EXISTS => safe no-op against live.
-- DEPLOY ORDER: after clients (FK target).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.departments (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  dept_code text NOT NULL,
  dept_name text,
  CONSTRAINT departments_pkey PRIMARY KEY (client_id, store_code, dept_code),
  CONSTRAINT departments_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(client_id)
);
