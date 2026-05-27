-- =============================================================================
-- PLU STUB INVESTIGATION (SB-AUD-002 Open Investigation)
--
-- product_search_index schema: ean, description, dept, subdept, stores[], last_seen
-- No plu column. No store_code column (stores is a text[] array).
--
-- Stale rows are those where the ean column holds a raw short PLU code
-- (e.g. "200215") instead of the correct 13-digit synthetic EAN.
--
-- Known PLUs that showed short codes in the dashboard:
--   PLU 200215  SPAR Delareyville  -> correct EAN 1011600200215
--   PLU 200301  SPAR Roosville     -> correct EAN 8017500200301
--
-- Run steps in order in the Supabase SQL Editor.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1: Find stale rows for the two known biltong PLUs
-- ---------------------------------------------------------------------------
SELECT ean, description, dept, subdept, stores, last_seen
FROM product_search_index
WHERE ean::text IN ('200215', '200301', '00200215', '00200301')
ORDER BY ean;
-- If rows return here, those are the stubs. Delete them in Step 4.
-- The correct rows to keep have EAN '1011600200215' and '8017500200301'.


-- ---------------------------------------------------------------------------
-- STEP 2: Broad audit — count all entries with sub-13-character EANs
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS stale_count
FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%';
-- If stale_count > 0, inspect with Step 3 before deleting.


-- ---------------------------------------------------------------------------
-- STEP 3: Inspect sub-13-digit rows before deleting
-- ---------------------------------------------------------------------------
SELECT ean, description, dept, subdept, stores, last_seen
FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%'
ORDER BY dept, description
LIMIT 100;


-- ---------------------------------------------------------------------------
-- STEP 4: Delete confirmed stale short-code stubs
--         (RUN ONLY after Step 3 review)
-- ---------------------------------------------------------------------------
DELETE FROM product_search_index
WHERE LENGTH(ean::text) < 13
  AND ean::text NOT LIKE 'B%'
  AND ean::text NOT LIKE 'b%';
-- Row count should equal stale_count from Step 2.


-- ---------------------------------------------------------------------------
-- STEP 5: Verify the correct 13-digit rows still exist
-- ---------------------------------------------------------------------------
SELECT ean, description, dept, stores, last_seen
FROM product_search_index
WHERE ean::text IN ('1011600200215', '8017500200301')
ORDER BY ean;
-- Expected: one row per EAN.


-- ---------------------------------------------------------------------------
-- STEP 6: Final index count
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_entries FROM product_search_index;
