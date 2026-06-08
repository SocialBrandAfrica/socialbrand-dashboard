-- =============================================================================
-- refresh_l2_anomaly_family3.sql
-- SB-CC-ANOM-001 Family 3 -- qualifying cascade + integrity outliers
-- =============================================================================
-- Reference   : SB-CC-ANOM-001, STOCK-TRIAGE-TOOL.md (SB-INDEX-014),
--               STOCK-CLEANUP-RULE-EVOLUTION-2026-06-08.md
-- Version     : 1.0
-- Date        : 2026-06-08
-- Depends on  : l2_anomaly_daily (create_l2_anomaly_daily.sql)
--               l2_stock_position, l2_rate_of_sale, sigma_movements,
--               sigma_ean_master, sigma_articles, sigma_supplier_link,
--               sigma_supplier_master
--
-- BEHAVIOUR
--   Deletes today's rows for the store (idempotent -- safe to re-run).
--   Inserts Family 3A rows (dead NORMAL stock, qualifying cascade).
--   Inserts Family 3B rows (integrity outliers from l2_stock_position signals).
--   Returns a JSON summary of row counts + capital by route for PM review.
--
-- QUALIFYING CASCADE ORDER (from STOCK-TRIAGE-TOOL.md SS "THE QUALIFYING CASCADE")
--   A. IDENTITY (what it IS, before asking how it behaves):
--      A1 deposit (repeated S/G) -> AMBIGUOUS (count, never TLX)
--      A2 production interim (sub-dept / dummy supplier) -> AMBIGUOUS, low conf
--      A3 non-selling consumable sub-dept -> TLX/AMBIGUOUS
--      A4 parent-child pack -> AMBIGUOUS (reconcile family, never zero)
--   B. LEDGER:
--      B5 negative SOH -> 3B integrity (suspect pool is soh>0, so only via 3B)
--   C. VERIFY PRESENCE (guardrails -- never zero anything that passes here):
--      C6 sold (any channel) after last receipt -> STOCKFLOW
--      C7 countable in StockFlow -> not implemented (no StockFlow data in DB)
--      C8 any recent movement (any channel, pos or neg, 365d) -> STOCKFLOW
--      C8b recode sibling (same desc-root, now selling) -> AMBIGUOUS
--   D. CORRECT & DECLUTTER (only survivors of C):
--      D9 phantom (SOH > ever received / never received at all) -> TLX/AMBIGUOUS
--     D10 received-then-static (no movement in window) -> TLX/AMBIGUOUS
--
-- PRODUCTION CARVE-OUT:
--   naive "sells + no receipt = production" over-fires on DSD/IBT channels.
--   A2 uses sub-dept LIKE + dummy supplier name ONLY. Confidence=0.40.
--   Always routed AMBIGUOUS. Do NOT promote to TLX until L1 decode complete.
--
-- IBT TRAP (Rule 28 in STOCK-CLEANUP-RULE-EVOLUTION):
--   ANY positive qty movement in any channel = stock arrived.
--   S/L (uppercase, DIWASOBE) = stock injection (inflow).
--   S/O (DIWASOBE) = bidirectional, decode incomplete -- treated as any-movement.
--   Before any zero: last_any_inbound must be NULL or outside the activity window.
-- =============================================================================


-- Drop old version if exists (Rule 19)
DROP FUNCTION IF EXISTS refresh_l2_anomaly_family3(text, numeric);


