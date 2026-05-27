-- =============================================================================
-- PLU STUB INVESTIGATION (SB-AUD-002 Open Investigation)
--
-- Pieter noticed short-format PLU codes appearing on some biltong lines in
-- the dashboard search results alongside the correct 13-digit synthetic EANs.
-- This script identifies and removes stale PLU stub rows from product_search_index.
--
-- Expected correct EANs:
--   BEEF SLICED BILTONG  SPAR Delareyville  ->  1011600200215
--   BEEF BILTONG SLICED  SPAR Roosville     ->  8017500200301
--
-- Run all steps in order in the Supabase SQL Editor.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1: Find stale short-code stubs for the two known biltong PLUs
-- ---------------------------------------------------------------------------
SELECT ean, plu, description, store_code
FROM product_search_index
WHERE ean::text IN ('200215', '200301', '00200215', '00200301')
   OR plu::text IN ('200215', '200301', '00200215', '00200301')
ORDER BY store_code, ean;
-- If any rows return with ean length < 13, those are stale stubs.
-- The correct rows to keep: EAN 1011600200215 and EAN 8017500200301.


-- ---------------------------------------------------------------------------
-- STEP 2: Broad audit — count all entries with sub-13-digit EANs
--         (barcode-format EANs starting with letters are excluded)
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS stale_count
FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%';
-- If stale_count > 0, inspect these rows with the query below before deleting.


-- ---------------------------------------------------------------------------
-- STEP 3: Inspect all sub-13-digit stale rows before deleting
-- ---------------------------------------------------------------------------
SELECT ean, description, dept, store_code, stores
FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%'
ORDER BY dept, description
LIMIT 100;
-- Review these rows. Most will be raw PLU codes that survived the April clean-up.


-- ---------------------------------------------------------------------------
-- STEP 4: Delete confirmed stale short-code stubs
--         (RUN ONLY after Step 3 confirms all rows are stale)
-- ---------------------------------------------------------------------------
DELETE FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%';
-- Check the row count in the result — should equal stale_count from Step 2.


-- ---------------------------------------------------------------------------
-- STEP 5: Verify correct 13-digit rows are still present
-- ---------------------------------------------------------------------------
SELECT ean, description, dept, store_code
FROM product_search_index
WHERE ean::text IN ('1011600200215', '8017500200301')
ORDER BY ean, store_code;
-- Expected: at least one row per EAN showing the correct 13-digit value.


-- ---------------------------------------------------------------------------
-- STEP 6: Final index count
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_entries FROM product_search_index;
-- Should be lower than before by the stale_count deleted in Step 4.
