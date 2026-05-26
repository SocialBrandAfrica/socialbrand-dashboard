-- =============================================================================
-- cleanup_search_index_post_ean_fix.sql
--
-- The EAN fix (sb_ean_002_fix.sql) renamed PLU codes in daily_snapshots.ean
-- to 13-digit synthetic EANs. The product_search_index was built before the
-- fix and still has entries keyed by the old short PLU codes. Those entries:
--   - No longer match any row in daily_snapshots (the PLU keys are gone)
--   - Block the synthetic EAN entries from being found by key-exact search
--
-- This script:
--   1. Counts the stale entries
--   2. Deletes them
--   3. Rebuilds the index for all 5 stores (adds the synthetic EAN entries)
--
-- Run after vacuum_analyze_post_ean_fix.sql Step 1 (VACUUM) is complete.
-- Steps 1 and 2 can be run in a single editor block.
-- Steps 3a-3e (upsert calls) can be run together.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Count stale entries (read-only, run first)
-- A stale entry is one whose EAN no longer exists anywhere in daily_snapshots.
-- Expected: several hundred to a few thousand (old short PLU codes).
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS stale_entries
FROM   product_search_index psi
WHERE  NOT EXISTS (
           SELECT 1
           FROM   daily_snapshots ds
           WHERE  ds.ean = psi.ean
           LIMIT  1
       );


-- ---------------------------------------------------------------------------
-- STEP 2 -- Delete stale entries
-- ---------------------------------------------------------------------------
DELETE FROM product_search_index
WHERE  NOT EXISTS (
           SELECT 1
           FROM   daily_snapshots ds
           WHERE  ds.ean = product_search_index.ean
           LIMIT  1
       );


-- ---------------------------------------------------------------------------
-- STEP 3 -- Full rebuild for all 5 stores
-- Inserts synthetic EAN entries that were never in the index.
-- ON CONFLICT updates existing entries (desc, dept, stores, last_seen).
-- Run all 5 in one block -- they are independent.
-- ---------------------------------------------------------------------------
SELECT upsert_search_index('10116');  -- SPAR Delareyville
SELECT upsert_search_index('21355');  -- TOPS Delareyville
SELECT upsert_search_index('80175');  -- SPAR Roosville
SELECT upsert_search_index('80176');  -- TOPS Roosville
SELECT upsert_search_index('80579');  -- TOPS Dice


-- ---------------------------------------------------------------------------
-- STEP 4 -- Verify
-- Expected: total_entries close to the count before Step 2 minus stale_entries
--           latest_seen should be today or yesterday.
-- ---------------------------------------------------------------------------
SELECT COUNT(*)       AS total_entries,
       MAX(last_seen) AS latest_seen
FROM   product_search_index;
