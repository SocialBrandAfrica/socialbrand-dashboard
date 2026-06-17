-- =============================================================================
-- create_sigma_orders.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_orders.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table, no prior
-- committed CREATE; loaded by the Sigma extractor. id nextval(seq)->bigserial.
-- IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_orders (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  order_nr bigint NOT NULL,
  supplier_nr bigint,
  order_type text,
  status_1 text,
  status_2 text,
  order_date date,
  expected_grv_date date,
  grv_date date,
  invoice_date date,
  due_date date,
  grv_nr bigint,
  invoice_nr text,
  order_retail_total numeric(14,4),
  order_cost_total numeric(14,4),
  invoice_value numeric(14,4),
  credit_value numeric(14,4),
  vat_total numeric(14,4),
  line_count smallint,
  carrier text,
  ext_doc_nr text,
  central_order_nr text,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_orders_client_id_store_code_order_nr_key UNIQUE (client_id, store_code, order_nr),
  CONSTRAINT sigma_orders_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_orders_grvdate ON public.sigma_orders USING btree (store_code, grv_date);
CREATE INDEX IF NOT EXISTS idx_sigma_orders_supplier ON public.sigma_orders USING btree (store_code, supplier_nr);
