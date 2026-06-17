-- =============================================================================
-- create_sigma_sales.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_sales.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. The DBUMBA sales
-- ledger (NORTH_STAR source of truth, period_kind='T' AND txn_kind=1). No prior
-- committed CREATE; loaded by the Sigma extractor. id nextval(seq)->bigserial.
-- IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_sales (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  sale_date date NOT NULL,
  product_code bigint NOT NULL,
  cashier_nr integer,
  period_kind text NOT NULL DEFAULT 'T'::text,
  txn_kind smallint NOT NULL DEFAULT 1,
  sales_incl_vat numeric(14,4),
  vat_value numeric(14,4),
  cost_value numeric(14,4),
  qty numeric(14,4),
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_sales_client_id_store_code_period_kind_sale_date_cash_key UNIQUE (client_id, store_code, period_kind, sale_date, cashier_nr, txn_kind, product_code),
  CONSTRAINT sigma_sales_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_sales_store_date ON public.sigma_sales USING btree (store_code, sale_date);
CREATE INDEX IF NOT EXISTS idx_sigma_sales_store_prod_date ON public.sigma_sales USING btree (store_code, product_code, sale_date DESC);
