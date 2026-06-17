-- =============================================================================
-- create_sigma_order_lines.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_order_lines.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table, no prior
-- committed CREATE; loaded by the Sigma extractor. id nextval(seq)->bigserial.
-- IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_order_lines (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  order_nr bigint NOT NULL,
  line_seq integer NOT NULL,
  product_code bigint NOT NULL,
  pack_size smallint NOT NULL DEFAULT 0,
  supplier_nr bigint,
  line_status text,
  description text,
  vat_code smallint,
  ordered_qty numeric(14,4),
  received_qty numeric(14,4),
  sell_price numeric(14,4),
  cost numeric(14,4),
  invoiced_cost numeric(14,4),
  invoiced_qty numeric(14,4),
  invoiced_line_total numeric(14,4),
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_order_lines_client_id_store_code_order_nr_line_seq_pr_key UNIQUE (client_id, store_code, order_nr, line_seq, product_code, pack_size),
  CONSTRAINT sigma_order_lines_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_orderlines_order ON public.sigma_order_lines USING btree (store_code, order_nr);
CREATE INDEX IF NOT EXISTS idx_sigma_orderlines_prod ON public.sigma_order_lines USING btree (store_code, product_code);
