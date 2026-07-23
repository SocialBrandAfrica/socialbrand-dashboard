-- =============================================================================
-- create_v_scan_ref_decoded.sql
-- Identity Layer Phase 1 (2026-07-22, CANON SS17). Owner: CC.
-- RECONCILE-001 one-file-per-object. Reconstructed from live DDL (R22),
-- HANDOVER-CURRENT JOB 1 debt cleared.
-- =============================================================================
-- THE DECODER. One row per scan code (L2 over native sigma_scan_refs). Closes
-- BUG-LOG ENG-030: kind = f(type_flag, system_flag, GS1 prefix), NEVER string
-- length. The extractor writes L1's code_kind from LENGTH while Sigma's own
-- type_flag (= DBREFE.cTYP) sits unused in the same row -- so 4,412 type_flag=3
-- EAN-8 bodies were stamped 'PLU'. This view reads the flags instead.
--
-- SAFE-BY-CONSTRUCTION rules baked in:
--   * UPCA_BODY is len-11 ONLY, EAN13_BODY len-12 ONLY. A shorter body decodes
--     ANOMALY_LEN (surfaced, non-real) rather than fabricating a check digit --
--     the two self-caught defects (type_flag=2 len-10, type_flag=1 len-7/8/10
--     had invented barcodes on 3,051 products before this).
--   * BLOCKED codes and non-numeric codes never decode.
--   * type_flag=0 20-29 body = IN_STORE (real, scannable, store-issued, NOT an
--     international article number and NOT a PLU). type_flag=0 scale-split was
--     FALSIFIED as a discriminator (canon SS17 gate c) -- scale lives on
--     sigma_articles.scale_flag, never a prefix guess.
--   * is_true_plu is ONLY type_flag=7 / system_flag=1 -- Sigma's real "no
--     scannable code" marker (RULE-BOOK SS2 tightened PLU).
--
-- is_real_v2 is GATE-1 SAFE: real-today (L1 body kinds) OR real-by-decode, so
-- nothing REAL can regress. Export/TLX eligibility is owned by l2_export_key,
-- never here. L1 (sigma_scan_refs) stays byte-identical -- this is L2 only.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_scan_ref_decoded AS
SELECT
    r.client_id,
    r.store_code,
    r.product_code,
    r.scan_code,
    r.type_flag,
    r.system_flag,
    r.blocked_flag,
    r.code_kind    AS code_kind_l1,     -- the length-derived L1 kind (the defect's carrier)
    r.barcode_full AS barcode_full_l1,
    k.code_kind_v2,

    -- append the GS1 check digit onto a stored body; FULL13 already carries it
    CASE
        WHEN k.code_kind_v2 = ANY (ARRAY['EAN8','EAN13_BODY','UPCA_BODY']) THEN r.scan_code || gs1_check_digit(r.scan_code)
        WHEN k.code_kind_v2 = 'FULL13' THEN r.scan_code
        ELSE NULL
    END AS barcode_full_v2,

    -- gate-1 safe: never demote a code L1 already calls a real body
    (k.code_kind_v2 = ANY (ARRAY['EAN13_BODY','UPCA_BODY','FULL13','EAN8']))
        OR (r.code_kind = ANY (ARRAY['EAN13_BODY','UPCA_BODY','FULL13'])) AS is_real_v2,

    -- the codes the EAN-8 decoder rescues that L1 did not already call real
    (k.code_kind_v2 = 'EAN8'
        AND (r.code_kind <> ALL (ARRAY['EAN13_BODY','UPCA_BODY','FULL13']))) AS real_added_by_decoder,

    (k.code_kind_v2 = 'IN_STORE') AS is_in_store,
    (k.code_kind_v2 = 'PLU')      AS is_true_plu,
    (k.code_kind_v2 IS DISTINCT FROM r.code_kind) AS kind_disagrees_with_l1

FROM sigma_scan_refs r
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN COALESCE(r.blocked_flag, '0') = ANY (ARRAY['1','-1']) THEN 'BLOCKED'
            WHEN r.scan_code !~ '^[0-9]+$'                             THEN 'NON_NUMERIC'
            WHEN r.type_flag = '7' AND r.system_flag = '1'            THEN 'PLU'
            WHEN r.type_flag = '9'                                    THEN 'ITF14'
            WHEN r.type_flag = '1' THEN
                CASE
                    WHEN length(r.scan_code) = 13 THEN 'FULL13'
                    WHEN length(r.scan_code) = 12 THEN 'EAN13_BODY'
                    WHEN length(r.scan_code) = 11 THEN 'UPCA_BODY'
                    ELSE 'ANOMALY_LEN'
                END
            WHEN r.type_flag = '3' THEN
                CASE
                    WHEN left(r.scan_code, 2) >= '20' AND left(r.scan_code, 2) <= '29' THEN 'IN_STORE'
                    WHEN length(r.scan_code) = 7 THEN 'EAN8'
                    ELSE 'ANOMALY_LEN'
                END
            WHEN r.type_flag = '0' THEN
                CASE
                    WHEN left(r.scan_code, 2) >= '20' AND left(r.scan_code, 2) <= '29' THEN 'IN_STORE'
                    ELSE 'OTHER_SHORT'
                END
            WHEN r.type_flag = '2' THEN
                CASE
                    WHEN length(r.scan_code) <= 5
                         AND left(r.scan_code, 2) >= '20' AND left(r.scan_code, 2) <= '29' THEN 'IN_STORE'
                    WHEN length(r.scan_code) = 11 THEN 'UPCA_BODY'
                    ELSE 'OTHER'
                END
            WHEN r.type_flag = ANY (ARRAY['4','6']) THEN 'HOLD_OUTLIER'
            ELSE 'OTHER'
        END AS code_kind_v2
) k;

COMMENT ON VIEW public.v_scan_ref_decoded IS
    'Identity Phase 1 decoder (CANON SS17, ENG-030). One row per scan code, kind = f(type_flag, system_flag, GS1 prefix) NEVER length. barcode_full_v2 appends the GS1 check digit for EAN8/EAN13/UPCA bodies. is_real_v2 is gate-1 safe (real-today OR real-by-decode). Export/TLX eligibility owned by l2_export_key, never here. L1 sigma_scan_refs stays byte-identical.';

GRANT SELECT ON public.v_scan_ref_decoded TO anon, authenticated;
