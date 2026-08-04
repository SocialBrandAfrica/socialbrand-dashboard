-- create_l2_product_resolution.sql
-- SB-CC-FORGE-MAP-001 section 6b: l2_product_resolution, the per-store nightly L2 pantry fact.
-- One row per (store_code, product_code). Emitted from pg_get_functiondef, never hand-keyed.
--
-- ==============================================================================
-- STATUS 2026-08-04: LIVE, 9,812 ROWS. The original ZERO-ROWS gate is SUPERSEDED
-- (R28 -- retired with a date and a successor, kept verbatim at the foot of this header).
-- ==============================================================================
-- Canon SS17's item-12 churn (ruled 2026-07-26) INVERTED the old gate: "the database
-- decides first and the floor is asked only for the residue. Never ask the floor a question
-- the ledger already answers." Withholding a deterministic resolution became the defect.
-- PM green-lit the build 2026-08-04 after the residue was published as a number.
--
-- THE WHOLE QUEUE IS NOW RESOLVED TO A BAND, not just the deterministic slice:
--   B_DB_DECIDES              the database rules alone, nobody is asked
--   C_RANK_LAST               a real question, but nothing live moves on it
--   D_ASK_FIRST               the floor's question, worst-first by capital
--   A_OUT_OF_SCOPE_correct..  weighed lines: correct by canon SS11, NOT a question
--   A_HELD_not_askable        no numeric suffix -- canon says these need the mid-string
--                             matcher BEFORE they are queued at all, so they are held
--
-- TWO CONTRACTS A CONSUMER MUST HONOUR:
--   evidence->>'askable'   false means canon forbids putting this to a person yet.
--                            An ask-list filters askable = true. Nothing else.
--   evidence->>'question'  the EXACT words to put to the floor, stored not composed.
--                            Canon SS17 constraint 1 bans a question whose answer IS the
--                            resolution ("are these the same product"). Storing the text
--                            rather than letting a UI paraphrase is what keeps that out.
--                            Three forms only, all physically observable and falsifiable.
--
-- WHAT THIS PASS REFUSES TO ASSERT (item-12 rule 3: the engine stays free to answer
-- UNKNOWN indefinitely, and an honest unknown beats a confident wrong):
--   is_keeper   NULL everywhere EXCEPT the SHARED_EAN successor, the one case the
--               database genuinely decides it (8 rows).
--   cost_error  NULL = NOT TESTED. This pass runs no cost test; false would assert
--               "tested and clean" on 9,812 untested rows.
--   unit_ref / cost_cascade_value / deposit_classification / canonical_ean / ean_status /
--   export_eligible / export_key -- NULL; they belong to the SAB cost cascade, the deposit
--   reshape and the Phase-3 consolidation. l2_export_key and l2_ean_resolved stay
--   authoritative today.
--
-- THREE SCHEMA CHANGES to what was a zero-row, zero-consumer scaffold, named because canon
-- said Phase 3 would need none (true of TABLES, not of columns):
--   1. pack_multiple added -- the N had nowhere to live and section 3.1 states the rule IS
--      "the family key, its members, the multipliers".
--   2. level CHECK gained 'pack' -- the original single/six/twelve_rb/twentyfour vocabulary
--      was written for the SAB beer anchor; the live population carries price-confirmed
--      multiples of 3,4,5,8,10,15,16,20 and stamping those 'unknown' is a lie in a column
--      the engine reads. 'twelve_rb' is never assigned here -- it asserts a returnable
--      container this pass cannot evidence.
--   3. cost_error NOT NULL dropped -- so NULL can mean UNTESTED.
--
-- ------------------ ORIGINAL GATE, VERBATIM, SUPERSEDED ----------------------
-- SCHEMA ONLY IN THIS PASS -- the refresh function is NOT built here ... the engine is
-- meant to PROPOSE candidates for confirmation via the Product-Mapper toolkit, which does
-- not exist yet ... auto-deciding ambiguous family/keeper matches without the
-- human-confirmation loop the brief itself mandates would be a canon contradiction.
-- STATUS 2026-07-26 (Identity Phase 2, PM ruling): the gate above STANDS -- zero rows.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.l2_product_resolution (
  store_code text NOT NULL,
  product_code bigint NOT NULL,
  family_key text,
  level text CHECK (level IN ('single','six','twelve_rb','twentyfour','pack','unknown')),
  pack_multiple numeric,
  is_keeper boolean,
  verdict text CHECK (verdict IN
    ('KEEP','STANDARDISE_DESCRIPTION','CONVERT_TO_NON_DEPLETE','ZERO_AND_KILL',
     'FIX_COST','RESHAPE_DEPOSIT','RESIDUE_HUMAN')),
  unit_ref numeric,
  cost_cascade_value numeric,
  cost_error boolean, -- NULL = NOT TESTED
  deposit_classification text,
  capital_impact_rand numeric, -- the worst-first ranking measure
  story text, -- R29
  evidence jsonb, -- carries rank_band, askable, question, candidate_types
  confidence numeric CHECK (confidence BETWEEN 0 AND 1),
  engine_version text,
  computed_at timestamptz,
  canonical_ean text, ean_status text, export_eligible boolean, export_key text,
  queue_candidate_id uuid,
  PRIMARY KEY (store_code, product_code)
);
CREATE INDEX IF NOT EXISTS idx_product_resolution_family ON public.l2_product_resolution(family_key) WHERE family_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_product_resolution_verdict ON public.l2_product_resolution(verdict);
REVOKE ALL ON public.l2_product_resolution FROM PUBLIC;
GRANT SELECT ON public.l2_product_resolution TO authenticated;
ALTER TABLE public.l2_product_resolution ENABLE ROW LEVEL SECURITY;
DO $pol$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
      AND tablename='l2_product_resolution' AND policyname='l2_product_resolution_read') THEN
    CREATE POLICY "l2_product_resolution_read" ON public.l2_product_resolution
      FOR SELECT TO authenticated USING (true);
  END IF;
