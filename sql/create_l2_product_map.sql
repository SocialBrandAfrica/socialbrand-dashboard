-- create_l2_product_map.sql
-- SB-CC-FORGE-MAP-001 section 6: the generalised store intelligence layer.
-- One row per human-confirmed (or engine-auto high-confidence) resolution.
-- Subsumes and generalises the planned l2_link_codes_queue (canon SS8.12),
-- which becomes the 'family' map_type. Writes ONLY through
-- rpc_forge_map_upsert / rpc_forge_map_retire (NOT YET BUILT -- the
-- Product-Mapper toolkit doesn't exist yet either; this table is schema
-- ready for that build, holds zero rows until it lands).

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
