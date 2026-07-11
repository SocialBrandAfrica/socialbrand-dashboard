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
  PRIMARY KEY (store_code, product_code)
);
CREATE INDEX idx_product_resolution_family ON public.l2_product_resolution(family_key) WHERE family_key IS NOT NULL;
CREATE INDEX idx_product_resolution_verdict ON public.l2_product_resolution(verdict);

REVOKE ALL ON public.l2_product_resolution FROM PUBLIC;
GRANT SELECT ON public.l2_product_resolution TO authenticated;
ALTER TABLE public.l2_product_resolution ENABLE ROW LEVEL SECURITY;
CREATE POLICY "l2_product_resolution_read" ON public.l2_product_resolution
  FOR SELECT TO authenticated USING (true);
