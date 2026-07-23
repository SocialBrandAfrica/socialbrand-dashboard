-- =============================================================================
-- create_gs1_check_digit.sql
-- Identity Layer Phase 1 (2026-07-22, CANON SS17). Owner: CC.
-- RECONCILE-001 one-file-per-object. Reconstructed from live DDL (R22),
-- HANDOVER-CURRENT JOB 1 debt cleared.
-- =============================================================================
-- GS1 modulo-10 check digit, LENGTH-AGNOSTIC. The weights run 3,1 from the
-- RIGHTMOST body digit, so one function serves an EAN-8 7-digit body, a UPC-A
-- 11-digit body and an EAN-13 12-digit body alike.
--
-- Why it exists: Sigma's DBREFE stores the code BODY; the till appends the
-- check digit (RULE-BOOK SS2, "code body vs full code"). v_scan_ref_decoded
-- calls this to APPEND the check digit onto a stored body and produce the real
-- scannable barcode -- exactly as the extractor already did for EAN13/UPC-A
-- bodies, now extended to EAN-8 bodies that the length-decoder had mislabelled
-- PLU (ENG-030).
--
-- Pure helper: IMMUTABLE, PARALLEL SAFE, STRICT (NULL body -> NULL). No side
-- effects, so anon/authenticated EXECUTE like any read object (R30 exempts
-- non-mutating functions).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gs1_check_digit(p_body text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE STRICT
SET search_path TO 'public'
AS $fn$
  -- GS1 modulo-10. Weights run 3,1 from the RIGHTMOST body digit, so the rule
  -- is length-agnostic and serves EAN-8 (7-body), UPC-A (11) and EAN-13 (12).
  SELECT ((10 - (SUM(substr(p_body, g.i, 1)::int
                     * CASE WHEN (length(p_body) - g.i) % 2 = 0 THEN 3 ELSE 1 END) % 10)) % 10)::text
  FROM generate_series(1, length(p_body)) AS g(i)
$fn$;

GRANT EXECUTE ON FUNCTION public.gs1_check_digit(text) TO anon, authenticated;
