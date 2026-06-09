-- =============================================================================
-- refresh_l2_stock_count_plan.sql
-- SB-CC-FAMILY3-COUNT-ENGINE-001 -- count-plan engine
-- =============================================================================
-- Reference   : SB-CC-FAMILY3-COUNT-ENGINE-001 (PM + CC layers)
--               STOCK-TRIAGE-TOOL.md (SB-INDEX-014)
--               SIGMA-CLEANUP-WORKFLOW.md (SB-INDEX-015)
-- Version     : 1.0
-- Date        : 2026-06-09
-- Depends on  : l2_stock_count_plan (create_l2_stock_count_plan.sql)
--               l2_stock_position, sigma_articles, sigma_ean_master
--
-- BEHAVIOUR
--   Deletes today's rows for the store (idempotent -- safe to re-run).
--   Inserts ALL in-scope lines including HEALTHY (pool must reconcile).
--   Returns JSONB summary: store, snapshot_date, pool_total, by_bucket.
--
-- GATE (Step 1 of brief):
--   l2_stock_position WHERE class='NORMAL' AND soh<>0 (includes negatives)
--   JOINED to sigma_articles (product must exist in Sigma at this store)
--   NO capital_value threshold. Floor = R0. Always.
--
-- SIGNAL COMPUTATION (Step 2):
--   sold_91d      = last_sale_date >= CURRENT_DATE-91 (and > 1990-01-01)
--   recv_365d     = last_receipt_date >= CURRENT_DATE-365 (and > 1990-01-01)
--   deposit_like  = description/subdept_name heuristic (BOTTLE/CRATE/RETURN/
--                   EMPTIES/EMPTY/DEPOSIT/DEP) -- pending full S/G decode
--   barcode_list  = pipe-separated EANs from sigma_ean_master; NULL = no barcode
--
-- CASCADE (Step 3 -- order matters, first matching branch wins):
--   1. deposit_like                                     -> AMBIGUOUS
--   2. sold_91d AND soh > 0                            -> HEALTHY
--   3. sold_91d AND soh < 0                            -> AMBIGUOUS
--   4. NOT sold_91d AND recv_365d                      -> STOCKFLOW
--   5. NOT sold_91d AND NOT recv_365d AND barcode_list IS NOT NULL -> TLX
--   6. else                                            -> AMBIGUOUS
--
-- HARD RULES (Step 4):
--   - No STOCKFLOW row should have NULL barcode_list (recycled-code risk).
--     The function logs a WARNING in the JSONB if this occurs.
--   - AMBIGUOUS rows with deposit_like=true are NEVER auto-zeroed. Manual only.
--   - Cost errors (cost_sanity_flag) are NOT in this pool -- handled by
--     l2_anomaly_daily Family 3B. This engine only sees clean l2_stock_position.
--
-- NO p_capital_floor PARAMETER -- EVER.
--   This is enforced by function signature. Any patch adding a floor parameter
--   is a rule violation (Pieter's law: value is never a rule).
--
-- DETERMINISM TEST:
--   Call twice in the same session with no data changes between calls.
--   The returned JSONB must be byte-for-byte identical both times.
--   A non-identical result is a nondeterminism bug -- block ship until resolved.
-- =============================================================================


-- Drop old version if exists (Rule 19)
DROP FUNCTION IF EXISTS refresh_l2_stock_count_plan(text);


CREATE OR REPLACE FUNCTION refresh_l2_stock_count_plan(
    p_store     text
    -- NO p_capital_floor parameter. Floor = R0. Pieter's law.
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id          text;
    v_today              date := CURRENT_DATE;
    v_pool_total         int;
    v_no_barcode_sf      int  := 0;   -- STOCKFLOW rows without barcode (recycled-code alert)
BEGIN

    -- -------------------------------------------------------------------------
    -- 0. Resolve client_id for this store
    -- -------------------------------------------------------------------------
    SELECT DISTINCT client_id
    INTO v_client_id
    FROM l2_stock_position
    WHERE store_code = p_store
    LIMIT 1;

    -- -------------------------------------------------------------------------
    -- 1. Clear today's rows for this store (idempotent -- safe to re-run)
    -- -------------------------------------------------------------------------
    DELETE FROM l2_stock_count_plan
    WHERE store_code    = p_store
      AND snapshot_date = v_today;


    -- =========================================================================
    -- 2. Compute signals + apply cascade + insert all in-scope rows
    --
    --    Gate: NORMAL + soh<>0 + exists in sigma_articles at this store.
    --    All matching rows are inserted, including HEALTHY.
    --    pool_total must equal sum of all four bucket counts.
    -- =========================================================================
    WITH

    -- -------------------------------------------------------------------------
    -- A. In-scope pool with routing signals
    -- -------------------------------------------------------------------------
    in_scope AS (
        SELECT
            sp.product_code,
            sp.description,
            sp.subdept_name,
            sp.dept_name,
            sp.soh,
            sp.capital_value,
            sp.unit_cost,
            sp.last_sale_date,
            sp.last_receipt_date,

            -- sold_91d: had a till sale within 91 days (1990-01-01 = never-sold sentinel)
            (   sp.last_sale_date >= v_today - 91
            AND sp.last_sale_date  > '1990-01-01'::date
            )                                               AS sold_91d,

            -- recv_365d: had a GRV/receipt within 365 days (1990-01-01 = never sentinel)
            (   sp.last_receipt_date >= v_today - 365
            AND sp.last_receipt_date  > '1990-01-01'::date
            )                                               AS recv_365d,

            -- deposit_like: description OR subdept heuristic for crate/bottle/deposit.
            -- Pending full precision via S/G movement count (L1-001 S/O decode).
            -- Routes AMBIGUOUS regardless of sold_91d -- never stocktake-zero a deposit.
            (   sp.description  ILIKE '%BOTTLE%'
            OR  sp.description  ILIKE '%CRATE%'
            OR  sp.description  ILIKE '%RETURN%'
            OR  sp.description  ILIKE '%EMPTIES%'
            OR  sp.description  ILIKE '%EMPTY%'
            OR  sp.description  ILIKE '%DEPOSIT%'
            OR  sp.description  ILIKE '% DEP %'
            OR  sp.description  ILIKE '% DEP'
            OR  sp.description  ILIKE 'DEP %'
            OR  sp.description   =    'DEP'
            OR  sp.description  ILIKE '%BOTTLE CHARGE%'
            OR  sp.subdept_name ILIKE '%BOTTLE%'
            OR  sp.subdept_name ILIKE '%CRATE%'
            OR  sp.subdept_name ILIKE '%RETURN%'
            OR  sp.subdept_name ILIKE '%EMPTIES%'
            OR  sp.subdept_name ILIKE '%EMPTY%'
            OR  sp.subdept_name ILIKE '%DEPOSIT%'
            OR  sp.subdept_name ILIKE '% DEP %'
            OR  sp.subdept_name ILIKE '% DEP'
            OR  sp.subdept_name ILIKE 'DEP %'
            OR  sp.subdept_name  =    'DEP'
            OR  sp.subdept_name ILIKE '%BOTTLE CHARGE%'
            )                                               AS deposit_like

        FROM l2_stock_position sp
        JOIN sigma_articles a
          ON a.store_code   = sp.store_code
         AND a.product_code = sp.product_code
        WHERE sp.store_code = p_store
          AND sp.class      = 'NORMAL'
          AND sp.soh        <> 0          -- includes negatives; soh=0 is out of scope
    ),

    -- -------------------------------------------------------------------------
    -- B. Barcodes from sigma_ean_master
    --    NULL barcode_list = no EAN registered -> bucket forced to AMBIGUOUS.
    --    Barcode is the ONLY safe Sigma<->StockFlow key (recycled-code guard).
    --    product_codes are reused in Sigma; barcode from sigma_ean_master is stable.
    -- -------------------------------------------------------------------------
    barcodes AS (
        SELECT
            em.product_code,
            STRING_AGG(DISTINCT em.barcode::text, '|') AS barcode_list
        FROM sigma_ean_master em
        WHERE em.store_code  = p_store
          AND em.product_code IN (SELECT product_code FROM in_scope)
        GROUP BY em.product_code
    ),

    -- -------------------------------------------------------------------------
    -- C. Apply deterministic cascade (order is fixed -- first branch wins).
    --    See Step 3 of SB-CC-FAMILY3-COUNT-ENGINE-001 brief.
    -- -------------------------------------------------------------------------
    routed AS (
        SELECT
            s.product_code,
            s.description,
            s.subdept_name,
            s.dept_name,
            s.soh,
            s.capital_value,
            s.unit_cost,
            s.last_sale_date,
            s.last_receipt_date,
            s.sold_91d,
            s.recv_365d,
            s.deposit_like,
            b.barcode_list,

            CASE
                -- Branch 1: deposit/crate/empties -> AMBIGUOUS (never auto-zero)
                WHEN s.deposit_like
                    THEN 'AMBIGUOUS'

                -- Branch 2: selling + positive SOH -> HEALTHY (no action)
                WHEN s.sold_91d AND s.soh > 0
                    THEN 'HEALTHY'

                -- Branch 3: selling + NEGATIVE SOH -> AMBIGUOUS (receiving gap)
                WHEN s.sold_91d AND s.soh < 0
                    THEN 'AMBIGUOUS'

                -- Branch 4: not selling, but received within 365d -> STOCKFLOW
                --   (stock is expected; physical count required, never auto-zero)
                WHEN NOT s.sold_91d AND s.recv_365d
                    THEN 'STOCKFLOW'

                -- Branch 5: dead + barcode confirmed -> TLX (safe auto-zero)
                WHEN NOT s.sold_91d AND NOT s.recv_365d AND b.barcode_list IS NOT NULL
                    THEN 'TLX'

                -- Branch 6 (else): no barcode, no movement, no sale -> AMBIGUOUS
                --   Cannot TLX without EAN; cannot StockFlow-key safely.
                --   Action: supply EAN in Sigma first, then re-run.
                ELSE 'AMBIGUOUS'
            END                                 AS bucket,

            CASE
                WHEN s.deposit_like
                    THEN 'Deposit/crate/empties -- manual count, never auto-zero.'
                WHEN s.sold_91d AND s.soh > 0
                    THEN NULL   -- HEALTHY: no action, no reason text needed
                WHEN s.sold_91d AND s.soh < 0
                    THEN 'Selling but negative SOH -- receiving-gap; count/GRV, never blind-zero.'
                WHEN NOT s.sold_91d AND s.recv_365d
                    THEN 'Active: last receipt <365d. Stock expected; physical count required.'
                WHEN NOT s.sold_91d AND NOT s.recv_365d AND b.barcode_list IS NOT NULL
                    THEN 'Dead: no sale 91d, no receipt 365d, barcode confirmed. Safe auto-zero.'
                ELSE
                    'No barcode in sigma_ean_master -- cannot TLX or StockFlow-key; supply EAN in Sigma.'
            END                                 AS bucket_reason

        FROM in_scope s
        LEFT JOIN barcodes b ON b.product_code = s.product_code
    )

    -- -------------------------------------------------------------------------
    -- D. Insert all rows -- HEALTHY included (pool must reconcile to total)
    -- -------------------------------------------------------------------------
    INSERT INTO l2_stock_count_plan (
        client_id,
        store_code,
        product_code,
        snapshot_date,
        description,
        subdept_name,
        dept_name,
        soh,
        capital_value,
        unit_cost,
        last_sale_date,
        last_receipt_date,
        barcode_list,
        sold_91d,
        recv_365d,
        deposit_like,
        bucket,
        bucket_reason
    )
    SELECT
        v_client_id,
        p_store,
        r.product_code,
        v_today,
        r.description,
        r.subdept_name,
        r.dept_name,
        r.soh,
        r.capital_value,
        r.unit_cost,
        r.last_sale_date,
        r.last_receipt_date,
        r.barcode_list,
        r.sold_91d,
        r.recv_365d,
        r.deposit_like,
        r.bucket,
        r.bucket_reason
    FROM routed r;

    GET DIAGNOSTICS v_pool_total = ROW_COUNT;


    -- -------------------------------------------------------------------------
    -- 3. Recycled-code guard: check for STOCKFLOW rows without barcode.
    --    Any such row is a risk -- the StockFlow export cannot safely key it.
    --    Surface in the JSONB summary so PM/CC can investigate.
    -- -------------------------------------------------------------------------
    SELECT COUNT(*) INTO v_no_barcode_sf
    FROM l2_stock_count_plan
    WHERE store_code    = p_store
      AND snapshot_date  = v_today
      AND bucket         = 'STOCKFLOW'
      AND barcode_list  IS NULL;


    -- -------------------------------------------------------------------------
    -- 4. Return JSONB summary (by_bucket: rows + capital per bucket)
    -- -------------------------------------------------------------------------
    RETURN (
        SELECT jsonb_build_object(
            'store',              p_store,
            'snapshot_date',      v_today,
            'pool_total',         v_pool_total,
            'no_barcode_sf_alert', v_no_barcode_sf,   -- >0 = recycled-code risk, investigate
            'by_bucket', (
                SELECT jsonb_object_agg(
                    bucket,
                    jsonb_build_object(
                        'rows',    rows,
                        'capital', capital
                    )
                )
                FROM (
                    SELECT
                        bucket,
                        COUNT(*)                               AS rows,
                        ROUND(SUM(capital_value)::numeric, 0) AS capital
                    FROM l2_stock_count_plan
                    WHERE store_code    = p_store
                      AND snapshot_date  = v_today
                    GROUP BY bucket
                ) s
            )
        )
    );

END;
$$;


COMMENT ON FUNCTION refresh_l2_stock_count_plan(text) IS
    'Refresh l2_stock_count_plan for one store. '
    'Gate: NORMAL + soh<>0 + sigma_articles JOIN. No capital floor. '
    'Cascade: deposit_like->AMBIGUOUS / sold+pos->HEALTHY / sold+neg->AMBIGUOUS / '
    'recv->STOCKFLOW / dead+barcode->TLX / else->AMBIGUOUS. '
    'Returns JSONB: pool_total, by_bucket (rows+capital), no_barcode_sf_alert. '
    'Idempotent: DELETE today then INSERT. Run twice same session = same JSONB. '
    'SB-CC-FAMILY3-COUNT-ENGINE-001. R21 + R22 compliant.';


GRANT EXECUTE ON FUNCTION refresh_l2_stock_count_plan(text) TO authenticated;


-- =============================================================================
-- DEPLOY STEPS (run in this order in Supabase SQL Editor):
--
--   Step 1: Run create_l2_stock_count_plan.sql (this creates the table).
--   Step 2: Run refresh_l2_stock_count_plan.sql (this file -- creates the function).
--   Step 3: Run on one store and verify:
--
--     SELECT refresh_l2_stock_count_plan('21355');
--
--   Step 4: Pool reconciliation check:
--     SELECT bucket, COUNT(*) AS rows,
--            ROUND(SUM(capital_value)::numeric, 0) AS capital_r
--     FROM l2_stock_count_plan
--     WHERE store_code = '21355' AND snapshot_date = CURRENT_DATE
--     GROUP BY bucket ORDER BY rows DESC;
--
--   Step 5: Determinism self-test (run the same refresh again, compare JSONB):
--     SELECT refresh_l2_stock_count_plan('21355');
--     -- Must return the same pool_total and by_bucket counts as Step 3.
--
--   Step 6: Golden baseline check (PM canonical 2026-06-09):
--     21355 TOPS Dela: pool=948  HEALTHY=708  STOCKFLOW=111  TLX=75   AMBIGUOUS=54
--     80176 TOPS Roos: pool=863  HEALTHY=622  STOCKFLOW=112  TLX=84   AMBIGUOUS=45
--     80579 TOPS Dice: pool=775  HEALTHY=478  STOCKFLOW=111  TLX=122  AMBIGUOUS=64
--     If AMBIGUOUS diverges by >40 rows, check the deposit_like filter patterns.
--
--   Step 7 (after PM review): extend to all stores:
--     SELECT refresh_l2_stock_count_plan('10116');
--     SELECT refresh_l2_stock_count_plan('80175');
--     SELECT refresh_l2_stock_count_plan('80176');
--     SELECT refresh_l2_stock_count_plan('80579');
--
-- OUTPUT ARTIFACT QUERIES:
--
--   StockFlow CSV (product_code only, capital descending):
--     SELECT product_code, description, soh, capital_value, barcode_list
--     FROM l2_stock_count_plan
--     WHERE store_code = '21355' AND snapshot_date = CURRENT_DATE
--       AND bucket = 'STOCKFLOW'
--     ORDER BY capital_value DESC;
--
--   TLX file (pipe-split barcodes for file generator):
--     SELECT product_code, barcode_list, description, soh
--     FROM l2_stock_count_plan
--     WHERE store_code = '21355' AND snapshot_date = CURRENT_DATE
--       AND bucket = 'TLX'
--     ORDER BY capital_value DESC;
--
--   Ambiguous triage list (manual review, capital descending):
--     SELECT product_code, description, subdept_name, soh, capital_value,
--            last_sale_date, last_receipt_date, deposit_like, bucket_reason
--     FROM l2_stock_count_plan
--     WHERE store_code = '21355' AND snapshot_date = CURRENT_DATE
--       AND bucket = 'AMBIGUOUS'
--     ORDER BY capital_value DESC;
-- =============================================================================
