-- =============================================================================
-- create_v_item_ean.sql
-- SocialBrand Intelligence Platform -- Reconciled EAN / PLU signal
-- =============================================================================
-- Version  : 2.0
-- Date     : 2026-06-11
-- Ref      : SB-CC-L1-EAN-COMPLETENESS, SB-CC-SOURCE-001 (R25),
--            CLEANUP-ENGINE-CANON (SB-INDEX-016)
-- Owner    : CC (Claude Code); PM ruling 2026-06-11 18:50
--
-- !! DEPLOYMENT GATE: run ONLY after sigma_scan_refs has data on all 5 stores
-- !! (first fill = extractor v1.11, expected nightly push 2026-06-11 ~21:00).
-- !! Deploying against an empty sigma_scan_refs makes has_barcode=FALSE
-- !! everywhere. Verify first:
-- !!   SELECT store_code, COUNT(*) FROM sigma_scan_refs GROUP BY 1;  -- x5 stores
--
-- WHAT CHANGED IN v2 (R25 ruling)
--   Source-of-record is now sigma_scan_refs (dw220sdb.dbo.DBREFE -- Sigma's
--   NATIVE scan-reference table). Sigma stores check-digit-stripped bodies;
--   the extractor decodes (GS1 check digit, 12->13 / 11->12) with provenance
--   (code_kind, decode_method). barcode_list now carries the DECODED full
--   scannable codes. sigma_ean_master (IntellistoX, derivative) is no longer
--   read here -- it remains as a cross-check table during transition.
--
--   Every in-scope article resolves to exactly one of:
--     has_barcode = TRUE          -- decoded scannable code available (TLX-able)
--     is_confirmed_plu = TRUE     -- PLU/scale: DBREFE PLU row OR Sigma cPLU/cWAG
--     both FALSE                  -- absent from DBREFE = identity/internal code
--                                    -> LINK_CODES / canon 8.4 synthetic-internal
--                                    path. NEVER fabricated GS1 codes.
--
-- ENGINE CONTRACT UNCHANGED: refresh_l2_anomaly_family3 reads barcode_list /
-- has_barcode / is_confirmed_plu exactly as before.
-- =============================================================================


-- Rule 19: DROP first, then clean CREATE
DROP VIEW IF EXISTS v_item_ean;


CREATE VIEW v_item_ean AS
SELECT
    a.client_id,
    a.store_code,
    a.product_code,

    -- Pipe-separated DECODED scannable codes (NULL when no scannable row).
    -- Scannable = EAN13_BODY / UPCA_BODY (check digit appended) or FULL13.
    sr.barcode_list,

    sr.barcode_list IS NOT NULL                                 AS has_barcode,

    -- Confirmed PLU/scale: a PLU row in DBREFE, or Sigma article flags
    -- (cPLU='1' / cWAG='1') when no scannable code exists.
    (sr.barcode_list IS NULL
     AND (COALESCE(sr.has_plu_row, FALSE)
          OR a.plu_flag = '1' OR a.scale_flag = '1'))           AS is_confirmed_plu,

    -- Provenance (R25): which source resolved this article.
    CASE WHEN sr.barcode_list IS NOT NULL THEN 'DBREFE'
         WHEN COALESCE(sr.has_plu_row, FALSE)
              OR a.plu_flag = '1' OR a.scale_flag = '1' THEN 'PLU'
         ELSE NULL
    END                                                         AS ean_source

FROM sigma_articles a
LEFT JOIN (
    SELECT
        client_id,
        store_code,
        product_code,
        STRING_AGG(barcode_full, '|' ORDER BY barcode_full)
            FILTER (WHERE code_kind IN ('EAN13_BODY','UPCA_BODY','FULL13'))
                                                                AS barcode_list,
        BOOL_OR(code_kind = 'PLU')                              AS has_plu_row
    FROM sigma_scan_refs
    WHERE COALESCE(blocked_flag, '0') NOT IN ('1','-1')
    GROUP BY client_id, store_code, product_code
) sr ON  sr.client_id    = a.client_id
     AND sr.store_code   = a.store_code
     AND sr.product_code = a.product_code;


