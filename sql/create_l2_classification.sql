-- =============================================================================
-- l2_classification  --  THE ENGINE (Loom, Layer 2) verdict table
-- =============================================================================
-- Canon: CLEANUP-ENGINE-CANON.md (SB-INDEX-016) section 8 "EXACT DEFINITIONS v1.0"
--        is the single buildable spec and wins over all earlier prose.
-- Brief: SB-CC-FAMILY3-COUNT-ENGINE-001 / SB-CC-L1-EAN-COMPLETENESS (gate CLEARED
--        2026-06-12: v_item_ean v2 live on DBREFE native scan refs, scan_refs 5/5).
--
-- One row per in-scope article per store per run. Deterministic, one pass,
-- first match wins. Precomputes BOTH the verdict (bucket = why) and the file
-- route (artifact = where) so the Fixer (Forge, L3) stays logic-free (R21).
--
-- SCOPE (s8.2, binding -- no value floor ever):
--   l2_stock_position WHERE class='NORMAL' AND soh<>0. Store-scoped (recycled
--   product-code guard). Existence in sigma_articles is implied (l2_stock_position
--   is built from it).
--
-- SIGNALS (s8.3) -- all from the raw sigma_movements ledger + v_item_ean.
--   Summary fields (last_sale_date / last_receipt_date) are cross-checks only,
--   never inputs (they are blind to stocktakes/transfers -- the over-zeroing
--   lesson). Windows measured from ref_date = the store's freshest ledger date.
--
-- MOVEMENT ENCODING (verified live 2026-06-13 on 10116, RULE-BOOK s16 R24):
--   K            = till sale (process NULL)
--   R (proc W)   = GRV receipt (+in / -return)
--   I (proc M)   = stocktake (DIWAINV) -- a confirmation, neutral flow
--   S/L (upper)  = stock injection (all +)
--   S/l (lower)  = outflow (all <=0)
--   S/Z S/M S/G S/D = outflows (all <0): write-off / Coca-Cola return / deposit / misc
--   S/O          = BIDIRECTIONAL, UNDECODED (R24). Used here ONLY to AVOID a zero
--                  (liveness + count routing), NEVER to justify a zero.
--
-- EAN RESOLUTION (s8.4) from v_item_ean v2:
--   has_barcode=true                         -> REAL  (ean_key = first barcode)
--   is_confirmed_plu=true (no barcode)       -> PLU   (ean_key NULL)
--   neither                                  -> UNRESOLVED (still classified by
--                                               behaviour from 2026-07-01, see PATCH
--                                               below -- identity gates the artifact,
--                                               never the verdict. Lands in AMBIGUOUS
--                                               only as the genuine residual, s8.10).
--   SYNTHETIC is NOT assigned here -- it may only be issued after the server
--   source is fully mapped (canon s8.4); ~332 in-scope UNRESOLVED as of 2026-07-01
--   (root cause: recycled/duplicate Sigma product codes, see PATCH TRACE below).
--
-- v1.1 INPUTS (s8.12, BINDING; Pieter, the Dice wrong-zero day) are present below
--   as clearly-flagged [[v1.1]] blocks, currently INERT pending PM's 06-13
--   count-vs-verdict ratification pack. They do not change the table contract,
--   the signals, the EAN resolution, or the KPI sets -- only the cascade ORDER of
--   two lines and the TLX near-certainty gate. Flip on ratification, no rewrite.
--
-- Refresh: SELECT refresh_l2_classification('10116');  -- per store, nightly,
--   after the L2 chain (l2_stock_position must be fresh). Idempotent: DELETE the
--   (store, ref_date) slice + re-INSERT. Returns a JSONB summary incl. the
--   unresolved_ean count (s8.6 guard 4: no silent empties).
-- =============================================================================
--
-- PATCH 2026-07-01 (CC, PM directive "Engine self-reliance", anchored to R21/
-- R25/R28 + canon s8.5/8.10/10). effective_from 2026-07-01. Supersedes the
-- s8.4 "ean_unresolved -> AMBIGUOUS" pre-gate below (superseded_on same date,
-- R28 -- the old rule is not deleted, it is described here as retired and why).
--
-- FAULT: the pre-gate sent every UNRESOLVED-EAN line straight to AMBIGUOUS
-- BEFORE any behaviour signal (moved_365_any / sold_91 / commercial_in_365 /
-- commercial_out_365 / counted_91 / recv_91) was ever evaluated. Identity was
-- acting as a GATE on classification itself, not a signal on artifact routing.
-- Verified live: 332 in-scope lines are currently UNRESOLVED across the 5
-- stores; 214 of them (64%) already carry a behaviour signal that the cascade
-- never got to see (COKE ZERO PET, CASTLE LITE, TILL ROLLS, HEINEKEN CRATES,
-- SAVANNA C/PACK, ICE among them).
--
-- CHANGE (GENERAL, R21 -- the formula, not the product):
--   1. The pre-gate is REMOVED. UNRESOLVED lines now flow through the full
--      cascade like any other line. ean_status stops gating the VERDICT and
--      continues to gate only the ARTIFACT: `tlx` still requires a real,
--      scannable barcode ("you cannot TLX what you cannot scan") -- DEAD_ZERO
--      and PHANTOM_ZERO on a non-REAL line still route to zero_manual/
--      stockflow/ambiguous, never tlx. Nothing about auto-zero safety changed.
--   2. area_class (s8.3) widened past the narrow SERVICE/CONSUMABLE dept-name
--      regex: CONSUMABLE now also matches a packaging-department signal
--      (DEMO_CALIBRATION -- 'FRONTEND PACK' is this estate's literal dept
--      name; a new operator recalibrates the department, not the mechanism)
--      plus a wider GENERAL description vocabulary (bags/wraps/foil/film/
--      straws/lids/labels/serviettes/tape, word-bounded to avoid false
--      positives like CUPCAKE).
--   3. NEW GENERAL signal `ever_received` (full ledger history, unwindowed --
--      canon s11's exact test: "K movements + ZERO R movements ever" is a
--      full-history question, not a 365d one). SOURCE_FIX (step 7) widened:
--      a line that sold in the last 365d and has NEVER had a GRV receipt in
--      its whole history is production behaviour regardless of dept-name
--      regex or EAN status (excluding REAL -- a real barcode implies bought,
--      canon s10 "a real EAN proves bought, not sold" is not overridden here,
--      it is the reason REAL stays out of this branch).
--   4. Steps 7/8 (SOURCE_FIX/EXPENSE_ZERO) widened from `ean_status IN
--      (PLU,SYNTHETIC)` to also admit UNRESOLVED -- an unmapped internal
--      code behaving like packaging or production is still packaging or
--      production; the identity gap is a separate, tracked debt (see TRACE),
--      not a reason to withhold the verdict.
--   5. AMBIGUOUS (step 9, else) is now reached ONLY after every behavioural
--      and widened area/production test has failed -- the genuine residual
--      per canon s8.10, proven not tuned: no target total was set, see the
--      verification report for the before/after split and every residual
--      reason.
--
-- TRACE (the "why" behind the identity gap, closed at source per PM directive):
--   Root cause is NOT an extractor bug. Invoke-ExtractScanRefs pulls DBREFE
--   with no WHERE filter beyond the dARTNR/dREFNR dedup (rn=1) -- every row
--   Sigma holds is already being extracted. blocked_flag is not the cause
--   either (100% of live sigma_scan_refs rows carry blocked_flag='0').
--   Verified live on CASTLE LITE @ 21355: ~50 distinct product_codes exist
--   for the same physical product (240, 230, 277, 272, 314 UNRESOLVED vs 286
--   "CASTLE LITE NRB" REAL, barcode 6003326015721, actively selling+
--   receiving). This is Sigma's own recycled/duplicate-product-code pattern
--   (already canonised -- Sprite 2944/76807, "recycled product codes" s2,
--   LINK_CODES s8.12#5): the ACTIVE/current-listing code carries the DBREFE
--   scan-ref registration; superseded/legacy sibling codes that still carry
--   residual SOH/sales in the ledger do not. Closing this fully (borrowing a
--   resolved sibling's identity via description/merch_group matching) is the
--   already-designed but not-yet-built l2_link_codes_queue (s8.12#5) -- CC
--   recommends prioritising that build next; it was not built into this
--   patch (a matching-rule of that weight deserves its own session, R21 s3/
--   s4, not a bolt-on under this one). This patch's cascade fix already
--   resolves the OPERATIONAL symptom for the 214/332 behaviourally-rescuable
--   lines without needing LINK_CODES; LINK_CODES would further shrink the
--   remaining true-unresolved population and let SYNTHETIC ids be assigned
--   correctly (canon s8.4) instead of leaving them UNRESOLVED forever.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- TABLE (Rule 19: DROP + clean CREATE)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.l2_classification CASCADE;

CREATE TABLE public.l2_classification (
    -- identity, frozen at snapshot (R22)
    client_id            text        NOT NULL DEFAULT 'socialbrand',
    store_code           text        NOT NULL,
    product_code         bigint      NOT NULL,
    snapshot_date        date        NOT NULL,
    description          text,
    dept_name            text,
    subdept_name         text,
    soh                  numeric,
    capital_value        numeric,
    unit_cost            numeric,
    -- signals (s8.3), all booleans COALESCE'd to false
    sold_91              boolean     NOT NULL DEFAULT false,
    sold_365             boolean     NOT NULL DEFAULT false,
    commercial_in_365    boolean     NOT NULL DEFAULT false,
    commercial_out_365   boolean     NOT NULL DEFAULT false,
    recv_91              boolean     NOT NULL DEFAULT false,
    counted_91           boolean     NOT NULL DEFAULT false,
    moved_365_any        boolean     NOT NULL DEFAULT false,
    ever_received        boolean     NOT NULL DEFAULT false,   -- PATCH 2026-07-01: full-history receipt check (canon s11)
    root_sibling_ever_received boolean NOT NULL DEFAULT false, -- PATCH 2026-07-01: description-root sibling corroboration guard
    -- resolution + area
    ean_status           text        NOT NULL,   -- REAL / PLU / UNRESOLVED
    ean_key              text,
    area_class           text,                   -- SERVICE / CONSUMABLE / MERCH (interim regex)
    nonstock_account     boolean     NOT NULL DEFAULT false,
    deposit_account      boolean     NOT NULL DEFAULT false,   -- SB-CC-DEPOSIT-001: deposit/returnable float
    cost_sanity_flag     boolean     NOT NULL DEFAULT false,
    -- verdict + route
    bucket               text        NOT NULL,   -- NON_STOCK COST_ERROR DEPOSIT DEAD_ZERO HEALTHY COUNT
                                                 -- LEAVE_COUNTED PHANTOM_ZERO AMBIGUOUS SOURCE_FIX EXPENSE_ZERO
    artifact             text        NOT NULL,   -- none tlx stockflow zero_manual ambiguous source_fix non_stock cost_error
    bucket_reason        text,
    engine_version       text        NOT NULL,
    classified_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT l2_classification_pk UNIQUE (store_code, product_code, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_l2_class_store_date   ON public.l2_classification (store_code, snapshot_date);
CREATE INDEX IF NOT EXISTS idx_l2_class_bucket       ON public.l2_classification (store_code, snapshot_date, bucket);
CREATE INDEX IF NOT EXISTS idx_l2_class_artifact     ON public.l2_classification (store_code, snapshot_date, artifact);

GRANT SELECT ON public.l2_classification TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- REFRESH FUNCTION
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.refresh_l2_classification(text, date) CASCADE;

CREATE OR REPLACE FUNCTION public.refresh_l2_classification(
    p_store         text,
    p_snapshot_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_engine   text := 'l2_classification v1.1 (canon s8.5, behaviour-first PATCH 2026-07-01; v1.1 s8.12 inputs still inert)';
    v_ref      date;
    v_summary  jsonb;
    v_pool     int;
    v_unres    int;
BEGIN
    -- Anchor the 91/365-day windows to the store's freshest ledger date, NOT a
    -- wall clock (stores lag; data-relative windows are correct + auditable).
    v_ref := COALESCE(
        p_snapshot_date,
        (SELECT MAX(movement_date) FROM sigma_movements WHERE store_code = p_store)
    );
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'refresh_l2_classification: no movement data for store %', p_store;
    END IF;

    -- Idempotent: clear this (store, ref_date) slice first.
    DELETE FROM l2_classification WHERE store_code = p_store AND snapshot_date = v_ref;

    WITH
    -- s8.3 signals, aggregated per product_code from the raw ledger.
    sig AS (
        SELECT
            product_code,
            bool_or(movement_type = 'K' AND movement_date >  v_ref - 91 )                              AS sold_91,
            bool_or(movement_type = 'K' AND movement_date >  v_ref - 365)                              AS sold_365,
            -- received (in) within 91d: GRV receipt with qty>0 (the still-arriving guard, line 4b)
            bool_or(movement_type = 'R' AND qty > 0 AND movement_date > v_ref - 91)                    AS recv_91,
            -- stocktake within 91d = human-verified present
            bool_or(movement_type = 'I' AND movement_date > v_ref - 91)                                AS counted_91,
            -- ANY movement within 365d = the TRUE liveness test (includes S/O -> avoids a wrong zero)
            bool_or(movement_date > v_ref - 365)                                                       AS moved_365_any,
            -- commercial IN (365d): GRV receipt-in OR S/L injection OR S/O qty-in
            bool_or(movement_date > v_ref - 365 AND (
                       (movement_type = 'R' AND qty > 0)
                    OR (movement_type = 'S' AND movement_process = 'L')
                    OR (movement_type = 'S' AND movement_process = 'O' AND qty > 0)
                  ))                                                                                    AS commercial_in_365,
            -- commercial OUT (365d): till sale OR S/{l,Z,M,G,D} OR S/O qty-out
            bool_or(movement_date > v_ref - 365 AND (
                       movement_type = 'K'
                    OR (movement_type = 'S' AND movement_process IN ('l','Z','M','G','D'))
                    OR (movement_type = 'S' AND movement_process = 'O' AND qty < 0)
                  ))                                                                                    AS commercial_out_365
        FROM sigma_movements
        WHERE store_code = p_store
          AND movement_date > v_ref - 365
        GROUP BY product_code
    ),
    -- ever_recv (PATCH 2026-07-01, GENERAL): full ledger history, UNWINDOWED --
    -- canon s11's production test ("K movements + ZERO R movements ever") is a
    -- full-history question. Deliberately separate from `sig` above, which is
    -- windowed to 365d for every other signal.
    ever_recv AS (
        SELECT DISTINCT product_code
        FROM sigma_movements
        WHERE store_code = p_store AND movement_type = 'R'
    ),
    -- root_sibling (PATCH 2026-07-01, GENERAL -- bounded corroboration guard,
    -- added after the story-test caught a false positive): "sells with no
    -- receipts ever" on its own cannot distinguish genuine production (ICE) from
    -- a duplicate/recycled Sigma product code riding on an actively-purchased
    -- SIBLING's receiving (live catch: CASTLE LITE 240/272/277 @ 21355 vs the
    -- resolved "CASTLE LITE NRB" 286, which carries the real GS1 + receipts --
    -- exactly the recycled-code pattern from the TRACE above). description_root
    -- strips common pack/container/size tokens -- the SAME "strip the pack
    -- suffix" concept canon already uses for parent-child pack detection -- so
    -- siblings group together. If ANY sibling under the same root ever
    -- received, this line is not production; it is an identity problem
    -- (LINK_CODES' job, s8.12#5), not a BOM/source-fix problem, and it falls
    -- through to AMBIGUOUS as the honest residual instead.
    root_sibling AS (
        SELECT
            regexp_replace(regexp_replace(upper(trim(sp2.description)),
                '[_ ]?(NRB|RB|CAN|PET|BTL|PK|CASE|CRATE|\d+ML|\d+L|\d+KG|\d+X\d+ML|\d+X\d+L)\M', '', 'g'),
                '\s+', ' ', 'g')                       AS description_root,
            bool_or(er.product_code IS NOT NULL)        AS root_ever_received
        FROM l2_stock_position sp2
        LEFT JOIN ever_recv er ON er.product_code = sp2.product_code
        WHERE sp2.store_code = p_store AND sp2.class = 'NORMAL' AND sp2.soh <> 0
        GROUP BY 1
    ),
    base AS (
        SELECT
            sp.client_id, sp.store_code, sp.product_code, sp.description,
            sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value, sp.unit_cost,
            sp.cost_sanity_flag,
            COALESCE(s.sold_91,            false) AS sold_91,
            COALESCE(s.sold_365,           false) AS sold_365,
            COALESCE(s.commercial_in_365,  false) AS commercial_in_365,
            COALESCE(s.commercial_out_365, false) AS commercial_out_365,
            COALESCE(s.recv_91,            false) AS recv_91,
            COALESCE(s.counted_91,         false) AS counted_91,
            COALESCE(s.moved_365_any,      false) AS moved_365_any,
            -- ever_received (PATCH 2026-07-01, GENERAL): full-history receipt
            -- check, powers the widened production signature at step 7.
            (er.product_code IS NOT NULL)          AS ever_received,
            -- root_sibling_ever_received (PATCH 2026-07-01, GENERAL): corroboration
            -- guard, see root_sibling CTE above.
            COALESCE(rs.root_ever_received, false)  AS root_sibling_ever_received,
            -- EAN resolution (s8.4)
            CASE
                WHEN COALESCE(ie.has_barcode, false)      THEN 'REAL'
                WHEN COALESCE(ie.is_confirmed_plu, false) THEN 'PLU'
                ELSE 'UNRESOLVED'
            END AS ean_status,
            CASE WHEN COALESCE(ie.has_barcode, false)
                 THEN split_part(ie.barcode_list, '|', 1)
                 ELSE NULL END AS ean_key,
            -- area_class (s8.3, interim regex until a server-side dimension lands, R23)
            -- PATCH 2026-07-01: CONSUMABLE widened past the narrow keyword list --
            -- (a) DEMO_CALIBRATION dept-name signal (FRONTEND PACK/PACKAGING/
            --     CONSUMABLES -- this estate's literal packaging department;
            --     a new operator recalibrates the name, not the mechanism), OR
            -- (b) GENERAL description vocabulary, word-bounded (\m..\M) so
            --     generic tokens (BAG, WRAP, CUP, LID) don't false-positive on
            --     real merchandise (CUPCAKE, GIFT WRAP paper as a sold item, etc).
            CASE
                WHEN (COALESCE(sp.dept_name,'') || ' ' || COALESCE(sp.subdept_name,'')) ~*
                     '(BUTCHER|BAKERY|BAKE OFF|DELI|HMR|HOME MEAL|CONFECTION|HOT FOOD|ROTISSER|SUSHI|PIZZA|SALAD BAR|PREP)'
                     THEN 'SERVICE'
                WHEN (COALESCE(sp.dept_name,'') || ' ' || COALESCE(sp.subdept_name,'')) ~*
                     '(FRONT.?END\s*PACK|PACKAGING|NON.?FOOD\s*NON.?SCAN|\mCONSUMABLES?\M)'
                  OR (COALESCE(sp.dept_name,'') || ' ' || COALESCE(sp.subdept_name,'') || ' ' || COALESCE(sp.description,'')) ~*
                     '(PACKAG|\mCONSUMABLE\M|CARRIER\s*BAG|SHOPPING\s*BAG|C/BAG|\mBAGS?\M|\mFOIL\M|CLING\s*(FILM|WRAP)|\mWRAP(PING)?\M|\mSTRAW(S)?\M|TILL\s*ROLL|SHELF\s*LABEL|\mSERVIETTES?\M|\mNAPKINS?\M|CLEANING\s*MATERIAL|STATIONER|\mLIDS?\M|STYRENE|\mFOMO\M)'
                     THEN 'CONSUMABLE'
                ELSE 'MERCH'
            END AS area_class,
            -- nonstock_account (s8.3): accounting lines living inside NORMAL
            ( COALESCE(sp.description,'') ~* '((^|[^0-9])14\s*%|NON.?SCAN|SALES?\s*DIFF|ROUNDING|SUSPENSE ACCOUNT)' ) AS nonstock_account,
            -- deposit_account (SB-CC-DEPOSIT-001): deposit/returnable float -- quart
            -- deposits, empties, crates, charge bottles. Returnable liability matched
            -- to a float, NOT velocity-movable stock investment -> carved out of the
            -- headline Capital Tied into a surfaced Deposits line. Description-based
            -- (interim, R23): the S/G deposit-return channel was evaluated and
            -- REJECTED as the identity -- at 10116 S/G also carries normal grocery
            -- supplier-returns (milk/beans), so S/G-alone over-carves real stock.
            ( COALESCE(sp.description,'') ~* '(\mDEP\M|\mDEPOSIT\M|EMPT(Y|IES)|RETURNABLE|\mCRATE|CHARGE BOTTLE)' ) AS deposit_account
        FROM l2_stock_position sp
        LEFT JOIN sig s ON s.product_code = sp.product_code
        LEFT JOIN ever_recv er ON er.product_code = sp.product_code
        LEFT JOIN root_sibling rs
               ON rs.description_root = regexp_replace(regexp_replace(upper(trim(sp.description)),
                    '[_ ]?(NRB|RB|CAN|PET|BTL|PK|CASE|CRATE|\d+ML|\d+L|\d+KG|\d+X\d+ML|\d+X\d+L)\M', '', 'g'),
                    '\s+', ' ', 'g')
        LEFT JOIN v_item_ean ie
               ON ie.store_code = sp.store_code AND ie.product_code = sp.product_code
        WHERE sp.store_code = p_store
          AND sp.class = 'NORMAL'
          AND sp.soh <> 0
    ),
    verdict AS (
        SELECT b.*,
        -- =====================================================================
        -- THE CASCADE (s8.5) -- one pass, first match wins. v1.0 ordering.
        -- [[v1.1]] s8.12 #2 promotes counted_91 ABOVE lines 3 and 4b (a 3-day-old
        --   count must never re-list for two-way movement). To flip on PM
        --   ratification: move the LEAVE_COUNTED branch up to immediately after
        --   the soh<0 COUNT branch. Inert today to stay faithful to FINAL v1.0.
        -- =====================================================================
        CASE
            WHEN b.nonstock_account                                          THEN 'NON_STOCK'      -- 0
            WHEN b.cost_sanity_flag                                          THEN 'COST_ERROR'     -- 0b
            -- SB-CC-DEPOSIT-001: deposit/returnable float carved here, ahead of the
            -- UNRESOLVED guard and the value cascade. Deposits are pass-through
            -- liability (not velocity-movable investment); they are NOT zeroed --
            -- kept whole, surfaced as their own Deposits line, excluded only from the
            -- headline Capital Tied include-set (s8.8). Many deposits are UNRESOLVED
            -- (no GS1) so this must precede 0c, but DEPOSIT never zeroes so the
            -- never-zero protection on unmapped items is preserved.
            WHEN b.deposit_account                                           THEN 'DEPOSIT'        -- 0c-DEP
            -- PATCH 2026-07-01: the old s8.4 "ean_status=UNRESOLVED -> AMBIGUOUS"
            -- pre-gate is RETIRED here (superseded_on 2026-07-01, R28 -- not
            -- deleted, described: it sent every unmapped line to AMBIGUOUS before
            -- any behaviour signal ran at all). Identity now gates the ARTIFACT
            -- only (tlx still requires a real scannable barcode, enforced in the
            -- artifact CASE below and in steps 2b/5/6 which stay REAL-gated by
            -- design) -- never the verdict. Behaviour runs first, from here down.
            WHEN NOT b.moved_365_any                                         THEN 'DEAD_ZERO'      -- 1
            WHEN b.sold_91 AND b.soh > 0
                 AND (b.ean_status = 'REAL'
                      OR (b.commercial_in_365 AND b.commercial_out_365))     THEN 'HEALTHY'        -- 2
            WHEN b.ean_status = 'REAL' AND b.sold_91 AND b.soh < 0           THEN 'COUNT'          -- 2b
            WHEN b.commercial_in_365 AND b.commercial_out_365               THEN 'COUNT'          -- 3
            WHEN b.counted_91                                               THEN 'LEAVE_COUNTED'  -- 4
            WHEN b.recv_91                                                  THEN 'COUNT'          -- 4b
            WHEN b.ean_status = 'REAL' AND NOT b.sold_365
                 AND NOT b.counted_91                                       THEN 'PHANTOM_ZERO'   -- 5
            WHEN b.ean_status = 'REAL'                                      THEN 'AMBIGUOUS'      -- 6
            -- PATCH 2026-07-01: 7/8 widened from ean_status IN (PLU,SYNTHETIC) to
            -- also admit UNRESOLVED (an unmapped internal code behaving like
            -- production/packaging is still production/packaging -- the identity
            -- gap is a separate tracked debt, see file header TRACE). REAL stays
            -- excluded by design (canon s10: a real EAN proves bought, not made).
            -- Step 7 also gains a GENERAL movement-signature OR: sold in 365d with
            -- NO receipt ever in the full ledger = made-in-store (canon s11),
            -- independent of the dept-name regex -- catches ICE-pattern lines
            -- whose department doesn't say BUTCHER/BAKERY/etc. Guarded by
            -- root_sibling_ever_received (story-test catch: without this guard,
            -- CASTLE LITE's duplicate/legacy codes at 21355 false-positived as
            -- production because their sibling code absorbs the real receiving).
            WHEN b.ean_status IN ('PLU','SYNTHETIC','UNRESOLVED')
                 AND (b.area_class = 'SERVICE'
                      OR (b.sold_365 AND NOT b.ever_received
                          AND NOT b.root_sibling_ever_received))              THEN 'SOURCE_FIX'    -- 7
            WHEN b.ean_status IN ('PLU','SYNTHETIC','UNRESOLVED')
                 AND b.area_class = 'CONSUMABLE'                              THEN 'EXPENSE_ZERO'  -- 8
            ELSE 'AMBIGUOUS'                                                                       -- 9 (genuine residual)
        END AS bucket
        FROM base b
    )
    INSERT INTO l2_classification (
        client_id, store_code, product_code, snapshot_date,
        description, dept_name, subdept_name, soh, capital_value, unit_cost,
        sold_91, sold_365, commercial_in_365, commercial_out_365, recv_91, counted_91, moved_365_any, ever_received, root_sibling_ever_received,
        ean_status, ean_key, area_class, nonstock_account, deposit_account, cost_sanity_flag,
        bucket, artifact, bucket_reason, engine_version, classified_at
    )
    SELECT
        v.client_id, v.store_code, v.product_code, v_ref,
        v.description, v.dept_name, v.subdept_name, v.soh, v.capital_value, v.unit_cost,
        v.sold_91, v.sold_365, v.commercial_in_365, v.commercial_out_365, v.recv_91, v.counted_91, v.moved_365_any, v.ever_received, v.root_sibling_ever_received,
        v.ean_status, v.ean_key, v.area_class, v.nonstock_account, v.deposit_account, v.cost_sanity_flag,
        v.bucket,
        -- ARTIFACT (s8.5 mapping). [[v1.1]] s8.12 #3 adds TLX near-certainty:
        --   tlx only when no active sibling family AND |soh|<24 (interim belt) AND
        --   real GS1 AND not counted_91. Sibling-family screen needs DF-1 +
        --   l2_link_codes_queue (a later build, canon s9), so the family condition
        --   is NOT yet enforced. The |soh|<24 belt IS available now and is applied
        --   so big REAL phantom/dead claims route to a COUNT, not a blind TLX
        --   ("more counts, less TLX"). When sibling guard ships, add it here.
        CASE v.bucket
            WHEN 'NON_STOCK'   THEN 'non_stock'
            WHEN 'COST_ERROR'  THEN 'cost_error'
            WHEN 'DEPOSIT'     THEN 'none'        -- kept whole, no fixer action; surfaced as Deposits line
            WHEN 'HEALTHY'     THEN 'none'
            WHEN 'COUNT'       THEN 'stockflow'
            WHEN 'LEAVE_COUNTED' THEN 'none'
            WHEN 'SOURCE_FIX'  THEN 'source_fix'
            WHEN 'EXPENSE_ZERO' THEN 'zero_manual'
            WHEN 'AMBIGUOUS'   THEN 'ambiguous'
            WHEN 'DEAD_ZERO'   THEN
                CASE WHEN v.ean_status = 'REAL' AND ABS(v.soh) < 24 THEN 'tlx'
                     WHEN v.ean_status = 'REAL'                     THEN 'stockflow'  -- big claim -> count, not blind zero
                     ELSE 'zero_manual' END
            WHEN 'PHANTOM_ZERO' THEN
                CASE WHEN ABS(v.soh) < 24 THEN 'tlx'
                     ELSE 'stockflow' END                                            -- big claim -> count
            ELSE 'ambiguous'
        END AS artifact,
        -- human-readable reason (R22) for every non-none verdict
        CASE v.bucket
            WHEN 'NON_STOCK'    THEN 'accounting/non-scan account line inside NORMAL'
            WHEN 'COST_ERROR'   THEN 'cost_sanity_flag: broken cost/pack -- fix Sigma cost first, capital is fiction'
            WHEN 'DEPOSIT'      THEN 'deposit/returnable float (deposits, empties, crates) -- pass-through liability, carved from Capital Tied, surfaced separately (SB-CC-DEPOSIT-001)'
            WHEN 'DEAD_ZERO'    THEN 'no movement of ANY type in 365d = dead'
                                     || CASE WHEN v.ean_status='REAL' AND ABS(v.soh)>=24 THEN ' (big SOH -> count, not blind tlx)' ELSE '' END
            WHEN 'HEALTHY'      THEN 'sold in 91d with positive SOH and a real/two-way identity'
            WHEN 'COUNT'        THEN CASE
                                       WHEN v.sold_91 AND v.soh < 0 THEN 'sells but SOH negative = receiving-gap, force count (s8.5 2b)'
                                       WHEN v.commercial_in_365 AND v.commercial_out_365 THEN 'two-way movement, presence unproven -> count'
                                       WHEN v.recv_91 THEN 'received in last 91d = still arriving, never auto-zero -> count'
                                       ELSE 'force count' END
            WHEN 'LEAVE_COUNTED' THEN 'stocktake within 91d = human-verified present, leave'
            WHEN 'PHANTOM_ZERO' THEN 'real EAN, not sold 365d, not counted 91d = phantom'
                                     || CASE WHEN ABS(v.soh)>=24 THEN ' (big SOH -> count first)' ELSE '' END
            WHEN 'SOURCE_FIX'   THEN CASE
                                       WHEN v.area_class = 'SERVICE' THEN 'no-barcode line in a service area -> Sigma source fix'
                                       ELSE 'sells in 365d with no receipt ever in the ledger = made-in-store (movement signature, canon s11)' END
                                     || CASE WHEN v.ean_status='UNRESOLVED' THEN ' [ean_unresolved -- see TRACE]' ELSE '' END
            WHEN 'EXPENSE_ZERO' THEN 'no-barcode consumable/packaging (dept or description signal) -> expense zero'
                                     || CASE WHEN v.ean_status='UNRESOLVED' THEN ' [ean_unresolved -- see TRACE]' ELSE '' END
            WHEN 'AMBIGUOUS'    THEN CASE
                                       WHEN v.ean_status = 'REAL' THEN 'real EAN, one-directional/insufficient signal -> investigate'
                                       WHEN v.ean_status = 'UNRESOLVED' THEN 'ean_unresolved AND no behaviour/area/production signal fired -- genuine residual, data gap, never zero (s8.4/s8.10)'
                                       ELSE 'no real EAN + merch area = data gap' END
            ELSE NULL
        END AS bucket_reason,
        v_engine,
        now()
    FROM verdict v;

    -- s8.6 guard 5: pool reconciliation. s8.6 guard 4: surface, never false-green.
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE ean_status = 'UNRESOLVED')
      INTO v_pool, v_unres
      FROM l2_classification
     WHERE store_code = p_store AND snapshot_date = v_ref;

    SELECT jsonb_build_object(
        'store_code',     p_store,
        'snapshot_date',  v_ref,
        'engine_version', v_engine,
        'pool_total',     v_pool,
        'unresolved_ean', v_unres,
        'by_bucket', (
            SELECT jsonb_object_agg(bucket, n)
            FROM (SELECT bucket, COUNT(*) n FROM l2_classification
                   WHERE store_code = p_store AND snapshot_date = v_ref
                   GROUP BY bucket) q
        ),
        'by_artifact', (
            SELECT jsonb_object_agg(artifact, n)
            FROM (SELECT artifact, COUNT(*) n FROM l2_classification
                   WHERE store_code = p_store AND snapshot_date = v_ref
                   GROUP BY artifact) q
        ),
        'capital_tied', (
            -- s8.8 Capital Tied include-set: HEALTHY + COUNT + AMBIGUOUS + LEAVE_COUNTED.
            -- DEPOSIT is now its own bucket so it is auto-excluded here (SB-CC-DEPOSIT-001).
            SELECT COALESCE(SUM(capital_value),0) FROM l2_classification
             WHERE store_code = p_store AND snapshot_date = v_ref
               AND bucket IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED')
        ),
        'capital_deposits', (
            -- SB-CC-DEPOSIT-001: deposit/returnable float, surfaced separately (not in headline)
            SELECT COALESCE(SUM(capital_value),0) FROM l2_classification
             WHERE store_code = p_store AND snapshot_date = v_ref
               AND bucket = 'DEPOSIT'
        )
    ) INTO v_summary;

    RETURN v_summary;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_classification(text, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
