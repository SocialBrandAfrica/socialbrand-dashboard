-- =============================================================================
-- create_sigma_articles.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for sigma_articles.
-- Rebuilt from LIVE 2026-06-17 via catalog introspection (Postgres-emitted DDL).
-- This L1 table previously had NO committed CREATE (created by an early extractor
-- run). Loaded by the Sigma extractor (Invoke-ExtractFromSigmaSQL.ps1), not seeded.
-- id normalized nextval(seq)->bigserial (identical on fresh deploy). IF NOT EXISTS
-- => applying to the existing live DB is a safe no-op; this file reconciles repo
-- to live, it does not mutate live.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.sigma_articles (
  id bigserial NOT NULL,
  client_id text NOT NULL DEFAULT 'socialbrand'::text,
  store_code text NOT NULL,
  product_code bigint NOT NULL,
  record_status text,
  description text,
  short_description text,
  vat_code smallint,
  sell_price_incl_vat numeric(14,4),
  net_promo_price numeric(14,4),
  department_nr smallint,
  merch_group_nr integer,
  pack_content text,
  unit text,
  weight numeric(14,4),
  origin_country text,
  article_type text,
  plu_flag text,
  scale_flag text,
  created_date date,
  price_change_date date,
  ingested_at timestamp with time zone NOT NULL DEFAULT now(),
  record_stock_qty smallint,
  CONSTRAINT sigma_articles_client_id_store_code_product_code_key UNIQUE (client_id, store_code, product_code),
  CONSTRAINT sigma_articles_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_sigma_articles_merch ON public.sigma_articles USING btree (store_code, merch_group_nr);
