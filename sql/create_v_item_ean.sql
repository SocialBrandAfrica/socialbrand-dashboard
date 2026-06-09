-- =============================================================================
-- create_v_item_ean.sql
-- SocialBrand Intelligence Platform -- Reconciled EAN / PLU signal
-- =============================================================================
-- Version  : 1.0
-- Date     : 2026-06-09
-- Ref      : SB-CC-L1-EAN-COMPLETENESS, CLEANUP-ENGINE-CANON (SB-INDEX-016)
-- Owner    : CC (Claude Code); PM sign-off before multi-store rollout
--
-- WHAT THIS IS
--   Single authoritative view: one row per article (client_id, store_code,
--   product_code).  Reconciles:
--     - sigma_ean_master : GS1 barcodes extracted from IntellistoX_EAN_Master
--                          (fixed in extractor v1.7: barcode stored as text,
--                          no float-truncation of trailing digit)
--     - sigma_articles   : PLU flag (cPLU='1') and scale flag (cWAG='1') from
--                          DBARTS -- confirmed made-in-store / scale items that
--                          have no GS1 barcode by design
--
--   Every in-scope article resolves to exactly one of:
--     has_barcode = TRUE          -- real GS1 barcode available for TLX generation
--     is_confirmed_plu = TRUE     -- no GS1 barcode, but Sigma confirms PLU/scale
--     both FALSE                  -- genuine data gap (ambiguous, never auto-zero)
--
-- ENGINE READS THIS VIEW
--   refresh_l2_anomaly_family3 reads v_item_ean in the 'barcodes' CTE.
--   has_barcode drives TLX_ZERO vs AMBIGUOUS routing (cascade steps D9/D10).
--   is_confirmed_plu surfaces confirmed PLU lines for SOURCE-FIX / audit.
--
-- RETIRING
--   The old product_catalog + sigma_ean_master coalesce and the
--   length/prefix heuristic (len=13 / starts_with='6') are retired.
--   This view is the ONLY EAN source the engine reads (R22, SB-CC-L1-EAN).
--
-- HOW TO RUN
--   Run this file once.  The view is rebuilt live on each query so it always
--   reflects the current state of sigma_ean_master and sigma_articles.
--   No nightly refresh needed -- it reads the L1 tables directly.
-- =============================================================================


-- Rule 19: DROP first, then clean CREATE
DROP VIEW IF EXISTS v_item_ean;


CREATE VIEW v_item_ean AS
SELECT
    a.client_id,
    a.store_code,
    a.product_code,

    -- Pipe-separated barcode list (NULL when no EAN record exists)
    -- Multiple rows per article are possible (EAN-13 + ITF-14 etc.)
    -- Sorted by sorter ASC (primary designation first)
    em.barcode_list,

    -- TRUE when at least one barcode row exists in sigma_ean_master
    em.barcode_list IS NOT NULL                                 AS has_barcode,

    -- TRUE when no GS1 barcode AND Sigma flags this as PLU/scale.
    -- These items legitimately have no GS1 barcode (made-in-store / sold
    -- by weight). plu_flag='1' (cPLU) = PLU item. scale_flag='1' (cWAG)
    -- = scale item.  Either flag alone is sufficient.
    (em.barcode_list IS NULL
     AND (a.plu_flag = '1' OR a.scale_flag = '1'))             AS is_confirmed_plu

FROM sigma_articles a
LEFT JOIN (
    SELECT
        client_id,
        store_code,
        product_code,
        STRING_AGG(barcode, '|' ORDER BY sorter ASC, barcode)  AS barcode_list
    FROM sigma_ean_master
    GROUP BY client_id, store_code, product_code
) em ON  em.client_id    = a.client_id
     AND em.store_code   = a.store_code
     AND em.product_code = a.product_code;


COMMENT ON VIEW v_item_ean IS
    'Reconciled EAN / PLU signal. One row per article. '
    'has_barcode=TRUE: real GS1 barcode in sigma_ean_master (text, untruncated). '
    'is_confirmed_plu=TRUE: no GS1 barcode, Sigma cPLU=1 or cWAG=1 (scale/made-in-store). '
    'Reads sigma_ean_master (extractor v1.7+) and sigma_articles. '
    'Engine reads this view -- never joins sigma_ean_master directly. '
    'Ref: SB-CC-L1-EAN-COMPLETENESS, CLEANUP-ENGINE-CANON SB-INDEX-016.';


GRANT SELECT ON v_item_ean TO anon, authenticated;


-- =============================================================================
-- COVERAGE AUDIT (run after extractor v1.7 has pushed):
-- =============================================================================
--
-- Per-store resolution breakdown:
-- SELECT
--     store_code,
--     COUNT(*)                                        AS total_articles,
--     COUNT(*) FILTER (WHERE has_barcode)             AS with_barcode,
--     COUNT(*) FILTER (WHERE is_confirmed_plu)        AS confirmed_plu,
--     COUNT(*) FILTER (WHERE NOT has_barcode
--                        AND NOT is_confirmed_plu)    AS unresolved
-- FROM v_item_ean
-- GROUP BY store_code
-- ORDER BY store_code;
--
-- Spot-check:
-- SELECT store_code, product_code, barcode_list, has_barcode, is_confirmed_plu
-- FROM v_item_ean
-- WHERE store_code = '10116'
--   AND product_code IN (
--       SELECT product_code FROM sigma_articles
--       WHERE description ILIKE '%B&H SPECIAL RED%'
--          OR description ILIKE '%SCOTTISH LEADER%'
--          OR description ILIKE '%INVERROCHE GIN%'
--   );
-- =============================================================================
