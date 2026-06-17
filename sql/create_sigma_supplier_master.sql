-- =============================================================================
-- create_sigma_supplier_master.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_supplier_master.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table (supplier
-- master incl. type/group/terms). No prior committed CREATE; loaded by the Sigma
-- extractor. id nextval(seq)->bigserial. IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_supplier_master (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  supplier_nr bigint NOT NULL,
  supplier_type text,
  supplier_group integer,
  name text,
  short_name text,
  short_name_2 text,
  status text,
  bbn text,
  gln bigint,
  creditor_nr text,
  order_contact_name text,
  order_city text,
  order_phone text,
  remit_name text,
  email text,
  settle_disc_1_pct numeric(9,4),
  settle_disc_1_days smallint,
  settle_disc_2_pct numeric(9,4),
  settle_disc_2_days smallint,
  terms_nr smallint,
  order_method integer,
  valid_from date,
  valid_to date,
  created_date date,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_supplier_master_client_id_store_code_supplier_nr_key UNIQUE (client_id, store_code, supplier_nr),
  CONSTRAINT sigma_supplier_master_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_supplier_type ON public.sigma_supplier_master USING btree (store_code, supplier_type, supplier_group);
