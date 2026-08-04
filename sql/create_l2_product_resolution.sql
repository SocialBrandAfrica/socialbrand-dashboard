-- create_l2_product_resolution.sql
-- SB-CC-FORGE-MAP-001 section 6b: l2_product_resolution, the per-store
-- nightly L2 pantry fact. One row per (store_code, product_code).
--
-- =====================================================================
-- STATUS 2026-08-04: THE ZERO-ROWS GATE BELOW IS SUPERSEDED AND LIVE.
-- R28 lineage -- retired with a date and a successor, never deleted.
-- =====================================================================
-- The original gate in this file (kept verbatim below) held the table at
-- ZERO ROWS until one of two conditions was met. Its own condition (b) was
-- "PM/Pieter explicitly rules the algorithm may propose verdicts
-- engine-only pending confirmation". BOTH halves of that have now landed:
--   * CANON SS17 THE ITEM-12 CHURN, RULED 2026-07-26 -- the sequencing
--     condition is "the database decides first and the floor is asked only
--     for the residue. Never ask the floor a question the ledger already
--     answers." That INVERTS the original gate: withholding a resolution
--     the database can make deterministically is now the defect.
--   * PM green-light 2026-08-04, bucket B first, after CC published the
--     residue as a number (the ruling's own stated precondition).
-- So this pass fills the table for BUCKET B ONLY -- the rows where canon's
-- own parent-child cross-check agrees and NO judgement is required.
-- Nothing ambiguous is resolved. The floor's 1,154-row residue is NOT
-- written here, and l2_link_codes_queue.status stays CHECK-locked.
--
-- WHAT THIS PASS DELIBERATELY DOES NOT DECIDE (left UNKNOWN, item-12 rule 3
-- "the engine stays free to answer UNKNOWN indefinitely"):
--   is_keeper   -- NULL. The within-level duplicate contest (section 4b
--                  step 2, keeper-by-movement) is a different question.
--   cost_error  -- NULL. This pass runs NO cost test; false would assert
--                  "tested and clean" on 6,772 untested rows.
--   unit_ref / cost_cascade_value / deposit_classification -- NULL, they
--                  belong to the SAB-anchored cost cascade and the deposit
--                  reshape (brief sections 3.8 / 4b step 6), not to bucket B.
--   canonical_ean / ean_status / export_eligible / export_key -- NULL, they
--                  are the Phase-3 consolidation columns; l2_export_key and
--                  l2_ean_resolved remain authoritative today.
--
-- THREE SCHEMA CHANGES were made to this ZERO-ROW, ZERO-CONSUMER scaffold,
-- named because canon SS17 said Phase 3 would need none (true of TABLES):
--   1. pack_multiple added -- the N had nowhere to live, and section 3.1
--      states the rule IS "the family key, its members, the multipliers".
--   2. level CHECK gained 'pack' -- the original vocabulary
--      (single/six/twelve_rb/twentyfour) was written for the SAB beer anchor;
--      the live population carries price-confirmed multiples of 3,4,5,8,10,
--      15,16,20 too, and stamping those 'unknown' is a lie in a column the
--      engine reads. 'twelve_rb' is NOT assigned by this pass -- it asserts a
--      returnable container this pass has no evidence for.
--   3. cost_error NOT NULL dropped -- see above.
--
-- ------------------ ORIGINAL GATE, VERBATIM, SUPERSEDED ---------------
-- SCHEMA ONLY IN THIS PASS -- the refresh function (the family/level/keeper
-- resolution algorithm, section 4b) is NOT built here. Reason, stated
-- plainly: section 4 of the brief is explicit -- "The human confirms, edits
-- or rejects. Nothing is written without a human decision" -- the engine is
-- meant to PROPOSE candidates for confirmation via the Product-Mapper
-- toolkit (section 5), which does not exist yet. This object feeds Capital
-- Tied directly (Tier 1, RULE-BOOK R22) -- auto-deciding ambiguous family/
-- keeper matches without the human-confirmation loop the brief itself
-- mandates would be a canon contradiction, not a shortcut.
-- STATUS 2026-07-26 (Identity Phase 2, PM ruling): the gate above STANDS and
-- was explicitly re-affirmed -- this table stays at ZERO ROWS.
-- ----------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.l2_product_resolution (
  store_code text NOT NULL,
  product_code bigint NOT NULL,
  family_key text,
  level text CHECK (level IN ('single','six','twelve_rb','twentyfour','pack','unknown')),
  pack_multiple numeric, -- singles-per-pack at this level; 1 on a single
  is_keeper boolean,
  verdict text CHECK (verdict IN
    ('KEEP','STANDARDISE_DESCRIPTION','CONVERT_TO_NON_DEPLETE','ZERO_AND_KILL',
     'FIX_COST','RESHAPE_DEPOSIT','RESIDUE_HUMAN')),
  unit_ref numeric,
  cost_cascade_value numeric,
  cost_error boolean, -- NULL = NOT TESTED by the pass that wrote the row
  deposit_classification text,
  capital_impact_rand numeric,
  story text, -- R29, the reason this row got this verdict
  evidence jsonb,
  confidence numeric CHECK (confidence BETWEEN 0 AND 1),
  engine_version text,
  computed_at timestamptz,
  canonical_ean text,
  ean_status text,
  export_eligible boolean,
  export_key text,
  queue_candidate_id uuid,
  PRIMARY KEY (store_code, product_code)
);
CREATE INDEX IF NOT EXISTS idx_product_resolution_family ON public.l2_product_resolution(family_key) WHERE family_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_product_resolution_verdict ON public.l2_product_resolution(verdict);

REVOKE ALL ON public.l2_product_resolution FROM PUBLIC;
GRANT SELECT ON public.l2_product_resolution TO authenticated;
ALTER TABLE public.l2_product_resolution ENABLE ROW LEVEL SECURITY;
-- policy created once; re-running this file is a safe no-op
DO $pol$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                   AND tablename='l2_product_resolution'
                   AND policyname='l2_product_resolution_read') THEN
    CREATE POLICY "l2_product_resolution_read" ON public.l2_product_resolution
      FOR SELECT TO authenticated USING (true);
  END IF;
