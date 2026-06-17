-- =============================================================================
-- create_sigma_movements.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_movements.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. The movement-ledger
-- spine (CLEANUP-ENGINE-CANON 1). No prior committed CREATE; loaded by the Sigma
-- extractor. id nextval(seq)->bigserial. IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_movements (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  movement_id bigint NOT NULL,
  product_code bigint NOT NULL,
  movement_type text,
  movement_process text,
  movement_date date,
  movement_time time without time zone,
  qty numeric(14,4),
  new_soh numeric(14,4),
  module text,
  user_name text,
  order_nr bigint,
  grv_nr bigint,
  supplier_nr bigint,
  retail_value numeric(14,4),
  cost_value numeric(14,4),
  article_text text,
  supplier_text text,
  delivery_note text,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_movements_client_id_store_code_movement_id_key UNIQUE (client_id, store_code, movement_id),
  CONSTRAINT sigma_movements_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_moves_store_prod_date ON public.sigma_movements USING btree (store_code, product_code, movement_date DESC);
CREATE INDEX IF NOT EXISTS idx_sigma_moves_type ON public.sigma_movements USING btree (store_code, movement_type, movement_process, movement_date);
