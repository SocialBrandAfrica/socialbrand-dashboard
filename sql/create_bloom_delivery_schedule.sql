-- create_bloom_delivery_schedule.sql
-- SB-RA-BLOOM-001 section 13: route-config/delivery-days read. Order screens
-- (this app and the Replit app) preload delivery date + next-delivery date
-- from this, never hardcode a weekday. Seeded from HANDOVER-CURRENT's
-- GRV-ledger-derived cadence (2026-07-11, R/W receipts x sigma_supplier_master
-- type Z / SAB name match) -- DEMO_CALIBRATION (R28), store #6 re-derives its
-- own from its own GRV ledger, same method, config key not a hardcode.
-- 80579 carries no DIRECT_BEER row -- it has no SAB receipts of its own
-- (IBT-fed from a sibling store), a named gap not a silent omission (R21 S5).
--
-- RLS: public-schema table, enabled with an open read policy (never rely on
-- table grants alone -- same discipline as community_rhythm's "anon read"
-- policy; the linter flags any public table with RLS disabled regardless of
-- grant intent).

CREATE TABLE public.bloom_delivery_schedule (
  client_id text NOT NULL DEFAULT 'socialbrand',
  store_code text NOT NULL,
  route_key text NOT NULL CHECK (route_key IN ('DC','DIRECT','DIRECT_BEER')),
  weekdays smallint[] NOT NULL, -- ISO weekday, 1=Mon .. 7=Sun
  scope text NOT NULL DEFAULT 'DEMO_CALIBRATION',
  effective_from date NOT NULL,
  source_note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, route_key)
);

REVOKE ALL ON public.bloom_delivery_schedule FROM PUBLIC;
GRANT SELECT ON public.bloom_delivery_schedule TO anon, authenticated;

ALTER TABLE public.bloom_delivery_schedule ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bloom_delivery_schedule_read" ON public.bloom_delivery_schedule
  FOR SELECT TO anon, authenticated USING (true);

INSERT INTO public.bloom_delivery_schedule (store_code, route_key, weekdays, effective_from, source_note) VALUES
  ('10116', 'DC', ARRAY[4,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SPAR ambient DC, derived from sigma_movements R/W receipts x sigma_supplier_master type Z'),
  ('80175', 'DC', ARRAY[3,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SPAR ambient DC, derived from sigma_movements R/W receipts x sigma_supplier_master type Z'),
  ('21355', 'DC', ARRAY[1,4], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, derived from sigma_movements R/W receipts x sigma_supplier_master type Z'),
  ('80176', 'DC', ARRAY[3,6], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, derived from sigma_movements R/W receipts x sigma_supplier_master type Z'),
  ('80579', 'DC', ARRAY[1,4], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: TOPS DC, derived from sigma_movements R/W receipts x sigma_supplier_master type Z'),
  ('21355', 'DIRECT_BEER', ARRAY[5], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SAB beer receipts, name ILIKE SAB'),
  ('80176', 'DIRECT_BEER', ARRAY[2], '2026-07-11', 'HANDOVER-CURRENT 2026-07-11: SAB beer receipts, name ILIKE SAB');
