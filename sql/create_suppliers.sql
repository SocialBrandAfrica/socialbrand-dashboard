-- =============================================================================
-- create_suppliers.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for suppliers.
-- Supplier master with contact details (referenced by products.supplier_code FK).
-- No prior committed CREATE. Rebuilt from LIVE 2026-06-17.
-- IF NOT EXISTS => safe no-op against live. DEPLOY ORDER: before products (FK target).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.suppliers (
  supplier_code text NOT NULL,
  supplier_name text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  client_id uuid,
  sigma_kund_code text,
  contact_name text,
  contact_email text,
  is_active boolean DEFAULT true,
  CONSTRAINT suppliers_pkey PRIMARY KEY (supplier_code)
);
