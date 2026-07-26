-- create_l2_product_map.sql
-- SB-CC-FORGE-MAP-001 section 6: the generalised store intelligence layer.
-- One row per human-confirmed (or engine-auto high-confidence) resolution.
-- Subsumes and generalises the planned l2_link_codes_queue (canon SS8.12),
-- which becomes the 'family' map_type. Writes ONLY through
-- rpc_forge_map_upsert / rpc_forge_map_retire (NOT YET BUILT -- the
-- Product-Mapper toolkit doesn't exist yet either; this table is schema
-- ready for that build, holds zero rows until it lands).
--
-- ⭐ IDENTITY PHASE 2 STATUS (2026-07-26, PM ruling -- CC).
-- STILL DELIBERATELY EMPTY (0 rows), and that is now a RULING, not just a
-- pending build. Two binding reasons:
--   1. The rpc_forge_map_upsert / _retire write path is still not built, and
--      R30 addendum 2 forbids any other write path (no direct INSERT grant).
--   2. What a resolution MEANS is the HELD item-12 candidate. Pieter's
--      principle governs: the engine may act on a family/successor resolution
--      only when the DATABASE decides it deterministically, and resolving it by
--      letting a normal user amend the database is NOT ALLOWED. PM churns the
--      mechanism before anything is written here.
-- confirmed_by / confirmed_at stay NULL until a human actually rules -- they are
-- a provenance stamp, never an approval the engine fills in for itself.
--
-- The DETERMINISTIC half of identity is live and does not need this table:
-- l2_ean_resolved answers "which barcode is this product's canonical key" and
-- v_ean_bridge is now a thin view over it. The candidates that WOULD be resolved
-- here sit in l2_link_codes_queue, status CHECK-locked to CANDIDATE (6,698 rows).
--
-- The "subsumes l2_link_codes_queue" plan above is DEFERRED, deliberately: canon
-- SS17 and the ENG-020 leg-2 gate name l2_link_codes_queue by name and need it
-- non-empty NOW, whereas this table cannot be written to until its RPC lands.
-- Fold the queue in here when rpc_forge_map_* is built, with lineage (R28).

CREATE TABLE public.l2_product_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_code text NOT NULL,
  map_type text NOT NULL CHECK (map_type IN
    ('family','order_receive_code','classification','route','identity','state')),
  subject_key text NOT NULL, -- product_code or family_key
  resolution jsonb NOT NULL, -- shaped per map_type, section 3.1-3.6
  evidence jsonb, -- the signals shown to the human at confirm time (R29)
  confirmed_by uuid REFERENCES auth.users(id),
  confirmed_at timestamptz,
  source text NOT NULL DEFAULT 'human' CHECK (source IN ('human','engine_auto')),
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  superseded_by uuid REFERENCES public.l2_product_map(id),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_product_map_store_type ON public.l2_product_map(store_code, map_type) WHERE status = 'active';
CREATE INDEX idx_product_map_subject ON public.l2_product_map(subject_key) WHERE status = 'active';

REVOKE ALL ON public.l2_product_map FROM PUBLIC;
GRANT SELECT ON public.l2_product_map TO authenticated;
ALTER TABLE public.l2_product_map ENABLE ROW LEVEL SECURITY;
CREATE POLICY "l2_product_map_read" ON public.l2_product_map
  FOR SELECT TO authenticated USING (true);
