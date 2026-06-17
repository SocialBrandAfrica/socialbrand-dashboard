-- =============================================================================
-- create_price_history.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for price_history.
-- Legacy products-family table (0 rows live; FK to products). No prior committed
-- CREATE. Rebuilt from LIVE 2026-06-17. id nextval->bigserial.
-- IF NOT EXISTS => safe no-op against live. DEPLOY ORDER: after products (FK).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.price_history (
  id bigserial NOT NULL,
  product_id bigint NOT NULL,
  store_id text NOT NULL,
  ean text NOT NULL,
  old_list_cost numeric(10,4),
  new_list_cost numeric(10,4),
  changed_at timestamp with time zone NOT NULL DEFAULT now(),
  source text,
  client_id uuid,
  plu_code text,
  sell_price numeric(10,4),
  cost_price numeric(10,4),
  gp_pct numeric(5,2),
  changed_by text,
  CONSTRAINT price_history_pkey PRIMARY KEY (id),
  CONSTRAINT price_history_product_id_fkey FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);
