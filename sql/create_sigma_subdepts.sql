-- =============================================================================
-- create_sigma_subdepts.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_subdepts.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table (merch groups),
-- no prior committed CREATE; loaded by the Sigma extractor. id nextval->bigserial.
-- IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_subdepts (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  merch_group_nr integer NOT NULL,
  name text,
  parent_department_nr smallint,
  vat_code smallint,
  short_code text,
  min_margin_pct numeric(9,4),
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_subdepts_client_id_store_code_merch_group_nr_key UNIQUE (client_id, store_code, merch_group_nr),
  CONSTRAINT sigma_subdepts_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_subdepts_parent ON public.sigma_subdepts USING btree (store_code, parent_department_nr);
