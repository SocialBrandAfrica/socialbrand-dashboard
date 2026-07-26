-- create_l2_product_resolution.sql
-- SB-CC-FORGE-MAP-001 section 6b: l2_product_resolution, the per-store
-- nightly L2 pantry fact. One row per (store_code, product_code).
--
-- SCHEMA ONLY IN THIS PASS -- the refresh function (the family/level/keeper
-- resolution algorithm, section 4b) is NOT built here. Reason, stated
-- plainly: section 4 of the brief is explicit -- "The human confirms, edits
-- or rejects. Nothing is written without a human decision" -- the engine is
-- meant to PROPOSE candidates for confirmation via the Product-Mapper
-- toolkit (section 5), which does not exist yet. This object feeds Capital
-- Tied directly (Tier 1, RULE-BOOK R22) -- auto-deciding ambiguous family/
-- keeper matches without the human-confirmation loop the brief itself
-- mandates would be a canon contradiction, not a shortcut. Table is ready
-- for `refresh_l2_product_resolution()` to fill once either (a) the
-- Product-Mapper toolkit lands, or (b) PM/Pieter explicitly rules the
-- algorithm may propose verdicts engine-only pending confirmation.
--
-- ⭐ STATUS 2026-07-26 (Identity Phase 2, PM ruling): the gate above STANDS and
-- was explicitly re-affirmed -- this table stays at ZERO ROWS. family_key /
-- is_keeper / verdict encode the family-keeper-successor decision, which IS the
-- held item-12 candidate (PM churns the mechanism before anything builds on it).
--
-- What DID land instead, deterministically and item-12-independently:
--   * l2_ean_resolved -- which barcode is a product's canonical key, native-first
--     (LIVE, 278,198 rows x5). The half of identity that needs no judgement.
--   * v_ean_bridge repointed to a thin view over it, retiring the R25 SS2 break.
--   * l2_link_codes_queue -- the family / successor / absent-identity CANDIDATES
--     this table would one day resolve, status CHECK-locked to CANDIDATE
--     (6,698 rows). The queue proposes; nothing resolves.
-- So the deterministic identity went live WITHOUT pre-empting the ruling, which
-- is exactly the boundary this file's original gate was written to protect.

CREATE TABLE public.l2_product_resolution (
  store_code text NOT NULL,
  product_code bigint NOT NULL,
  family_key text,
  level text CHECK (level IN ('single','six','twelve_rb','twentyfour','unknown')),
  is_keeper boolean,
  verdict text CHECK (verdict IN
    ('KEEP','STANDARDISE_DESCRIPTION','CONVERT_TO_NON_DEPLETE','ZERO_AND_KILL',
     'FIX_COST','RESHAPE_DEPOSIT','RESIDUE_HUMAN')),
  unit_ref numeric, -- SAB case cost / case units (section 4b step 1)
  cost_cascade_value numeric, -- the family's single-equivalent unit cost derived from the keeper
  cost_error boolean NOT NULL DEFAULT false,
  deposit_classification text, -- e.g. CRATE_CHARGE / BOTTLE_RETURN / NULL if not deposit-related
  capital_impact_rand numeric, -- the rand a ZERO_AND_KILL/FIX_COST verdict would free or correct
  story text, -- R29, the reason this row got this verdict
  evidence jsonb,
  confidence numeric CHECK (confidence BETWEEN 0 AND 1),
  engine_version text,
  computed_at timestamptz,
  -- ⭐ IDENTITY PHASE 2 SCAFFOLD (2026-07-26, PM ruling: "scaffold the columns +
  -- the export/gate flag but write zero resolution rows"). CANON SS17 places
  -- identity AND export-eligibility as ONE pantry fact per (store, product);
  -- these columns are that shape pre-cut, so Phase 3 can consolidate with NO
  -- schema change. All NULL until then.
  canonical_ean text,        -- from l2_ean_resolved (deterministic, already live)
  ean_status text,           -- REAL | PLU | IN_STORE | UNRESOLVED
  export_eligible boolean,   -- the gate flag; authoritative source TODAY is l2_export_key
  export_key text,
  queue_candidate_id uuid,   -- the l2_link_codes_queue candidate this row would answer
  PRIMARY KEY (store_code, product_code)
);
CREATE INDEX idx_product_resolution_family ON public.l2_product_resolution(family_key) WHERE family_key IS NOT NULL;
CREATE INDEX idx_product_resolution_verdict ON public.l2_product_resolution(verdict);

REVOKE ALL ON public.l2_product_resolution FROM PUBLIC;
GRANT SELECT ON public.l2_product_resolution TO authenticated;
ALTER TABLE public.l2_product_resolution ENABLE ROW LEVEL SECURITY;
CREATE POLICY "l2_product_resolution_read" ON public.l2_product_resolution
  FOR SELECT TO authenticated USING (true);