END $pol$;

-- Wired into refresh_l2_pipeline immediately after that store's refresh_l2_link_codes_queue.

CREATE OR REPLACE FUNCTION public.refresh_l2_product_resolution(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_engine_version text := 'FORGE-MAP-001 all-buckets v3.0';
  v_deleted int; v_inserted int; v_res jsonb;
BEGIN
  DELETE FROM l2_product_resolution WHERE store_code = p_store;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  WITH pf AS (
    SELECT id, store_code, group_key, evidence, evidence->>'root' AS root,
           (regexp_match(evidence->'pack_side'->>'description','_([0-9]+)\s*$'))[1]::int AS n,
           (evidence->>'sell_price_ratio')::numeric AS ratio
    FROM l2_link_codes_queue WHERE candidate_type='PACK_FAMILY' AND store_code=p_store),
  pf_band AS (SELECT *, CASE WHEN n IS NULL THEN 'A_NOT_ASKABLE_no_numeric_suffix'
                             WHEN ratio IS NULL THEN 'A_NOT_ASKABLE_no_price_ratio'
                             WHEN abs(ratio/n-1)<=0.25 THEN 'B_DB_DECIDES'
                             ELSE 'D_ASK_FIRST' END AS band FROM pf),
  pf_slots AS (
    SELECT store_code, id AS qid, 'PACK_FAMILY'::text AS ctype, group_key AS fam, root, n, ratio,
           (evidence->'pack_side'->>'product_code')::bigint AS code, 'pack'::text AS side,
           (evidence->'pack_side'->>'record_stock_qty')::int AS rsq,
           (evidence->'pack_side'->>'soh')::numeric AS soh, NULL::boolean AS sells, band FROM pf_band
    UNION ALL
    SELECT store_code, id, 'PACK_FAMILY', group_key, root, n, ratio,
           (evidence->'single_side'->>'product_code')::bigint, 'single',
           (evidence->'single_side'->>'record_stock_qty')::int,
           (evidence->'single_side'->>'soh')::numeric, NULL, band FROM pf_band),
  se AS (
    SELECT id, store_code, group_key, subject_product_code AS subj, related_product_code AS rel,
           (evidence->'subject'->>'last_sale_date') IS NOT NULL AS subj_sells,
           (evidence->'related'->>'last_sale_date') IS NOT NULL AS rel_sells,
           evidence->>'shared_ean' AS shared_ean
    FROM l2_link_codes_queue WHERE candidate_type='SHARED_EAN' AND store_code=p_store),
  se_band AS (SELECT *, CASE WHEN NOT subj_sells AND NOT rel_sells THEN 'C_RANK_LAST'
                             WHEN subj_sells <> rel_sells THEN 'B_DB_DECIDES'
                             ELSE 'D_ASK_FIRST' END AS band FROM se),
  se_slots AS (
    SELECT store_code, id AS qid, 'SHARED_EAN'::text, group_key, shared_ean, NULL::int, NULL::numeric,
           subj, NULL::text, NULL::int, NULL::numeric, subj_sells, band FROM se_band
    UNION ALL
    SELECT store_code, id, 'SHARED_EAN', group_key, shared_ean, NULL, NULL,
           rel, NULL, NULL, NULL, rel_sells, band FROM se_band),
  ab_slots AS (
    SELECT store_code, id, 'ABSENT_FROM_DBREFE'::text, NULL::text, evidence->>'description',
           NULL::int, NULL::numeric, subject_product_code, NULL::text, NULL::int,
           (evidence->>'soh')::numeric, NULL::boolean,
           CASE WHEN evidence->>'pack_content' ~* '^(P/KG|KG|[0-9.]+KG)$' THEN 'A_OUT_OF_SCOPE_weighed_s11'
                WHEN (evidence->>'last_sale_date') IS NULL THEN 'C_RANK_LAST'
                WHEN (evidence->>'pack_content') IS NULL THEN 'C_RANK_LAST'
                ELSE 'D_ASK_FIRST' END
    FROM l2_link_codes_queue WHERE candidate_type='ABSENT_FROM_DBREFE' AND store_code=p_store),
  slots AS (SELECT * FROM pf_slots UNION ALL SELECT * FROM se_slots UNION ALL SELECT * FROM ab_slots),
  agg AS (
    SELECT store_code, code, count(DISTINCT ctype) AS n_types, array_agg(DISTINCT ctype) AS ctypes,
      array_agg(DISTINCT band) AS bands,
      CASE WHEN bool_or(band='D_ASK_FIRST') THEN 'D_ASK_FIRST'
           WHEN bool_or(band='C_RANK_LAST') THEN 'C_RANK_LAST'
           WHEN bool_or(band LIKE 'A[_]%')   THEN 'A_HELD'
           ELSE 'B_DB_DECIDES' END AS band,
      bool_or(band='A_OUT_OF_SCOPE_weighed_s11') AS is_weighed,
      bool_or(band LIKE 'A_NOT_ASKABLE%')        AS not_askable,
      bool_or(sells) FILTER (WHERE ctype='SHARED_EAN') AS se_sells,
      min(fam) AS fam, min(root) AS root,
      count(DISTINCT fam) FILTER (WHERE fam IS NOT NULL) AS families,
      count(DISTINCT side) FILTER (WHERE side IS NOT NULL) AS sides, min(side) AS side,
      count(DISTINCT n) FILTER (WHERE side='pack') AS multiples, min(n) FILTER (WHERE side='pack') AS n,
      min(rsq) AS rsq_min, max(rsq) AS rsq_max, min(soh) AS soh,
      min(abs(ratio/n-1)) FILTER (WHERE side IS NOT NULL AND n IS NOT NULL AND ratio IS NOT NULL) AS best_dev,
      count(*) AS slot_count, (array_agg(qid ORDER BY qid))[1] AS qid
    FROM slots GROUP BY 1,2),
  shaped AS (
    SELECT a.*,
      (a.band='B_DB_DECIDES' AND 'PACK_FAMILY'=ANY(a.ctypes) AND
       (a.families>1 OR a.sides>1 OR COALESCE(a.multiples,1)>1
        OR a.rsq_min IS DISTINCT FROM a.rsq_max OR a.rsq_min IS NULL)) AS pf_inconsistent,
      (a.band='B_DB_DECIDES' AND a.n_types=1 AND a.side='pack'   AND a.rsq_min=0) AS pack_canon_shape,
      (a.band='B_DB_DECIDES' AND a.n_types=1 AND a.side='single' AND a.rsq_min=1) AS single_canon_shape,
      (a.band='B_DB_DECIDES' AND a.n_types=1 AND a.side='pack'   AND a.rsq_min=1) AS pack_tracks_stock,
      -- NEW v3: a single that does NOT track stock means the family has NO stock-bearing code.
      (a.band='B_DB_DECIDES' AND a.n_types=1 AND a.side='single' AND a.rsq_min=0) AS family_has_no_stock_code,
      -- NEW v3: SHARED_EAN successor signature -- canon SS17: "exactly one code selling, the clean
      -- successor signature the database can rule alone."
      (a.band='B_DB_DECIDES' AND a.n_types=1 AND 'SHARED_EAN'=ANY(a.ctypes)) AS se_successor
    FROM agg a),
  final AS (
    SELECT s.*, sp.capital_value,
      CASE
        WHEN s.n_types>1                       THEN 'RESIDUE_HUMAN'
        WHEN s.is_weighed                      THEN 'KEEP'
        WHEN s.not_askable                     THEN 'RESIDUE_HUMAN'
        WHEN s.band IN ('C_RANK_LAST','D_ASK_FIRST') THEN 'RESIDUE_HUMAN'
        WHEN s.pf_inconsistent                 THEN 'RESIDUE_HUMAN'
        WHEN s.se_successor AND s.se_sells     THEN 'KEEP'
        WHEN s.se_successor                    THEN 'ZERO_AND_KILL'
        WHEN s.family_has_no_stock_code        THEN 'RESIDUE_HUMAN'
        WHEN s.single_canon_shape              THEN 'KEEP'
        WHEN s.pack_canon_shape                THEN 'KEEP'
        WHEN s.pack_tracks_stock               THEN 'CONVERT_TO_NON_DEPLETE'
        ELSE 'RESIDUE_HUMAN' END AS v
    FROM shaped s
    LEFT JOIN l2_stock_position sp ON sp.client_id='socialbrand'
      AND sp.store_code=s.store_code AND sp.product_code=s.code)
  INSERT INTO l2_product_resolution (
    store_code, product_code, family_key, level, pack_multiple, is_keeper, verdict,
    cost_error, capital_impact_rand, story, evidence, confidence,
    engine_version, computed_at, queue_candidate_id)
  SELECT f.store_code, f.code,
    CASE WHEN f.n_types=1 THEN f.fam ELSE NULL END,
    CASE WHEN f.n_types>1 OR f.band<>'B_DB_DECIDES' OR NOT ('PACK_FAMILY'=ANY(f.ctypes)) THEN NULL
         WHEN f.side='single' THEN 'single' WHEN f.n=6 THEN 'six'
         WHEN f.n=24 THEN 'twentyfour' ELSE 'pack' END,
    CASE WHEN f.n_types>1 OR f.band<>'B_DB_DECIDES' OR NOT ('PACK_FAMILY'=ANY(f.ctypes)) THEN NULL
         WHEN f.side='single' THEN 1 ELSE f.n END,
    -- is_keeper is asserted ONLY where the database genuinely decided it: the SHARED_EAN
    -- successor. Everywhere else it stays NULL (item-12 rule 3).
    CASE WHEN f.se_successor THEN f.se_sells ELSE NULL END,
    f.v, NULL::boolean, COALESCE(f.capital_value,0),
    CASE
      WHEN f.n_types>1 THEN format('Code %s carries %s open questions at once (%s). One code has one verdict slot, so the engine resolves none rather than picking. Falsifier: closing every type but one.', f.code, f.n_types, array_to_string(f.ctypes,' + '))
      WHEN f.is_weighed THEN format('Code %s is a weighed line (pack content by KG). Canon SS11: scale and loose lines are not barcode-countable by design and are counted in DIWAINV by article. No missing identity, NOT a floor question. Falsifier: it selling as a barcoded each.', f.code)
      WHEN f.not_askable THEN format('Code %s sits in a pack family whose pack description carries no numeric suffix (the mid-string CRATE / PK / C-PACK class). Canon SS17: these need the mid-string matcher before they are queued at all, so this is HELD and deliberately not put to anyone. Falsifier: the matcher extracting a multiple.', f.code)
      WHEN f.band='C_RANK_LAST' THEN format('Code %s is unresolved but nothing live moves on it: %s. Ranked last. Falsifier: the line selling again.', f.code, CASE WHEN 'ABSENT_FROM_DBREFE'=ANY(f.ctypes) THEN 'no scannable code and never sold' ELSE 'two codes share a barcode and neither sells' END)
      WHEN f.band='D_ASK_FIRST' THEN CASE
          WHEN 'ABSENT_FROM_DBREFE'=ANY(f.ctypes) THEN format('ASK THE FLOOR: "Scan the pack on the shelf and tell me what code comes up." Code %s (%s) sells but the ledger holds no scannable code for it. Falsifier: the scan returning nothing, which is itself the answer.', f.code, COALESCE(f.root,'?'))
          WHEN 'PACK_FAMILY'=ANY(f.ctypes) THEN format('ASK THE FLOOR: "Count the singles inside the pack you are holding and tell me the number." Code %s in family "%s": the description says _%s but the sell price says about %sx, disagreeing by %s%%. Falsifier: the count matching one of the two.', f.code, COALESCE(f.root,'?'), f.n, round(f.n*(1+f.best_dev),1), round(f.best_dev*100,1))
          ELSE format('ASK THE FLOOR: "Scan each of these two products in turn and tell me the code that comes up on each." Code %s shares barcode %s with another code and BOTH sell. Falsifier: the two scans returning different codes.', f.code, COALESCE(f.root,'?')) END
      WHEN f.pf_inconsistent THEN format('ASK THE FLOOR: "Count the singles inside the pack you are holding and tell me the number." Code %s could not be resolved deterministically -- it appears in %s families, %s sides, %s multiples. The engine does not guess a family. Falsifier: a single family, side and multiple.', f.code, f.families, f.sides, COALESCE(f.multiples,0))
      WHEN f.se_successor AND f.se_sells THEN format('Code %s SURVIVES: it shares barcode %s with another code and it is the only one of the two that sells. Canon SS17 calls that the clean successor signature the database rules alone. Falsifier: the other code selling again.', f.code, COALESCE(f.root,'?'))
      WHEN f.se_successor THEN format('Code %s is the SUPERSEDED half of barcode %s -- it shares that barcode with a code that sells while this one does not. RECOMMENDATION ONLY: zero its SOH first, retire at source after. Nothing is changed by the engine. Falsifier: this code selling again, which reopens it.', f.code, COALESCE(f.root,'?'))
      WHEN f.family_has_no_stock_code THEN format('ASK THE FLOOR: "Which of these codes do you count when you count this product?" Code %s is the single of family "%s" but it does NOT track stock, and neither does its pack -- so the family has NO stock-bearing code and canon SS14 v5''s milk template is broken at both ends. Falsifier: a third code in the family holding the stock.', f.code, COALESCE(f.root,'?'))
      WHEN f.single_canon_shape THEN format('Code %s is the stock-bearing single of family "%s". Its pack prices at %sx and says _%s, agreeing within %s%%, so the database sets this family without asking anyone. Falsifier: the pack ceasing to track to this single.', f.code, f.root, round(f.n*(1+f.best_dev),2), f.n, round(f.best_dev*100,1))
      WHEN f.pack_canon_shape THEN format('Code %s is the %s-unit pack of family "%s", non-deplete by method (canon SS14 v5): it rings revenue and depletes into the single. Suffix _%s and a price ratio agreeing within %s%% both say %s. Falsifier: a price ratio moving beyond 25%% of the suffix.', f.code, f.n, f.root, f.n, round(f.best_dev*100,1), f.n)
      WHEN f.pack_tracks_stock THEN format('Code %s is the %s-unit pack of family "%s" but it TRACKS STOCK while its single does too -- the rogue shape canon SS14 v5 names, holding %s units and %s of book capital. RECOMMENDATION ONLY. Falsifier: the floor confirming this is genuinely the stock-bearing code.', f.code, f.n, f.root, COALESCE(f.soh,0), to_char(COALESCE(f.capital_value,0),'FM999G999G990D00'))
      ELSE format('Code %s did not match any resolved shape and is left for a person.', f.code) END,
    jsonb_build_object(
      'rank_band', CASE WHEN f.is_weighed THEN 'A_OUT_OF_SCOPE_correct_by_s11'
                        WHEN f.not_askable THEN 'A_HELD_not_askable'
                        ELSE f.band END,
      'askable', (f.v='RESIDUE_HUMAN' AND NOT f.is_weighed AND NOT f.not_askable),
      'candidate_types', to_jsonb(f.ctypes), 'source_bands', to_jsonb(f.bands),
      'root', f.root, 'family_key', f.fam, 'side', f.side, 'pack_multiple', f.n,
      'price_ratio_deviation', round(f.best_dev,4), 'record_stock_qty', f.rsq_min,
      'soh', f.soh, 'queue_slots', f.slot_count,
      'question', CASE WHEN NOT (f.v='RESIDUE_HUMAN' AND NOT f.is_weighed AND NOT f.not_askable) THEN NULL WHEN 'ABSENT_FROM_DBREFE'=ANY(f.ctypes) THEN 'Scan the pack on the shelf and tell me what code comes up.' WHEN 'PACK_FAMILY'=ANY(f.ctypes) THEN 'Count the singles inside the pack you are holding and tell me the number.' ELSE 'Scan each of these two products in turn and tell me the code that comes up on each.' END, 'rule','canon SS17 item-12 + SS14 ADDENDUM v5 + SS11'),
    CASE WHEN f.v='RESIDUE_HUMAN' OR f.band<>'B_DB_DECIDES' OR f.n_types>1 THEN NULL
         WHEN f.se_successor THEN 0.90
         WHEN f.best_dev IS NULL THEN NULL
         WHEN f.best_dev<=0.05 THEN 0.95 WHEN f.best_dev<=0.15 THEN 0.85 ELSE 0.75 END,
    v_engine_version, now(), f.qid
  FROM final f;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  SELECT jsonb_build_object('store_code',p_store,'engine_version',v_engine_version,
    'deleted',v_deleted,'inserted',v_inserted,
    'by_verdict',(SELECT jsonb_object_agg(verdict,n) FROM (SELECT verdict,count(*) n FROM l2_product_resolution WHERE store_code=p_store GROUP BY 1) t),
    'askable',(SELECT count(*) FROM l2_product_resolution WHERE store_code=p_store AND (evidence->>'askable')::boolean)) INTO v_res;
  RETURN v_res;
END;
$function$
;

REVOKE EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_product_resolution(text) TO authenticated;