COMMENT ON VIEW v_item_ean IS
    'Reconciled EAN / PLU signal v2 (R25). One row per article. '
    'Source-of-record: sigma_scan_refs (DBREFE, Sigma-native, check-digit decoded '
    'with provenance). has_barcode=TRUE: decoded scannable code (EAN13/UPCA/FULL13). '
    'is_confirmed_plu=TRUE: DBREFE PLU row or Sigma cPLU/cWAG. Both FALSE = absent '
    'from DBREFE = identity/internal code (LINK_CODES path, never fabricated). '
    'Engine reads this view only. Ref: SB-CC-SOURCE-001, CLEANUP-ENGINE-CANON 8.4.';


GRANT SELECT ON v_item_ean TO anon, authenticated;


-- =============================================================================
-- POST-DEPLOY GATE AUDIT (run after first v1.11 load, all 5 stores):
-- =============================================================================
--
-- 1. TAC DUAL-PROOF (PM-required): decoded codes vs PRSSALE EANs --
-- SELECT s.store_code,
--        COUNT(DISTINCT s.barcode_full)                                    AS decoded_codes,
--        COUNT(DISTINCT s.barcode_full) FILTER (WHERE ds.ean IS NOT NULL)  AS tac_verified
-- FROM sigma_scan_refs s
-- LEFT JOIN (SELECT DISTINCT store_code, ean FROM daily_snapshots
--            WHERE snapshot_date >= CURRENT_DATE - 3) ds
--   ON ds.store_code = s.store_code AND ds.ean = s.barcode_full
-- WHERE s.code_kind IN ('EAN13_BODY','UPCA_BODY','FULL13')
-- GROUP BY s.store_code ORDER BY s.store_code;
--
-- 2. Gate count (expect a large drop from 452; remainder = LINK_CODES triage):
-- SELECT store_code,
--        COUNT(*) FILTER (WHERE NOT has_barcode AND NOT is_confirmed_plu) AS unresolved
-- FROM v_item_ean
-- JOIN l2_stock_position sp USING (store_code, product_code)
-- WHERE sp.class='NORMAL' AND sp.soh <> 0
-- GROUP BY store_code ORDER BY store_code;
--
-- 3. Spot-checks (expect 13-digit decoded codes):
-- SELECT store_code, product_code, barcode_list, ean_source
-- FROM v_item_ean
-- WHERE store_code='10116' AND product_code IN (
--   SELECT product_code FROM sigma_articles
--   WHERE description ILIKE '%B&H SPECIAL RED%' OR description ILIKE '%SCOTTISH LEADER%'
--      OR description ILIKE '%INVERROCHE%');
-- -- B&H expect barcode_list = 6001060684821
--
-- 4. 452 TRIAGE (present-in-DBREFE resolves; absent = identity/internal):
-- SELECT v.store_code, v.product_code, a.description,
--        CASE WHEN sr.product_code IS NOT NULL THEN 'IN_DBREFE_CHECK_KIND'
--             ELSE 'ABSENT_IDENTITY_CODE' END AS triage
-- FROM v_item_ean v
-- JOIN l2_stock_position sp USING (store_code, product_code)
-- JOIN sigma_articles a ON a.store_code=v.store_code AND a.product_code=v.product_code
-- LEFT JOIN (SELECT DISTINCT store_code, product_code FROM sigma_scan_refs) sr
--   ON sr.store_code=v.store_code AND sr.product_code=v.product_code
-- WHERE NOT v.has_barcode AND NOT v.is_confirmed_plu
--   AND sp.class='NORMAL' AND sp.soh <> 0
-- ORDER BY v.store_code, a.description;
-- =============================================================================
