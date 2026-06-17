-- =============================================================================
-- create_sigma_lifecycle.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_lifecycle.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table, no prior
-- committed CREATE; loaded by the Sigma extractor. id nextval(seq)->bigserial.
-- IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_lifecycle (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  product_code bigint NOT NULL,
  soh numeric(14,4),
  standard_stock numeric(14,4),
  running_sales numeric(14,4),
  first_sale_date date,
  last_sale_date date,
  last_receipt_date date,
  last_order_date date,
  last_inv_date date,
  last_inv_soh numeric(14,4),
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_lifecycle_client_id_store_code_product_code_key UNIQUE (client_id, store_code, product_code),
  CONSTRAINT sigma_lifecycle_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_lifecycle_lastsale ON public.sigma_lifecycle USING btree (store_code, last_sale_date);
