-- =============================================================================
-- create_sigma_supplier_link.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_supplier_link.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table (article<->
-- supplier, pack_size, list_cost). No prior committed CREATE; loaded by the Sigma
-- extractor. id nextval(seq)->bigserial. IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_supplier_link (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  supplier_nr bigint NOT NULL,
  product_code bigint NOT NULL,
  pack_size smallint NOT NULL DEFAULT 0,
  list_cost numeric(14,4),
  status text,
  supplier_article_nr text,
  origin_code text,
  ean bigint,
  ean_type text,
  cost_date date,
  valid_from date,
  valid_to date,
  last_change_date date,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_supplier_link_client_id_store_code_supplier_nr_produc_key UNIQUE (client_id, store_code, supplier_nr, product_code, pack_size),
  CONSTRAINT sigma_supplier_link_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_supplink_prod ON public.sigma_supplier_link USING btree (store_code, product_code);