CREATE OR REPLACE FUNCTION refresh_l2_anomaly_family3(
    p_store         text,
    p_capital_floor numeric DEFAULT 1000.0
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     text;   -- matches source tables (text = 'socialbrand', not uuid)
    v_today         date := CURRENT_DATE;
    v_window_days   int  := 365;    -- activity window for C8 recent-movement guardrail
    v_window_active int  := 40;     -- days for "recent receipt" in phantom test
    v_3a_count      int;
    v_3b_count      int;
BEGIN

    -- -------------------------------------------------------------------------
    -- 0. Resolve client_id for this store (from l2_stock_position)
    -- -------------------------------------------------------------------------
    SELECT DISTINCT client_id
    INTO v_client_id
    FROM l2_stock_position
    WHERE store_code = p_store
    LIMIT 1;

    -- -------------------------------------------------------------------------
    -- 1. Clear today's rows for this store (idempotent)
    -- -------------------------------------------------------------------------
    DELETE FROM l2_anomaly_daily
    WHERE store_code   = p_store
      AND snapshot_date = v_today;

    -- =========================================================================
    -- FAMILY 3A: DEAD NORMAL STOCK -- qualifying cascade
    -- Suspect pool: NORMAL, soh>0, no 91d sales, capital>=floor, not cost_sanity
    -- =========================================================================
    WITH

    -- -------------------------------------------------------------------------
    -- A. Suspect pool from l2_stock_position
    -- -------------------------------------------------------------------------
    suspects AS (
        SELECT
            sp.product_code,
            sp.description,
            sp.subdept_name,
            sp.dept_name,
            sp.soh,
            sp.capital_value,
            sp.unit_cost,
            sp.daily_ros,
            sp.sales_qty_91d,
            sp.last_sale_date,
            sp.last_receipt_date,
            sp.never_sold,
            sp.signals,
            sp.class_reason,
            sp.confidence         AS sp_confidence,
            sp.supplier_nr
        FROM l2_stock_position sp
        WHERE sp.store_code      = p_store
          AND sp.class           = 'NORMAL'
          AND NOT sp.cost_sanity_flag
          AND sp.soh             > 0
          AND sp.sales_qty_91d   = 0
          AND sp.capital_value   >= p_capital_floor
    ),

    -- -------------------------------------------------------------------------
    -- B. Movement signals from sigma_movements (full history + windowed)
    --    IBT TRAP: any positive qty = inbound. S/O bidirectional = any_movement.
    -- -------------------------------------------------------------------------
    mov_signals AS (
        SELECT
            m.product_code,

            -- Deposit: repeated S/G (return-to-supplier, deposit class)
            COUNT(*) FILTER (
                WHERE m.movement_type = 'S' AND m.movement_process = 'G'
            )                                       AS deposit_sg_count,

            -- Last GRV (R/W/DIWAREPR, positive qty = stock in)
            MAX(m.movement_date) FILTER (
                WHERE m.movement_type = 'R'
                  AND m.module        = 'DIWAREPR'
                  AND m.qty           > 0
            )                                       AS last_grv_date,

            -- Last inbound: ANY positive movement (IBT trap guard)
            MAX(m.movement_date) FILTER (
                WHERE m.qty > 0
            )                                       AS last_any_inbound,

            -- Last movement of ANY kind (C8 recent-movement guardrail)
            MAX(m.movement_date)                    AS last_any_movement,

            -- Full-history: ever had a non-till movement that could explain SOH
            -- (for the "never received" phantom sub-type)
            COUNT(*) FILTER (
                WHERE m.movement_type = 'R' AND m.qty > 0
            )                                       AS total_grv_count

        FROM sigma_movements m
        WHERE m.store_code = p_store
          AND m.product_code IN (SELECT product_code FROM suspects)
        GROUP BY m.product_code
    ),

    -- -------------------------------------------------------------------------
    -- C. Barcodes from sigma_ean_master (for TLX routing)
    -- -------------------------------------------------------------------------
    barcodes AS (
        SELECT
            product_code,
            STRING_AGG(DISTINCT barcode::text, '|') AS barcode_list
        FROM sigma_ean_master
        WHERE store_code = p_store
          AND product_code IN (SELECT product_code FROM suspects)
        GROUP BY product_code
    ),

    -- -------------------------------------------------------------------------
    -- D. Parent-child pack detection (MANDATORY before any zero, Rule 18)
    --    Pack token ANYWHERE in description (not just suffix -- Rule caveat).
    --    Tokens: _N, 6PK, 12PK, 24PK, PK, C/PACK, CRATE, CASE, BOTTLE, PACK
    --    Strategy: flag articles whose description matches the pack-token regex
    --    AND a sibling article exists with the same description-root.
    -- -------------------------------------------------------------------------
    art_with_root AS (
        SELECT
            a.product_code,
            a.description,
            a.pack_content,
            -- Strip pack token(s) to derive the base description root
            TRIM(
                REGEXP_REPLACE(
                    a.description,
                    -- Match pack tokens anywhere: _N, 6PK, 12PK, 24PK, PK,
                    -- C/PACK, CRATE, CASE, BOTTLE, PACK (case-insensitive)
                    '(\s*_\d+|\s+\d{1,2}PK|\s+C\/PACK|\s+CRATE|\s+CASE'
                    '|\s+BOTTLE|\s+PACK(?:\s+\d+)?)',
                    '', 'gi'
                )
            ) AS desc_root,
            -- Is this itself a pack code?
            (a.description ~*
                '(_\d+|\s\d{1,2}PK|\sC\/PACK|\sCRATE|\sCASE|\sBOTTLE|\sPACK\s*\d*)'
            ) AS is_pack_code
        FROM sigma_articles a
        WHERE a.store_code = p_store
    ),
    -- Pack codes from suspects, with a selling sibling
    parent_child_flags AS (
        SELECT DISTINCT s.product_code
        FROM suspects       s
        JOIN art_with_root  a  ON a.product_code = s.product_code AND a.is_pack_code
        JOIN art_with_root  sib ON
              sib.product_code  <> a.product_code
          AND sib.is_pack_code  IS DISTINCT FROM TRUE            -- sibling is single
          AND sib.desc_root      = a.desc_root                   -- same family
        -- Sibling must be active (has recent sales) -- use l2_stock_position
        JOIN l2_stock_position sp_sib ON
              sp_sib.store_code   = p_store
          AND sp_sib.product_code = sib.product_code
          AND sp_sib.sales_qty_91d > 0
    ),

    -- -------------------------------------------------------------------------
    -- E. Production interim signal (sub-dept + dummy supplier; confidence=0.40)
    --    NOT production-by-no-receipt -- that over-fires on DSD/IBT channels.
    -- -------------------------------------------------------------------------
    production_interim AS (
        SELECT DISTINCT sl.product_code
        FROM sigma_supplier_link   sl
        JOIN sigma_supplier_master sm
          ON sm.store_code   = p_store
         AND sm.supplier_nr  = sl.supplier_nr
        WHERE sl.store_code  = p_store
          AND sl.product_code IN (SELECT product_code FROM suspects)
          AND (
              sm.name       ILIKE '%OWN ICE%'
           OR sm.name       ILIKE '%ALGEMEEN%'
           OR sm.name       ILIKE '%DUMMY%'
           OR sm.short_name ILIKE '%OWN%'
          )
        UNION
        -- Production sub-dept heuristic (not primary, adds confidence)
        SELECT DISTINCT sp.product_code
        FROM suspects sp
        WHERE sp.subdept_name ILIKE '%ICE%'
           OR sp.subdept_name ILIKE '%DELI%'
           OR sp.subdept_name ILIKE '%BAKERY%'
           OR sp.subdept_name ILIKE '%BUTCHERY%'
           OR sp.subdept_name ILIKE '%SPIT BRAAI%'
           OR sp.subdept_name ILIKE '%ROTISSERIE%'
           OR sp.subdept_name ILIKE '%FLAME GRILL%'
           OR sp.subdept_name ILIKE '%SUSHI%'
           OR sp.subdept_name ILIKE '%PIZZA%'
    ),

    -- -------------------------------------------------------------------------
    -- F. Recode sibling (C8b): same description-root, currently selling
    -- -------------------------------------------------------------------------
    recode_sibling AS (
        SELECT DISTINCT s.product_code
        FROM suspects       s
        JOIN art_with_root  a   ON a.product_code = s.product_code
        JOIN art_with_root  sib ON
              sib.product_code <> a.product_code
          AND sib.desc_root     = a.desc_root
        JOIN l2_stock_position sp_sib ON
              sp_sib.store_code   = p_store
          AND sp_sib.product_code = sib.product_code
          AND sp_sib.sales_qty_91d > 0
        -- Exclude parent-child (already handled in A4)
        WHERE s.product_code NOT IN (SELECT product_code FROM parent_child_flags)
    ),

    -- -------------------------------------------------------------------------
    -- G. Apply the qualifying cascade -- first match wins (A -> B -> C -> D)
    -- -------------------------------------------------------------------------
    cascade_result AS (
        SELECT
            s.product_code,
            s.description,
            s.subdept_name,
            s.dept_name,
            s.soh,
            s.capital_value,
            s.unit_cost,
            s.daily_ros,
            s.sales_qty_91d,
            s.last_sale_date,
            s.last_receipt_date,
            s.never_sold,
            s.signals,

            ms.deposit_sg_count,
            ms.last_grv_date,
            ms.last_any_inbound,
            ms.last_any_movement,
            ms.total_grv_count,

            b.barcode_list,
            b.barcode_list IS NOT NULL                      AS has_barcode,
            pc.product_code IS NOT NULL                     AS parent_child_flag,
            pi.product_code IS NOT NULL                     AS production_interim,
            rs.product_code IS NOT NULL                     AS recode_sibling_flag,

            -- ---------------------------------------------------------------
            -- THE CASCADE -- first match determines outcome
            -- ---------------------------------------------------------------
            CASE
                -- A1: Deposit (repeated S/G = crate/bottle return)
                WHEN ms.deposit_sg_count >= 2
                    THEN 'A1_DEPOSIT'

                -- A2: Production (interim signal -- low confidence)
                WHEN pi.product_code IS NOT NULL
                    THEN 'A2_PRODUCTION_INTERIM'

                -- A3: Non-selling consumable sub-dept
                --     (consumable that sells+receives = not consumable => falls through)
                WHEN s.subdept_name ILIKE '%CONSUMABLE%'
                    THEN 'A3_CONSUMABLE'

                -- A4: Parent-child pack (sibling is active)
                WHEN pc.product_code IS NOT NULL
                    THEN 'A4_PARENT_CHILD'

                -- C6: Sold after last receipt (stock demonstrably there -- slow)
                WHEN s.last_sale_date IS NOT NULL
                  AND s.last_receipt_date IS NOT NULL
                  AND s.last_sale_date > s.last_receipt_date
                    THEN 'C6_SOLD_AFTER_RECEIPT'

                -- C7: Countable in StockFlow -- not implemented (no StockFlow data)

                -- C8: Any recent movement in last 365d (IBT-trap guardrail)
                --     Conservative: any positive inbound in window = stay
                WHEN ms.last_any_movement >= v_today - v_window_days
                    THEN 'C8_RECENT_MOVEMENT'

                -- C8b: Recode sibling (same description-root is now selling)
                WHEN rs.product_code IS NOT NULL
                    THEN 'C8b_RECODE_SIBLING'

                -- D9: Phantom -- SOH exists but nothing was ever received
                --     (more on hand than can be explained; never had a GRV)
                WHEN (ms.total_grv_count IS NULL OR ms.total_grv_count = 0)
                  AND (s.last_receipt_date IS NULL)
                    THEN 'D9_PHANTOM_NEVER_RECEIVED'

                -- D10: Received-then-static -- had a receipt but no activity since
                ELSE 'D10_DECLUTTER'
            END                                             AS cascade_step

        FROM suspects           s
        LEFT JOIN mov_signals   ms ON ms.product_code = s.product_code
        LEFT JOIN barcodes      b  ON b.product_code  = s.product_code
        LEFT JOIN parent_child_flags pc ON pc.product_code = s.product_code
        LEFT JOIN production_interim pi ON pi.product_code = s.product_code
        LEFT JOIN recode_sibling     rs ON rs.product_code = s.product_code
    ),

    -- -------------------------------------------------------------------------
    -- H. Derive route + anomaly_type + confidence from cascade_step
    -- -------------------------------------------------------------------------
    routed AS (
        SELECT
            c.*,

            CASE c.cascade_step
                WHEN 'A1_DEPOSIT'             THEN 'DEPOSIT'
                WHEN 'A2_PRODUCTION_INTERIM'  THEN 'PRODUCTION_INTERIM'
                WHEN 'A3_CONSUMABLE'          THEN 'CONSUMABLE'
                WHEN 'A4_PARENT_CHILD'        THEN 'PARENT_CHILD'
                WHEN 'C6_SOLD_AFTER_RECEIPT'  THEN 'DEAD_STOCK'
                WHEN 'C8_RECENT_MOVEMENT'     THEN 'DEAD_STOCK'
                WHEN 'C8b_RECODE_SIBLING'     THEN 'DEAD_STOCK'
                WHEN 'D9_PHANTOM_NEVER_RECEIVED' THEN 'PHANTOM_SUSPECT'
                WHEN 'D10_DECLUTTER'          THEN 'DEAD_STOCK'
                ELSE 'DEAD_STOCK'
            END                                             AS anomaly_type,

            CASE c.cascade_step
                -- A-class: never auto-zero; manual or StockFlow required
                WHEN 'A1_DEPOSIT'             THEN 'AMBIGUOUS'
                WHEN 'A2_PRODUCTION_INTERIM'  THEN 'AMBIGUOUS'
                WHEN 'A3_CONSUMABLE'          THEN
                    CASE WHEN c.has_barcode THEN 'TLX_ZERO' ELSE 'AMBIGUOUS' END
                WHEN 'A4_PARENT_CHILD'        THEN 'AMBIGUOUS'
                -- C-class: stock is reasonably expected to be there
                WHEN 'C6_SOLD_AFTER_RECEIPT'  THEN 'STOCKFLOW'
                WHEN 'C8_RECENT_MOVEMENT'     THEN 'STOCKFLOW'
                WHEN 'C8b_RECODE_SIBLING'     THEN 'AMBIGUOUS'
                -- D-class: zeroable if barcode available
                WHEN 'D9_PHANTOM_NEVER_RECEIVED' THEN
                    CASE WHEN c.has_barcode THEN 'TLX_ZERO' ELSE 'AMBIGUOUS' END
                WHEN 'D10_DECLUTTER'          THEN
                    CASE WHEN c.has_barcode THEN 'TLX_ZERO' ELSE 'AMBIGUOUS' END
                ELSE 'AMBIGUOUS'
            END                                             AS route,

            CASE c.cascade_step
                WHEN 'A1_DEPOSIT'             THEN 0.92
                WHEN 'A2_PRODUCTION_INTERIM'  THEN 0.40  -- interim signal only
                WHEN 'A3_CONSUMABLE'          THEN 0.85
                WHEN 'A4_PARENT_CHILD'        THEN 0.88
                WHEN 'C6_SOLD_AFTER_RECEIPT'  THEN 0.90
                WHEN 'C8_RECENT_MOVEMENT'     THEN 0.80
                WHEN 'C8b_RECODE_SIBLING'     THEN 0.75
                WHEN 'D9_PHANTOM_NEVER_RECEIVED' THEN 0.95
                WHEN 'D10_DECLUTTER'          THEN
                    -- Higher confidence when truly dead (never sold, no receipt)
                    CASE WHEN c.never_sold AND (c.total_grv_count > 0)
                         THEN 0.92
                         ELSE 0.78
                    END
                ELSE 0.60
            END                                             AS confidence,

            -- Human-readable evidence (R22)
            CASE c.cascade_step
                WHEN 'A1_DEPOSIT' THEN
                    'Deposit/crate: ' || c.deposit_sg_count::text
                    || ' S/G (return-to-supplier) movements detected. '
                    || 'Must be counted, never auto-zeroed.'
                WHEN 'A2_PRODUCTION_INTERIM' THEN
                    'Production (INTERIM -- low confidence): matched dummy/own-factory '
                    || 'supplier OR production sub-dept (' || c.subdept_name || '). '
                    || 'Route AMBIGUOUS pending L1 movement-channel decode (SB-CC-L1-001). '
                    || 'Do NOT promote to TLX without confirming no DSD/IBT receipts.'
                WHEN 'A3_CONSUMABLE' THEN
                    'Consumable sub-dept, no sales. SOH=' || c.soh::text
                    || ' capital=R' || ROUND(c.capital_value, 0)::text || '.'
                WHEN 'A4_PARENT_CHILD' THEN
                    'Pack code detected (description contains pack token). '
                    || 'Sibling single-code is actively selling. '
                    || 'Reconcile pack/single family before any action.'
                WHEN 'C6_SOLD_AFTER_RECEIPT' THEN
                    'Sold after last receipt: last_sale=' || c.last_sale_date::text
                    || ' > last_receipt=' || c.last_receipt_date::text
                    || '. Stock is there but slow. Reorder or range review.'
                WHEN 'C8_RECENT_MOVEMENT' THEN
                    'Recent movement in last ' || v_window_days::text || 'd: '
                    || COALESCE('last_any=' || c.last_any_movement::text, 'unknown')
                    || '. Any positive inbound='
                    || COALESCE(c.last_any_inbound::text, 'none') || '. '
                    || 'IBT trap: stock may have arrived via non-receipt channel.'
                WHEN 'C8b_RECODE_SIBLING' THEN
                    'Recode suspected: sibling with same description-root is selling. '
                    || 'Reconcile product codes before any zero (Rule 26).'
                WHEN 'D9_PHANTOM_NEVER_RECEIVED' THEN
                    'Phantom: SOH=' || c.soh::text
                    || ' but NO GRV receipt ever found in sigma_movements. '
                    || 'Stock on books but never booked in -- likely phantom or opening-balance error.'
                WHEN 'D10_DECLUTTER' THEN
                    'Static dead stock: never_sold=' || COALESCE(c.never_sold::text, 'unknown')
                    || ' last_receipt=' || COALESCE(c.last_receipt_date::text, 'never')
                    || ' last_movement=' || COALESCE(c.last_any_movement::text, 'never')
                    || '. No inbound in ' || v_window_days::text || 'd. Safe to declutter.'
                ELSE
                    'Cascade step: ' || c.cascade_step
            END                                             AS evidence

        FROM cascade_result c
    )

    -- -------------------------------------------------------------------------
    -- I. Insert Family 3A rows
    -- -------------------------------------------------------------------------
    INSERT INTO l2_anomaly_daily (
        client_id, store_code, product_code, snapshot_date,
        family, anomaly_type, route, cascade_step,
        description, subdept_name, dept_name,
        soh, capital_value, unit_cost, daily_ros, sales_qty_91d,
        last_sale_date, last_receipt_date, never_sold, has_barcode,
        deposit_sg_count, last_grv_date, last_any_inbound, last_any_movement,
        parent_child_flag, production_interim,
        confidence, evidence, signals_snapshot,
        status, detected_at
    )
    SELECT
        v_client_id, p_store, r.product_code, v_today,
        '3A', r.anomaly_type, r.route, r.cascade_step,
        r.description, r.subdept_name, r.dept_name,
        r.soh, r.capital_value, r.unit_cost, r.daily_ros, r.sales_qty_91d,
        r.last_sale_date, r.last_receipt_date, r.never_sold, r.has_barcode,
        r.deposit_sg_count, r.last_grv_date, r.last_any_inbound, r.last_any_movement,
        r.parent_child_flag, r.production_interim,
        r.confidence, r.evidence,
        ARRAY_TO_STRING(r.signals, ', '),
        'OPEN', now()
    FROM routed r;

    GET DIAGNOSTICS v_3a_count = ROW_COUNT;

    -- =========================================================================
    -- FAMILY 3B: INTEGRITY OUTLIERS (from l2_stock_position signals)
    -- Separate from 3A -- these are all classes, not just NORMAL.
    -- =========================================================================
    INSERT INTO l2_anomaly_daily (
        client_id, store_code, product_code, snapshot_date,
        family, anomaly_type, cascade_step,
        description, subdept_name, dept_name,
        soh, capital_value, unit_cost, daily_ros, sales_qty_91d,
        last_sale_date, last_receipt_date, never_sold,
        confidence, evidence, signals_snapshot,
        status, detected_at
    )
    SELECT
        v_client_id,
        p_store,
        sp.product_code,
        v_today,
        '3B',
        -- anomaly_type per signal (one row per signal per product)
        signal_type.label,
        -- cascade_step not applicable for 3B
        'B5_' || signal_type.label,
        sp.description,
        sp.subdept_name,
        sp.dept_name,
        sp.soh,
        sp.capital_value,
        sp.unit_cost,
        sp.daily_ros,
        sp.sales_qty_91d,
        sp.last_sale_date,
        sp.last_receipt_date,
        sp.never_sold,
        0.99,   -- integrity signals are deterministic
        signal_type.label || ': class=' || sp.class
            || ' soh=' || ROUND(sp.soh::numeric, 0)::text
            || ' capital=R' || ROUND(sp.capital_value::numeric, 0)::text
            || ' signals=[' || ARRAY_TO_STRING(sp.signals, ',') || ']',
        ARRAY_TO_STRING(sp.signals, ', '),
        'OPEN',
        now()
    FROM l2_stock_position sp
    CROSS JOIN (VALUES
        ('NEGATIVE_SOH'),
        ('COST_SANITY'),
        ('STALE_LEDGER'),
        ('INVESTIGATE_STOCK')
    ) AS signal_type(label)
    WHERE sp.store_code = p_store
      AND (
          (signal_type.label = 'NEGATIVE_SOH'      AND sp.neg_soh_signal)
       OR (signal_type.label = 'COST_SANITY'       AND sp.cost_sanity_flag)
       OR (signal_type.label = 'STALE_LEDGER'      AND sp.stale_ledger_flag)
       OR (signal_type.label = 'INVESTIGATE_STOCK' AND sp.investigate_stock_flag)
      )
    ON CONFLICT (store_code, product_code, snapshot_date, anomaly_type)
        DO NOTHING;  -- 3B product_code might also appear in 3A; avoid duplicate anomaly_type

    GET DIAGNOSTICS v_3b_count = ROW_COUNT;

    -- =========================================================================
    -- Return summary for PM review
    -- =========================================================================
    RETURN (
        SELECT jsonb_build_object(
            'store',        p_store,
            'snapshot_date', v_today,
            'capital_floor', p_capital_floor,
            '3A_total',     v_3a_count,
            '3B_total',     v_3b_count,
            'by_route', (
                SELECT jsonb_object_agg(
                    COALESCE(route, 'NULL'),
                    jsonb_build_object(
                        'rows',    cnt,
                        'capital', capital
                    )
                )
                FROM (
                    SELECT
                        route,
                        COUNT(*)                                AS cnt,
                        ROUND(SUM(capital_value)::numeric, 0)   AS capital
                    FROM l2_anomaly_daily
                    WHERE store_code    = p_store
                      AND snapshot_date = v_today
                      AND family        = '3A'
                    GROUP BY route
                ) r
            ),
            'by_type', (
                SELECT jsonb_object_agg(
                    anomaly_type,
                    jsonb_build_object(
                        'rows',    cnt,
                        'capital', capital
                    )
                )
                FROM (
                    SELECT
                        anomaly_type,
                        COUNT(*)                                AS cnt,
                        ROUND(SUM(capital_value)::numeric, 0)   AS capital
                    FROM l2_anomaly_daily
                    WHERE store_code    = p_store
                      AND snapshot_date = v_today
                    GROUP BY anomaly_type
                ) t
            )
        )
    );

END;
$$;


COMMENT ON FUNCTION refresh_l2_anomaly_family3(text, numeric) IS
    'Populates l2_anomaly_daily for one store. '
    'Family 3A: qualifying cascade (A identity->B ledger->C verify->D declutter) '
    'on dead NORMAL stock (soh>0, no 91d sales, capital>=floor). '
    'Family 3B: integrity outliers (neg_soh, cost_sanity, stale_ledger, investigate_stock). '
    'Idempotent: deletes and re-inserts today''s rows. '
    'Returns JSON summary for PM review before multi-store. '
    'SB-CC-ANOM-001 Family 3, STOCK-TRIAGE-TOOL.md cascade.';


GRANT EXECUTE ON FUNCTION refresh_l2_anomaly_family3(text, numeric) TO authenticated;


-- =============================================================================
-- STEP 1: Run the function on 10116 (PM review before multi-store)
-- =============================================================================
-- SELECT refresh_l2_anomaly_family3('10116');
--
-- STEP 2: Detailed review query
-- =============================================================================
-- SELECT
--     family,
--     anomaly_type,
--     route,
--     COUNT(*)                                             AS rows,
--     ROUND(SUM(capital_value)::numeric, 0)                AS total_capital_r,
--     ROUND(AVG(confidence)::numeric, 2)                   AS avg_confidence,
--     ROUND(AVG(soh)::numeric, 1)                          AS avg_soh,
--     COUNT(*) FILTER (WHERE never_sold)                   AS never_sold_count,
--     COUNT(*) FILTER (WHERE parent_child_flag)            AS parent_child_count
-- FROM l2_anomaly_daily
-- WHERE store_code    = '10116'
--   AND snapshot_date = CURRENT_DATE
-- GROUP BY family, anomaly_type, route
-- ORDER BY family, total_capital_r DESC;
--
-- STEP 3: Top capital items by route (show Pieter the biggest lines)
-- =============================================================================
-- SELECT
--     route, cascade_step, product_code, description, subdept_name,
--     soh, ROUND(capital_value::numeric, 0) AS capital_r,
--     last_sale_date, last_receipt_date, never_sold, has_barcode,
--     ROUND(confidence::numeric, 2) AS conf,
--     evidence
-- FROM l2_anomaly_daily
-- WHERE store_code    = '10116'
--   AND snapshot_date = CURRENT_DATE
--   AND family        = '3A'
-- ORDER BY route, capital_value DESC
-- LIMIT 50;
-- =============================================================================
