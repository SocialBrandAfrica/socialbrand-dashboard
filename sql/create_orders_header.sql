-- create_orders_header.sql
-- SB-CC-BLOOM-004/PARITY-001 item 3: orders redesigned as a header (was an
-- unused Phase-1 per-line shell -- 0 rows, no view/matview dependents,
-- confirmed via pg_depend + repo grep before this DROP). order_items is the
-- new child table. Writes enter ONLY via rpc_bloom_submit_order /
-- rpc_bloom_order_status (SECURITY DEFINER) -- R30 addendum 2, no direct
-- INSERT/UPDATE grant to authenticated. store_code kept as plain text, no FK
-- to stores (matches the existing convention -- no other engine table FKs
-- stores.store_code, it's a composite-unique key there, not a simple one).
--
-- Supabase project default privileges auto-grant SELECT on new tables to
-- anon independent of any REVOKE ... FROM PUBLIC (the same class of trap as
-- the RPC anon-execute trap, RULE-BOOK R30 addendum) -- explicit
-- REVOKE ... FROM anon is required below, not optional.

DROP TABLE IF EXISTS public.orders CASCADE;

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL DEFAULT 'socialbrand',
  store_code text NOT NULL,
  route_key text NOT NULL CHECK (route_key IN ('DC','DIRECT','DIRECT_BEER')),
  source text NOT NULL DEFAULT 'dc' CHECK (source IN ('dc','desk','recipe')),
  preset text,
  delivery_date date NOT NULL,
  next_delivery_date date,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','confirmed','exported','delivered','cancelled')),
  total_value numeric NOT NULL DEFAULT 0,
  line_count integer NOT NULL DEFAULT 0,
  submitted_by uuid NOT NULL REFERENCES auth.users(id),
  confirmed_by uuid REFERENCES auth.users(id),
  confirmed_at timestamptz,
  cancelled_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_store_date ON public.orders(store_code, delivery_date);
CREATE INDEX idx_orders_status ON public.orders(status);

CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_code bigint NOT NULL,
  ean text,
  description text,
  pack_size smallint,
  pack_cost numeric,
  qty_packs integer NOT NULL CHECK (qty_packs >= 0),
  line_value numeric NOT NULL DEFAULT 0,
  kvi_band text,
  mode text,
  tier text,
  story text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_order_items_order_product ON public.order_items(order_id, product_code);
CREATE INDEX idx_order_items_order ON public.order_items(order_id);

REVOKE ALL ON public.orders FROM PUBLIC;
REVOKE ALL ON public.order_items FROM PUBLIC;
GRANT SELECT ON public.orders TO authenticated;
GRANT SELECT ON public.order_items TO authenticated;
REVOKE SELECT ON public.orders FROM anon;
REVOKE SELECT ON public.order_items FROM anon;

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "orders_select_by_role" ON public.orders FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = auth.uid()
      AND (up.role IN ('admin','town_manager') OR up.store_code = orders.store_code)
  )
);

CREATE POLICY "order_items_select_by_role" ON public.order_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.user_profiles up ON up.id = auth.uid()
    WHERE o.id = order_items.order_id
      AND (up.role IN ('admin','town_manager') OR up.store_code = o.store_code)
  )
);
