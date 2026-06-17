-- =============================================================================
-- create_clients.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for clients.
-- Multi-tenant root (referenced by stores.client_id FK). No prior committed
-- CREATE. Rebuilt from LIVE 2026-06-17. IF NOT EXISTS => safe no-op against live.
-- DEPLOY ORDER: create before stores (FK target).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.clients (
  client_id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_name text NOT NULL,
  brand_name text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT clients_pkey PRIMARY KEY (client_id)
);
