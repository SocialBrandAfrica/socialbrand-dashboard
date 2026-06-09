-- =============================================================================
-- migrate_sigma_ean_master_barcode_to_text.sql
-- SB-CC-L1-EAN-COMPLETENESS -- Phase 1: column type fix
-- =============================================================================
-- Version  : 1.0
-- Date     : 2026-06-09
-- Ref      : SB-CC-L1-EAN-COMPLETENESS, SIGMA-SERVER-SCHEMA-MAP.md SS9c
-- Owner    : CC (Claude Code)
--
-- ROOT CAUSE
--   dREFNR in IntellistoX_EAN_Master is a SQL Server float (double precision).
--   The extractor used CAST(dREFNR AS BIGINT) which truncates floating-point
--   imprecision: 6001060684821.0 may round to 6001060684820.xxx -> truncated
--   to 6001060684820.  Stored in Supabase as 600106068482 (12 digits, not 13).
--   B&H SPECIAL RED is the confirmed example; likely affects 100s of rows.
--
-- FIX
--   Extractor v1.7 uses CONVERT(varchar(20), CONVERT(bigint, ROUND(dREFNR, 0)))
--   which rounds first (correct) then converts to string.  sigma_ean_master.barcode
--   changes from bigint to text so no numeric precision is applied to the value.
--
-- HOW TO RUN
--   Paste into Supabase SQL Editor and Execute.
--   Takes ~1s on 33k rows.  Safe to re-run (idempotent via IF EXISTS).
--   After this, the next nightly push (extractor v1.7) re-ingests all barcodes
--   with correct precision.  Run verify query below after the next push.
-- =============================================================================


-- Step 1: Drop the unique constraint that references the barcode column
-- (Postgres cannot change the type of a column referenced by a constraint)
ALTER TABLE sigma_ean_master
    DROP CONSTRAINT IF EXISTS sigma_ean_master_client_id_store_code_barcode_product_code_key;


-- Step 2: Change barcode from bigint to text
-- USING barcode::text: all existing 12-digit truncated values are preserved as
-- strings so the table is not emptied.  The next nightly push will overwrite
-- them with the correct 13-digit values.
ALTER TABLE sigma_ean_master
    ALTER COLUMN barcode TYPE text USING barcode::text;


-- Step 3: Recreate the unique constraint (same logical key, now on text column)
ALTER TABLE sigma_ean_master
    ADD CONSTRAINT sigma_ean_master_client_id_store_code_barcode_product_code_key
    UNIQUE (client_id, store_code, barcode, product_code);


-- =============================================================================
-- VERIFY after next nightly push (extractor v1.7 must have run first):
-- =============================================================================
--
-- 1. Spot-check known truncated items:
-- SELECT store_code, product_code, barcode, LENGTH(barcode) AS len
-- FROM sigma_ean_master
-- WHERE product_code IN (
--     SELECT product_code FROM sigma_articles
--     WHERE description ILIKE '%B&H SPECIAL RED%'
--        OR description ILIKE '%SCOTTISH LEADER%'
--        OR description ILIKE '%INVERROCHE GIN%'
-- )
-- ORDER BY store_code, product_code;
-- Expected: len = 13 for EAN-13 barcodes.
--
-- 2. Unresolved count (target: 533 -> 0):
-- SELECT
--     a.store_code,
--     COUNT(*) FILTER (
--         WHERE NOT EXISTS (
--             SELECT 1 FROM sigma_ean_master em
--             WHERE em.store_code   = a.store_code
--               AND em.product_code = a.product_code
--         )
--         AND a.plu_flag IS DISTINCT FROM '1'
--         AND a.scale_flag IS DISTINCT FROM '1'
--     ) AS unresolved
-- FROM sigma_articles a
-- JOIN l2_stock_position sp
--     ON sp.store_code   = a.store_code
--    AND sp.product_code = a.product_code
--    AND sp.class        = 'NORMAL'
--    AND sp.soh         <> 0
-- GROUP BY a.store_code
-- ORDER BY a.store_code;
-- =============================================================================
