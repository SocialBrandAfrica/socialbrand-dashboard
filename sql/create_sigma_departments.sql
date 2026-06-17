-- =============================================================================
-- create_sigma_departments.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_departments.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table, no prior
-- committed CREATE; loaded by the Sigma extractor. id nextval(seq)->bigserial.
-- IF NOT EXISTS => safe no-op against live (reconciles repo to live).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_departments (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  department_nr smallint NOT NULL,
  name text,
  vat_code smallint,
  short_code text,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_departments_client_id_store_code_department_nr_key UNIQUE (client_id, store_code, department_nr),
  CONSTRAINT sigma_departments_pkey PRIMARY KEY (id)
);
