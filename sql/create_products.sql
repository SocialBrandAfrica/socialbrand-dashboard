-- =============================================================================
-- create_products.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for products.
-- PHASE 1 LEGACY, FROZEN (no new writes -- product_catalog is the authoritative
-- enrichment source). Captured for completeness/reproducibility. No prior committed
-- CREATE. Rebuilt from LIVE 2026-06-17. id nextval->bigserial.
-- IF NOT EXISTS => safe no-op against live. DEPLOY ORDER: after suppliers (FK).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.products (
  id bigserial NOT NULL,
  store_id text NOT NULL,
  ean text NOT NULL,
  product_code text,
  description text,
  size text,
  department text,
  sub_department text,
  supplier_code text,
  list_cost numeric(10,4),
  current_status text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  client_id uuid,
  dept_code text,
  sub_dept_code text,
  plu_code text,
  brand text,
  pack_size text,
  is_active boolean DEFAULT true,
  last_seen_at date,
  CONSTRAINT products_store_id_ean_key UNIQUE (store_id, ean),
  CONSTRAINT products_pkey PRIMARY KEY (id),
  CONSTRAINT products_supplier_code_fkey FOREIGN KEY (supplier_code) REFERENCES suppliers(supplier_code) ON DELETE SET NULL,
  CONSTRAINT products_current_status_check CHECK ((current_status = ANY (ARRAY['Active'::text, 'Inactive'::text, 'Inactive Zero SOH'::text])))
);
