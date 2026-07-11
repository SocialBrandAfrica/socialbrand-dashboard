-- create_bloom_supplier_catalogue.sql
-- SB-CC-FORGE-MAP-001 section 3.2/6b: external order catalogues as universal
-- reference (R25 native/derived register). Generalised columns so any direct
-- supplier's own order file (SAB BEES first, Distell/Coca-Cola/Diageo later)
-- loads into ONE table, never one table per supplier. No cost/EAN column --
-- the BEES catalogue export itself does not carry either (verified against
-- the source file); those are evidence-per-GRV facts (sigma_movements
-- cost_value, delivery_note-matched invoices), not a catalogue fact -- do
-- not synthesize what the source doesn't provide (R22).
--
-- Seed: 146 SAB BEES case SKUs from Bloom/SAB-BEES-catalogue_2026-07-10.csv,
-- loaded verbatim (row count reconciled 146=146). See sql/seed_bloom_supplier_catalogue_sab.sql.

CREATE TABLE public.bloom_supplier_catalogue (
  supplier_name text NOT NULL,
  supplier_sku text NOT NULL,
  name text NOT NULL,
  brand text,
  category text,
  package text,
  case_units smallint,
  source_file text,
  loaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (supplier_name, supplier_sku)
);

REVOKE ALL ON public.bloom_supplier_catalogue FROM PUBLIC;
GRANT SELECT ON public.bloom_supplier_catalogue TO anon, authenticated;
ALTER TABLE public.bloom_supplier_catalogue ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bloom_supplier_catalogue_read" ON public.bloom_supplier_catalogue
  FOR SELECT TO anon, authenticated USING (true);
