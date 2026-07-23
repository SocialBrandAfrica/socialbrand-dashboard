-- =============================================================================
-- create_v_item_ean.sql
-- SocialBrand Intelligence Platform -- Reconciled EAN / PLU signal
-- =============================================================================
-- Version  : 3.0 (Identity Phase 1 repoint)
-- Date     : 2026-07-22
-- Ref      : CANON SS17 (Identity Layer), ENG-030, SB-CC-L1-EAN-COMPLETENESS,
--            R25 (native-first)
-- Owner    : CC (Claude Code)
-- Reconstructed from live DDL (R22), HANDOVER-CURRENT JOB 1 debt cleared.
--
-- WHAT CHANGED IN v3 (ENG-030 CLOSED)
--   v_item_ean is REPOINTED onto v_scan_ref_decoded. code_kind now comes from
--   Sigma's own type_flag/system_flag + GS1 prefix, NEVER string length. The
--   defect it closes: the length-decoder stamped ~4,303 EAN-8-body products
--   'PLU' (is_confirmed_plu=true) -- OUR assertion, not Sigma's fact.
--
--   The OUTPUT CONTRACT IS UNCHANGED (barcode_list / has_barcode /
--   is_confirmed_plu / ean_source), so every consumer -- l2_classification,
--   refresh_l2_anomaly_family3, l2_anomaly_daily, rpc_forge_count_list,
--   rpc_forge_integrity, rpc_forge_lines, rpc_forge_summary -- reads it exactly
--   as before. Gate 1 proven live: 0 has_barcode regressions, 3,110 products
--   gained a real barcode.
--
--   Key semantic tightenings, all sourced from v_scan_ref_decoded:
--     * barcode_list = the DECODED real codes (barcode_full_v2, falling back to
--       L1's barcode_full where the decoder adds nothing), FILTER is_real_v2.
--     * is_confirmed_plu = TRUE only where Sigma's own type_flag=7/system_flag=1
--       says so (has_true_plu_row), OR the article carries plu_flag/scale_flag.
--       An EAN-8 body is no longer swept into PLU by its length.
--
-- v2 lineage (superseded, kept for history): source-of-record moved to
-- sigma_scan_refs (DBREFE native) 2026-06-12; sigma_ean_master became a
-- derivative cross-check only (R25). v3 keeps that source and fixes the decode.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_item_ean AS
SELECT
    a.client_id,
    a.store_code,
    a.product_code,

    -- Pipe-separated DECODED real scannable codes (NULL when none).
    sr.barcode_list,

    sr.barcode_list IS NOT NULL                                 AS has_barcode,

    -- Confirmed PLU/scale: Sigma's own true-PLU row (type_flag=7/system_flag=1),
    -- or the article flags, and only when no scannable code exists.
    (sr.barcode_list IS NULL
     AND (COALESCE(sr.has_true_plu_row, FALSE)
          OR a.plu_flag = '1' OR a.scale_flag = '1'))           AS is_confirmed_plu,

    -- Provenance (R25): which source resolved this article.
    CASE WHEN sr.barcode_list IS NOT NULL THEN 'DBREFE'
         WHEN COALESCE(sr.has_true_plu_row, FALSE)
              OR a.plu_flag = '1' OR a.scale_flag = '1' THEN 'PLU'
         ELSE NULL
    END                                                         AS ean_source

FROM sigma_articles a
LEFT JOIN (
    SELECT
        d.client_id,
        d.store_code,
        d.product_code,
        STRING_AGG(COALESCE(d.barcode_full_v2, d.barcode_full_l1), '|'
                   ORDER BY COALESCE(d.barcode_full_v2, d.barcode_full_l1))
            FILTER (WHERE d.is_real_v2
                      AND COALESCE(d.barcode_full_v2, d.barcode_full_l1) IS NOT NULL)
                                                                AS barcode_list,
        BOOL_OR(d.is_true_plu)                                  AS has_true_plu_row
    FROM v_scan_ref_decoded d
    WHERE COALESCE(d.blocked_flag, '0') <> ALL (ARRAY['1','-1'])
    GROUP BY d.client_id, d.store_code, d.product_code
) sr ON  sr.client_id    = a.client_id
     AND sr.store_code   = a.store_code
     AND sr.product_code = a.product_code;

COMMENT ON VIEW public.v_item_ean IS
    'Reconciled EAN / PLU signal v3 (Identity Phase 1, ENG-030). One row per '
    'article. Repointed onto v_scan_ref_decoded: code kind = Sigma type_flag/'
    'system_flag+prefix, never string length. Output contract unchanged '
    '(barcode_list/has_barcode/is_confirmed_plu/ean_source). is_confirmed_plu is '
    'TRUE only where Sigma cTYP=7/cSYSTEM=1 (or plu_flag/scale_flag). Engine '
    'reads this view only. Ref: CANON SS17, SS8.4.';

GRANT SELECT ON public.v_item_ean TO anon, authenticated;
