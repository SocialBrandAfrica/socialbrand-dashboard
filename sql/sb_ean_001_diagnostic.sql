-- =============================================================================
-- sb_ean_001_diagnostic.sql
--
-- Diagnoses the EAN/PLU contamination in daily_snapshots WITHOUT a full
-- table scan.  The naive approach (WHERE LENGTH(ean) <= 8) scans all 18M
-- rows and hits Supabase's 60-second HTTP gateway timeout every time.
--
-- This version joins daily_snapshots.ean against product_catalog.plu_raw
-- on (store_code, plu_raw).  Both columns are indexed, so the planner
-- executes an index nested-loop join — milliseconds instead of minutes.
--
-- PREREQUISITE:
--   1. Run create_product_catalog.sql
--   2. Run load_plu_reference.py to populate product_catalog from DIWAAIS2
--
-- Run in Supabase SQL Editor.  No writes — safe to run any time.
-- =============================================================================

-- ── 1. How many daily_snapshots rows have a raw PLU instead of synthetic EAN?
SELECT
  ds.store_code,
  COUNT(*)                                    AS raw_plu_rows,
  COUNT(DISTINCT ds.ean)                      AS distinct_raw_plús,
  COUNT(DISTINCT ds.snapshot_date)            AS affected_dates,
  MIN(ds.snapshot_date)                       AS earliest_date,
  MAX(ds.snapshot_date)                       AS latest_date
FROM public.daily_snapshots ds
JOIN public.product_catalog pc
  ON  pc.store_code = ds.store_code
  AND pc.plu_raw    = ds.ean
  AND pc.is_plu     = TRUE
GROUP BY ds.store_code
ORDER BY ds.store_code;


-- ── 2. Cross-store PLU collision proof
--    Same raw PLU in both stores maps to different products.
--    This is WHY synthetic EANs are required.
SELECT
  a.plu_raw,
  a.store_code                               AS store_a,
  a.description                              AS description_a,
  a.ean                                      AS synthetic_a,
  b.store_code                               AS store_b,
  b.description                              AS description_b,
  b.ean                                      AS synthetic_b
FROM public.product_catalog a
JOIN public.product_catalog b
  ON  a.plu_raw = b.plu_raw
  AND a.store_code < b.store_code    -- avoid self-join duplicates
  AND a.is_plu
  AND b.is_plu
  AND a.description <> b.description -- different product = collision
ORDER BY a.plu_raw
LIMIT 20;


-- ── 3. Eight-digit PLUs in daily_snapshots (push script -lt 8 bug)
--    These are in daily_snapshots as raw 8-digit strings because the
--    push script used  $rawEan.Length -lt 8  instead of  -le 8.
SELECT
  ds.store_code,
  COUNT(*)                                    AS rows_affected,
  COUNT(DISTINCT ds.ean)                      AS distinct_8d_plús
FROM public.daily_snapshots ds
JOIN public.product_catalog pc
  ON  pc.store_code = ds.store_code
  AND pc.plu_raw    = ds.ean
  AND pc.is_plu     = TRUE
  AND LENGTH(ds.ean) = 8
GROUP BY ds.store_code;


-- ── 4. Would the Step-A DELETE remove anything?
--    Rows where BOTH the raw PLU and its synthetic EAN already exist
--    for the same (store_code, snapshot_date) — true duplicates.
SELECT
  ds_raw.store_code,
  COUNT(*)                                    AS true_duplicate_rows
FROM public.daily_snapshots ds_raw
JOIN public.product_catalog pc
  ON  pc.store_code = ds_raw.store_code
  AND pc.plu_raw    = ds_raw.ean
  AND pc.is_plu     = TRUE
JOIN public.daily_snapshots ds_syn
  ON  ds_syn.store_code    = pc.store_code
  AND ds_syn.snapshot_date = ds_raw.snapshot_date
  AND ds_syn.ean           = pc.ean      -- synthetic EAN already exists
GROUP BY ds_raw.store_code;
