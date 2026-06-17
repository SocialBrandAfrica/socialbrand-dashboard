-- =============================================================================
-- create_sigma_trade_terms.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_trade_terms.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection. L1 table (DBKOND trade
-- terms / discounts). No prior committed CREATE; loaded by the Sigma extractor.
-- id nextval(seq)->bigserial. IF NOT EXISTS => safe no-op against live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_trade_terms (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  term_id bigint NOT NULL,
  condition_kind text,
  supplier_nr bigint,
  product_code bigint,
  merch_group_nr integer,
  group_ref smallint,
  description text,
  discount numeric(14,4),
  min_qty numeric(14,4),
  basis text,
  kind text,
  tier smallint,
  valid_from date,
  valid_to date,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT sigma_trade_terms_client_id_store_code_term_id_key UNIQUE (client_id, store_code, term_id),
  CONSTRAINT sigma_trade_terms_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_terms_supplier ON public.sigma_trade_terms USING btree (store_code, supplier_nr);
