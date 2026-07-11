-- create_supplier_calendar.sql
-- SB-CC-BLOOM-007 item 1: supplier_calendar. Named separately from the
-- earlier bloom_delivery_schedule (PARITY-001 item 3, route_key DC/DIRECT/
-- DIRECT_BEER, built for the Replit app's read) because this brief's route
-- keys are format-split (DC_AMBIENT vs DC_TOPS, matching p_route on the
-- recipe RPC and the desk screen) -- a genuinely different grain, not a
-- rename. Small tracked duplication (both hold the same GRV-derived
-- cadence facts at different granularity) -- flagged, not hidden; a
-- consolidation pass is cheap later and not worth the Sunday deadline now.
-- Same underlying verified facts (HANDOVER-CURRENT 2026-07-11 GRV-derived
-- cadence), no new derivation.

CREATE TABLE public.supplier_calendar (
  store_code text NOT NULL,
  route_key text NOT NULL CHECK (route_key IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER')),
  delivery_dows smallint[] NOT NULL, -- ISO weekday, 1=Mon .. 7=Sun
  order_cutoff_days smallint NOT NULL DEFAULT 2, -- BUG-LOG ENG-011: minimum lead between order date and delivery date
  scope text NOT NULL DEFAULT 'DEMO_CALIBRATION',
  effective_from date NOT NULL,
  source_note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, route_key)
);

REVOKE ALL ON public.supplier_calendar FROM PUBLIC;
GRANT SELECT ON public.supplier_calendar TO anon, authenticated;
ALTER TABLE public.supplier_calendar ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_calendar_read" ON public.supplier_calendar
  FOR SELECT TO anon, authenticated USING (true);

INSERT INTO public.supplier_calendar (store_code, route_key, delivery_dows, effective_from, source_note) VALUES
  ('10116', 'DC_AMBIENT', ARRAY[4,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SPAR ambient DC, sigma_movements R/W x sigma_supplier_master type Z'),
  ('80175', 'DC_AMBIENT', ARRAY[3,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SPAR ambient DC, sigma_movements R/W x sigma_supplier_master type Z'),
  ('21355', 'DC_TOPS', ARRAY[1,4], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, sigma_movements R/W x sigma_supplier_master type Z'),
  ('80176', 'DC_TOPS', ARRAY[3,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, sigma_movements R/W x sigma_supplier_master type Z'),
  ('80579', 'DC_TOPS', ARRAY[1,4], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, sigma_movements R/W x sigma_supplier_master type Z'),
  ('21355', 'DIRECT_BEER', ARRAY[5], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SAB beer receipts, name ILIKE SAB'),
  ('80176', 'DIRECT_BEER', ARRAY[2], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SAB beer receipts, name ILIKE SAB');
