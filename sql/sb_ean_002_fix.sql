-- =============================================================================
-- sb_ean_002_fix.sql
--
-- Historical EAN fix for daily_snapshots.
--
-- Problem: Push script v3.14 and earlier wrote raw PLU codes (1-8 digits)
-- directly into daily_snapshots.ean instead of the synthetic 13-digit EAN.
-- 534 PLU codes exist in BOTH SPAR stores but map to different products —
-- without store-specific synthetic EANs the data is silently corrupt.
--
-- Fix strategy:
--   Step A  — DELETE rows where the synthetic EAN already exists for the
--              same (store_code, snapshot_date).  These are true duplicates
--              created if any partial-fix run already ran.  Safe to skip if
--              Step-A count (from diagnostic) is 0.
--
--   Step B  — UPDATE daily_snapshots.ean from raw PLU to synthetic 13-digit
--              EAN using the product_catalog index join (no table scan).
--
--   Step C  — Verify: no raw PLU codes remain in daily_snapshots.
--
--   Step D  — Refresh mv_rate_of_sale (its data uses the EAN column).
--
-- PREREQUISITES:
--   1. Run create_product_catalog.sql
--   2. Run load_plu_reference.py  (populates product_catalog from DIWAAIS2)
--   3. Run sb_ean_001_diagnostic.sql  (confirm scope, especially Step-A count)
--   4. BACK UP daily_snapshots or confirm you can restore from push history
--
-- EXECUTION TIME: Step B touches ~16M rows (all historical PLU rows across
-- all snapshots).  Run as a single transaction; Supabase may need the service
-- role key (not anon key) to avoid statement_timeout.  Expect 2-10 minutes.
--
-- Run in Supabase SQL Editor using the service role connection.
-- =============================================================================

BEGIN;

-- ── Step A: Remove true duplicates ─────────────────────────────────────────
-- Only needed if synthetic EAN rows were already inserted by a partial fix.
-- If sb_ean_001 Step-4 returned 0, this deletes nothing (safe to run).
DELETE FROM public.daily_snapshots ds_raw
USING public.product_catalog pc,
      public.daily_snapshots ds_syn
WHERE pc.store_code    = ds_raw.store_code
  AND pc.plu_raw       = ds_raw.ean        -- raw PLU row
  AND pc.is_plu        = TRUE
  AND ds_syn.store_code    = pc.store_code
  AND ds_syn.snapshot_date = ds_raw.snapshot_date
  AND ds_syn.ean           = pc.ean;       -- synthetic EAN already exists → delete raw duplicate

-- ── Step B: Rename raw PLU rows to synthetic EAN ───────────────────────────
-- Joins on (store_code, plu_raw) index — no full table scan.
UPDATE public.daily_snapshots ds
SET    ean = pc.ean
FROM   public.product_catalog pc
WHERE  pc.store_code = ds.store_code
  AND  pc.plu_raw    = ds.ean
  AND  pc.is_plu     = TRUE;

COMMIT;


-- ── Step C: Verify ─────────────────────────────────────────────────────────
-- Should return 0 rows if fix is complete.
SELECT
  ds.store_code,
  COUNT(*)                               AS remaining_raw_plu_rows,
  COUNT(DISTINCT ds.ean)                 AS distinct_raw_plús_remaining
FROM public.daily_snapshots ds
JOIN public.product_catalog pc
  ON  pc.store_code = ds.store_code
  AND pc.plu_raw    = ds.ean
  AND pc.is_plu     = TRUE
GROUP BY ds.store_code;


-- ── Step D: Refresh materialized view ──────────────────────────────────────
-- mv_rate_of_sale contains EAN — must rebuild to reflect corrected EANs.
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_rate_of_sale;

-- Also reload PostgREST schema cache
SELECT pg_notify('pgrst', 'reload schema');
