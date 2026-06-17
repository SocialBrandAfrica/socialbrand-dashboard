-- =============================================================================
-- create_sigma_ean_master.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_ean_master.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table, no prior
-- committed CREATE (barcode column was later altered bigint->text by
-- migrate_sigma_ean_master_barcode_to_text.sql -- reflected here as text).
-- NOTE: derivative cross-check only since R25 (v_item_ean v2 reads sigma_scan_refs).
-- Loaded by the Sigma extractor. id nextval(seq)->bigserial. IF NOT EXISTS no-op vs live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_ean_master (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  barcode text NOT NULL,
  product_code bigint NOT NULL,
  ean_system text,
  ean_type text,
  check_digit smallint,
  orderable boolean,
  sorter integer,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_ean_master_client_id_store_code_barcode_product_code_key UNIQUE (client_id, store_code, barcode, product_code),
  CONSTRAINT sigma_ean_master_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_ean_prod ON public.sigma_ean_master USING btree (store_code, product_code);
