-- =============================================================================
-- sb_ean_002_fix_batched.sql
--
-- Replaces sb_ean_002_fix.sql for use in the Supabase SQL Editor (60s timeout).
-- Run each numbered block SEPARATELY. Each block is one store or one date batch
-- and completes in under 60 seconds.
--
-- TOTAL SCOPE (from sb_ean_001_diagnostic.sql):
--   Store 10116: delete 33,889 dupes + update 122,421 rows
--   Store 21355: delete 121 dupes   + update 482 rows
--   Store 80175: delete 19,406 dupes + update 7,883 rows
--   Store 80176: delete 381 dupes   + update 1,015 rows
--   Store 80579: delete 396 dupes   + update 0 rows (all were dupes)
--
-- PREREQUISITES:
--   1. create_product_catalog.sql run
--   2. load_plu_reference.py run (42,900 rows loaded)
--   3. sb_ean_001_diagnostic.sql reviewed
--
-- ORDER: Run all Step A blocks first (delete dupes), then all Step B blocks
-- (rename to synthetic EAN). Never run Step B before Step A on the same store.
--
-- After all blocks done, run Step C (verify) and Step D (refresh MV).
-- =============================================================================


-- ============================================================
-- STEP A: Delete true duplicates
-- (rows where synthetic EAN already exists alongside raw PLU)
-- Run each A-block separately. Check row count after each.
-- ============================================================


-- ── A1: Store 10116, Feb–Jun 2025 (expect ~10,000–12,000 rows) ────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code    = '10116'
    AND  ds.snapshot_date BETWEEN '2025-02-01' AND '2025-06-30'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A2: Store 10116, Jul–Nov 2025 (expect ~10,000–12,000 rows) ────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code    = '10116'
    AND  ds.snapshot_date BETWEEN '2025-07-01' AND '2025-11-30'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A3: Store 10116, Dec 2025–May 2026 (expect ~10,000–12,000 rows) ───────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code    = '10116'
    AND  ds.snapshot_date BETWEEN '2025-12-01' AND '2026-05-31'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A4: Store 80175, Feb–Jul 2025 (expect ~8,000–10,000 rows) ─────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code    = '80175'
    AND  ds.snapshot_date BETWEEN '2025-02-01' AND '2025-07-31'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A5: Store 80175, Aug 2025–May 2026 (expect ~9,000–10,000 rows) ────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code    = '80175'
    AND  ds.snapshot_date BETWEEN '2025-08-01' AND '2026-05-31'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A6: Store 21355 — all dates (expect 121 rows) ─────────────────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code = '21355'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A7: Store 80176 — all dates (expect 381 rows) ─────────────────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code = '80176'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ── A8: Store 80579 — all dates (expect 396 rows) ─────────────────────────
WITH dupes AS (
  SELECT ds.store_code, ds.snapshot_date, ds.ean
  FROM   public.daily_snapshots ds
  JOIN   public.product_catalog pc
           ON  pc.store_code = ds.store_code
           AND pc.plu_raw    = ds.ean
           AND pc.is_plu     = TRUE
  WHERE  ds.store_code = '80579'
    AND  EXISTS (
           SELECT 1 FROM public.daily_snapshots ds2
           WHERE  ds2.store_code    = ds.store_code
             AND  ds2.snapshot_date = ds.snapshot_date
             AND  ds2.ean           = pc.ean
         )
)
DELETE FROM public.daily_snapshots
WHERE  (store_code, snapshot_date, ean) IN (SELECT store_code, snapshot_date, ean FROM dupes);


-- ============================================================
-- STEP B: Rename raw PLU rows to synthetic EAN
-- Only run AFTER all Step A blocks for that store are done.
-- Uses product_catalog_plu_raw_idx — no full table scan.
-- ============================================================


-- ── B1: Store 10116 (expect 122,421 rows updated) ─────────────────────────
UPDATE public.daily_snapshots ds
SET    ean = pc.ean
FROM   public.product_catalog pc
WHERE  pc.store_code = ds.store_code
  AND  pc.plu_raw    = ds.ean
  AND  pc.is_plu     = TRUE
  AND  ds.store_code = '10116';


-- ── B2: Store 80175 (expect 7,883 rows updated) ────────────────────────────
UPDATE public.daily_snapshots ds
SET    ean = pc.ean
FROM   public.product_catalog pc
WHERE  pc.store_code = ds.store_code
  AND  pc.plu_raw    = ds.ean
  AND  pc.is_plu     = TRUE
  AND  ds.store_code = '80175';


-- ── B3: Store 21355 (expect 482 rows updated) ──────────────────────────────
UPDATE public.daily_snapshots ds
SET    ean = pc.ean
FROM   public.product_catalog pc
WHERE  pc.store_code = ds.store_code
  AND  pc.plu_raw    = ds.ean
  AND  pc.is_plu     = TRUE
  AND  ds.store_code = '21355';


-- ── B4: Store 80176 (expect 1,015 rows updated) ────────────────────────────
UPDATE public.daily_snapshots ds
SET    ean = pc.ean
FROM   public.product_catalog pc
WHERE  pc.store_code = ds.store_code
  AND  pc.plu_raw    = ds.ean
  AND  pc.is_plu     = TRUE
  AND  ds.store_code = '80176';


-- ── B5: Store 80579 — skip (all rows were dupes, deleted in A8) ────────────
-- SELECT 'Store 80579: no rows to update — all PLU rows were true duplicates';


-- ============================================================
-- STEP C: Verify — run after all A + B blocks complete
-- Should return 0 rows per store if fix is complete.
-- ============================================================

SELECT
  ds.store_code,
  COUNT(*)               AS remaining_raw_plu_rows,
  COUNT(DISTINCT ds.ean) AS distinct_raw_plús_remaining
FROM   public.daily_snapshots ds
JOIN   public.product_catalog pc
         ON  pc.store_code = ds.store_code
         AND pc.plu_raw    = ds.ean
         AND pc.is_plu     = TRUE
GROUP  BY ds.store_code;


-- ============================================================
-- STEP D: Refresh materialized view (run once after Step C = 0 rows)
-- mv_rate_of_sale uses the EAN column — must rebuild.
-- ============================================================

REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_rate_of_sale;

SELECT pg_notify('pgrst', 'reload schema');
