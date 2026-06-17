-- =============================================================================
-- create_stores.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for stores.
-- The fleet config table (refresh_l2_pipeline now reads stores WHERE is_active,
-- R25). No prior committed CREATE. Rebuilt from LIVE 2026-06-17.
-- IF NOT EXISTS => safe no-op against live. DEPLOY ORDER: after clients (FK).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.stores (
  store_id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  store_name text NOT NULL,
  store_type text,
  location text,
  sigma_server text,
  is_active boolean DEFAULT true,
  lan_ip text,
  secondary_ip text,
  CONSTRAINT stores_client_id_store_code_key UNIQUE (client_id, store_code),
  CONSTRAINT stores_pkey PRIMARY KEY (store_id),
  CONSTRAINT stores_client_id_fkey FOREIGN KEY (client_id) REFERENCES clients(client_id)
);