END $pol$;

-- ================= THE BUCKET-B RESOLVER (live body) =================
-- Emitted from pg_get_functiondef, never hand-transcribed (RECONCILE-001).
-- Wired into refresh_l2_pipeline immediately after refresh_l2_link_codes_queue
-- for the same store -- it reads that queue, so the order is load-bearing.

CREATE OR REPLACE FUNCTION public.refresh_l2_product_resolution(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_engine_version text := 'FORGE-MAP-001 bucketB v1.0';
  v_deleted int; v_inserted int;
  v_res jsonb;
BEGIN
  DELETE FROM l2_product_resolution WHERE store_code = p_store;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  WITH q AS (
    SELECT id, store_code, group_key, evidence,
           (regexp_match(evidence->'pack_side'->>'description', '_([0-9]+)\s*$'))[1]::int AS n,
           (evidence->>'sell_price_ratio')::numeric AS ratio
    FROM l2_link_codes_queue
    WHERE candidate_type = 'PACK_FAMILY' AND store_code = p_store
  ),
  -- BUCKET B ONLY. Canon SS17 item-12 condition 2: the database decides where its own
  -- parent-child cross-check agrees (suffix multiple vs sell-price ratio, within 25%).
  -- Everything else is the floor's question or out of scope and is NOT written here.
  bucket_b AS (
    SELECT * FROM q
    WHERE n IS NOT NULL AND n > 0 AND ratio IS NOT NULL AND abs(ratio / n - 1) <= 0.25
  ),
  slots AS (
    SELECT store_code, id AS qid, group_key, n, ratio,
           (evidence->'pack_side'->>'product_code')::bigint      AS code,
           'pack'::text                                          AS side,
           (evidence->'pack_side'->>'record_stock_qty')::int      AS rsq,
           (evidence->'pack_side'->>'soh')::numeric               AS soh,
           (evidence->'pack_side'->>'description')                AS descr,
           evidence->>'root'                                      AS root
    FROM bucket_b
    UNION ALL
    SELECT store_code, id, group_key, n, ratio,
           (evidence->'single_side'->>'product_code')::bigint,
           'single',
           (evidence->'single_side'->>'record_stock_qty')::int,
           (evidence->'single_side'->>'soh')::numeric,
           (evidence->'single_side'->>'description'),
           evidence->>'root'
    FROM bucket_b
  ),
  -- ONE row per (store, code). A single legitimately anchors several pack siblings, so the
  -- collision is expected; a code landing in two FAMILIES or on two SIDES is not, and that
  -- case is answered RESIDUE_HUMAN rather than guessed (item-12 rule 3: the engine stays
  -- free to answer UNKNOWN indefinitely).
  agg AS (
    SELECT store_code, code,
           min(group_key)                                   AS group_key,
           min(root)                                        AS root,
           count(DISTINCT group_key)                        AS families,
           count(DISTINCT side)                             AS sides,
           min(side)                                        AS side,
           count(DISTINCT n) FILTER (WHERE side = 'pack')   AS multiples,
           min(n) FILTER (WHERE side = 'pack')              AS n,
           min(rsq)                                         AS rsq_min,
           max(rsq)                                         AS rsq_max,
           min(soh)                                         AS soh,
           min(abs(ratio / n - 1))                          AS best_dev,
           count(*)                                         AS slot_count,
           (array_agg(qid ORDER BY qid))[1]                 AS qid
    FROM slots GROUP BY 1, 2
  ),
  shaped AS (
    SELECT a.*,
           (a.families > 1 OR a.sides > 1 OR COALESCE(a.multiples,1) > 1
            OR a.rsq_min IS DISTINCT FROM a.rsq_max
            OR a.rsq_min IS NULL)                                            AS inconsistent,
           -- canon SS14 ADDENDUM v5: zero-deplete on a pack code is METHOD, not a defect.
           (a.side = 'pack'   AND a.rsq_min = 0)                             AS pack_canon_shape,
           (a.side = 'single' AND a.rsq_min = 1)                             AS single_canon_shape,
           (a.side = 'pack'   AND a.rsq_min = 1)                             AS pack_tracks_stock
    FROM agg a
  )
  INSERT INTO l2_product_resolution (
    store_code, product_code, family_key, level, pack_multiple, is_keeper, verdict,
    cost_error, capital_impact_rand, story, evidence, confidence,
    engine_version, computed_at, queue_candidate_id)
  SELECT
    s.store_code,
    s.code,
    s.group_key,
    CASE WHEN s.side = 'single' THEN 'single'
         WHEN s.n = 6  THEN 'six'
         WHEN s.n = 24 THEN 'twentyfour'
         ELSE 'pack' END,
    CASE WHEN s.side = 'single' THEN 1 ELSE s.n END,
    NULL::boolean,   -- is_keeper: the within-level duplicate contest is NOT what bucket B decides.
                     -- Left UNKNOWN rather than asserted (item-12 rule 3).
    CASE WHEN s.inconsistent          THEN 'RESIDUE_HUMAN'
         WHEN s.single_canon_shape    THEN 'KEEP'
         WHEN s.pack_canon_shape      THEN 'KEEP'
         WHEN s.pack_tracks_stock     THEN 'CONVERT_TO_NON_DEPLETE'
         ELSE 'RESIDUE_HUMAN' END,
    NULL::boolean,   -- cost_error: this pass runs NO cost test. NULL = untested, never false.
    CASE WHEN s.pack_tracks_stock THEN COALESCE(sp.capital_value, 0) ELSE NULL END,
    CASE
      WHEN s.inconsistent THEN
        format('Code %s at %s could not be resolved deterministically: it appears in %s families, %s sides, %s multiples. The engine does not guess a family. Falsifier: a single family, side and multiple would resolve it.',
               s.code, s.store_code, s.families, s.sides, COALESCE(s.multiples,0))
      WHEN s.single_canon_shape THEN
        format('Code %s is the stock-bearing single of family "%s". Its pack sibling prices at %sx the single and its description says _%s, agreeing within %s%%, so the database sets this family without asking anyone. Canon method shape holds: single tracks stock. Falsifier: the pack would have to stop tracking to this single.',
               s.code, s.root, round(s.n * (1 + s.best_dev), 2), s.n, round(s.best_dev * 100, 1))
      WHEN s.pack_canon_shape THEN
        format('Code %s is the %s-unit pack of family "%s", non-deplete by method (canon SS14 v5): it rings revenue and depletes into the single. Suffix _%s and a sell-price ratio agreeing within %s%% both say %s, which is why this needs no human. Falsifier: a price ratio moving beyond 25%% of the suffix.',
               s.code, s.n, s.root, s.n, round(s.best_dev * 100, 1), s.n)
      WHEN s.pack_tracks_stock THEN
        format('Code %s is the %s-unit pack of family "%s" but it TRACKS STOCK (record_stock_qty=1) while its single does too. That is the rogue shape canon SS14 v5 names: a pack that should be non-deplete is holding %s units and %s of book capital. RECOMMENDATION ONLY, nothing is changed at source. Falsifier: the floor confirms this code is genuinely the stock-bearing code and the single is not.',
               s.code, s.n, s.root, COALESCE(s.soh,0), to_char(COALESCE(sp.capital_value,0), 'FM999G999G990D00'))
      ELSE format('Code %s at %s did not match any resolved shape and is left for a person.', s.code, s.store_code)
    END,
    jsonb_build_object(
      'root', s.root, 'group_key', s.group_key, 'side', s.side,
      'pack_multiple', s.n, 'price_ratio_deviation', round(s.best_dev, 4),
      'record_stock_qty', s.rsq_min, 'soh', s.soh, 'queue_slots', s.slot_count,
      'bucket', 'B_database_decides', 'rule', 'canon SS17 item-12 condition 2 + SS14 ADDENDUM v5'),
    -- Confidence DISCRIMINATES. Canon SS17 named the flat 0.600 on every row as a constant
    -- wearing a confidence's clothes; this grades on how tightly price agrees with the suffix.
    CASE WHEN s.inconsistent THEN NULL
         WHEN s.best_dev <= 0.05 THEN 0.95
         WHEN s.best_dev <= 0.15 THEN 0.85
         ELSE 0.75 END,
    v_engine_version,
    now(),
    s.qid
  FROM shaped s
  LEFT JOIN l2_stock_position sp
         ON sp.client_id = 'socialbrand'          -- canon SS17: these indexes LEAD with client_id
        AND sp.store_code = s.store_code
        AND sp.product_code = s.code;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  SELECT jsonb_build_object(
    'store_code', p_store, 'engine_version', v_engine_version,
    'deleted', v_deleted, 'inserted', v_inserted,
    'by_verdict', (SELECT jsonb_object_agg(verdict, n) FROM
        (SELECT verdict, count(*) n FROM l2_product_resolution WHERE store_code=p_store GROUP BY 1) t),
    'by_level', (SELECT jsonb_object_agg(level, n) FROM
        (SELECT level, count(*) n FROM l2_product_resolution WHERE store_code=p_store GROUP BY 1) t)
  ) INTO v_res;

  RETURN v_res;
END;
$function$
;

-- R30 addendum extension: BOTH legs of the PUBLIC-grant trap, proven live
-- 2026-08-04 (acl = postgres/authenticated/service_role, anon EXECUTE false).
REVOKE EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) TO authenticated;
