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
--   neither                                  -> UNRESOLVED (error state -> AMBIGUOUS,
--                                               reason ean_unresolved; never zeroed).
--   SYNTHETIC is NOT assigned here -- it may only be issued after the server
--   source is fully mapped (canon s8.4); we are at ~410 unresolved, not 0.
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
    -- resolution + area
    ean_status           text        NOT NULL,   -- REAL / PLU / UNRESOLVED
    ean_key              text,
    area_class           text,                   -- SERVICE / CONSUMABLE / MERCH (interim regex)
    nonstock_account     boolean     NOT NULL DEFAULT false,
    cost_sanity_flag     boolean     NOT NULL DEFAULT false,
    -- verdict + route
    bucket               text        NOT NULL,   -- NON_STOCK COST_ERROR DEAD_ZERO HEALTHY COUNT
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
    v_engine   text := 'l2_classification v1.0 (canon s8.5; v1.1 inputs inert)';
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
            CASE
                WHEN (COALESCE(sp.dept_name,'') || ' ' || COALESCE(sp.subdept_name,'')) ~*
                     '(BUTCHER|BAKERY|BAKE OFF|DELI|HMR|HOME MEAL|CONFECTION|HOT FOOD|ROTISSER|SUSHI|PIZZA|SALAD BAR|PREP)'
                     THEN 'SERVICE'
                WHEN (COALESCE(sp.dept_name,'') || ' ' || COALESCE(sp.subdept_name,'') || ' ' || COALESCE(sp.description,'')) ~*
                     '(PACKAG|CONSUMABLE|CARRIER BAG|SHOPPING BAG|STRAW|TILL ROLL|SHELF LABEL|CLEANING MATERIAL|STATIONER)'
                     THEN 'CONSUMABLE'
                ELSE 'MERCH'
            END AS area_class,
            -- nonstock_account (s8.3): accounting lines living inside NORMAL
            ( COALESCE(sp.description,'') ~* '((^|[^0-9])14\s*%|NON.?SCAN|SALES?\s*DIFF|ROUNDING|SUSPENSE ACCOUNT)' ) AS nonstock_account
        FROM l2_stock_position sp
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
            -- s8.4 hard guard: an UNRESOLVED EAN is an error state, not a class.
            -- It pre-empts every zero/count/healthy line so an unmapped item is
            -- NEVER zeroed/expensed (the over-zeroing lesson) -- it routes to
            -- AMBIGUOUS (work queue, reason ean_unresolved) until L1 mapping
            -- resolves it. This also makes line 1's "else zero_manual" apply only
            -- to RESOLVED PLU/SYNTHETIC dead lines, reconciling s8.4 with s8.5.
            WHEN b.ean_status = 'UNRESOLVED'                                 THEN 'AMBIGUOUS'      -- 0c (s8.4)
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
            WHEN b.ean_status IN ('PLU','SYNTHETIC') AND b.area_class = 'SERVICE'
                                                                            THEN 'SOURCE_FIX'    -- 7
            WHEN b.ean_status IN ('PLU','SYNTHETIC') AND b.area_class = 'CONSUMABLE'
                                                                            THEN 'EXPENSE_ZERO'  -- 8
            ELSE 'AMBIGUOUS'                                                                       -- 9
        END AS bucket
        FROM base b
    )
    INSERT INTO l2_classification (
        client_id, store_code, product_code, snapshot_date,
        description, dept_name, subdept_name, soh, capital_value, unit_cost,
        sold_91, sold_365, commercial_in_365, commercial_out_365, recv_91, counted_91, moved_365_any,
        ean_status, ean_key, area_class, nonstock_account, cost_sanity_flag,
        bucket, artifact, bucket_reason, engine_version, classified_at
    )
    SELECT
        v.client_id, v.store_code, v.product_code, v_ref,
        v.description, v.dept_name, v.subdept_name, v.soh, v.capital_value, v.unit_cost,
        v.sold_91, v.sold_365, v.commercial_in_365, v.commercial_out_365, v.recv_91, v.counted_91, v.moved_365_any,
        v.ean_status, v.ean_key, v.area_class, v.nonstock_account, v.cost_sanity_flag,
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
            WHEN 'SOURCE_FIX'   THEN 'PLU/scale line in a service area -> Sigma source fix'
            WHEN 'EXPENSE_ZERO' THEN 'PLU consumable/packaging -> expense zero'
            WHEN 'AMBIGUOUS'    THEN CASE
                                       WHEN v.ean_status = 'UNRESOLVED' THEN 'ean_unresolved: no barcode + no PLU flag -- data gap, never zero (s8.4)'
                                       WHEN v.ean_status = 'REAL' THEN 'real EAN, one-directional/insufficient signal -> investigate'
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
            -- s8.8 Capital Tied include-set: HEALTHY + COUNT + AMBIGUOUS + LEAVE_COUNTED
            SELECT COALESCE(SUM(capital_value),0) FROM l2_classification
             WHERE store_code = p_store AND snapshot_date = v_ref
               AND bucket IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED')
        )
    ) INTO v_summary;

    RETURN v_summary;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_classification(text, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
