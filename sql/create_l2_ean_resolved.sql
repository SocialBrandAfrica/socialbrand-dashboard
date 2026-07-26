-- =============================================================================
-- create_l2_ean_resolved.sql
-- IDENTITY PHASE 2 (CANON SS17) -- THE DETERMINISTIC RESOLVED IDENTITY.
-- Applied 2026-07-26, migration phase2_01_l2_ean_resolved_native_first_identity.
-- Owner: CC. Item-12 INDEPENDENT.
-- =============================================================================
-- One canonical scannable key per (store_code, product_code), NATIVE FIRST:
-- Sigma's own scan codes via v_scan_ref_decoded, with the monthly
-- product_catalog spreadsheet demoted to a fallback. This is what retires the
-- R25 SS2 break named in RULE-BOOK SS8 and CANON SS17 -- a canonical object
-- (v_ean_bridge) standing on a derivative.
--
-- WHAT IT IS NOT: it carries no family, no keeper, no successor and no verdict.
-- Those live in l2_product_resolution and are HELD for PM's item-12 ruling
-- (2026-07-26). This table answers only the deterministic question: which
-- barcode is this product's canonical key, and did Sigma actually give us one.
--
-- ⭐ WHY PERSISTED, NOT A VIEW (measured, not assumed). The decoder's CASE plus
-- gs1_check_digit over 240k sigma_scan_refs rows measured 6,835 ms as a plain
-- query (EXPLAIN ANALYZE 2026-07-26). v_ean_bridge has 31 live dependents, so a
-- 6.8s view would have been a dashboard-wide regression. Persisted + refreshed
-- on the nightly chain, the bridge reads in 55 ms -- a 124x difference.
--
-- COVERAGE WON (measured ×5, 2026-07-26). Native real-EAN coverage vs the old
-- catalogue-only bridge: 10116 77.4% vs 43.0% · 21355 88.4% vs 2.5% ·
-- 80175 83.7% vs 16.0% · 80176 91.1% vs 2.6% · 80579 88.4% vs 2.2%.
-- The three TOPS stores go from ~2.5% to ~88-91%, which is why canon's
-- "treat TOPS EAN-grain coverage as synthetic-dominant" is now retired.
--
-- R22 GATES PASSED before the bridge was repointed:
--   * (store_code, product_code) unique -- 240,142 rows / 240,142 keys, 0 dupes
--     (fan-out safety, R20, preserved)
--   * 0 products lost: every (store, product) the old bridge carried still has a
--     row (product_catalog survives as the fallback -- 4,512 rows group-wide
--     still resolve only through it, which is why its retirement is Phase 3)
--   * 1,462 keys CHANGED to a native value (~3.4% of the old bridge)
--   * EAN-8 rescue population 3,113/3,113 check-digit valid; UPC-A 7,672/7,672
--   * sales reconciliation delta R0.0000 on all 5 stores (R20 addendum)
--
-- NAMED FINDING, pre-existing, NOT introduced here: 25 FULL13 codes Sigma holds
-- fail their own GS1 check digit (e.g. 1234567891213 on BONNITA BULK CHEDDAR
-- 2X10KG -- a hand-typed dummy). They are byte-identical to what L1 already
-- carried and already flowed through v_item_ean, so this is L1 data quality for
-- a floor fix, not a decoder defect.
--
-- ean_shared: another product in the SAME store resolves to the SAME barcode.
-- 66 products / 33 groups group-wide. SURFACED, never resolved -- these are the
-- recode/successor signature and they emit to l2_link_codes_queue as candidates.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_ean_resolved (
  client_id        text        NOT NULL DEFAULT 'socialbrand',
  store_code       text        NOT NULL,
  product_code     bigint      NOT NULL,
  ean              text,                                 -- canonical key; NULL = no key at all
  ean_source       text        NOT NULL,                  -- NATIVE_EAN13 | NATIVE_UPCA | NATIVE_EAN8 | CATALOGUE | NONE
  is_real          boolean     NOT NULL,                  -- true only when Sigma itself holds a real GS1 code
  real_code_count  smallint    NOT NULL DEFAULT 0,        -- how many real codes the product carries (the lossy-shape fact)
  ean_shared       boolean     NOT NULL DEFAULT false,    -- another product in this store resolves to the SAME ean
  in_articles      boolean     NOT NULL DEFAULT false,    -- present in sigma_articles at this store
  resolved_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

COMMENT ON TABLE public.l2_ean_resolved IS
  'Identity Phase 2 (CANON SS17). Deterministic resolved identity: one canonical scannable key per (store_code, product_code), native sigma_scan_refs first (v_scan_ref_decoded), product_catalog only as fallback. Retires the R25 SS2 break under v_ean_bridge, which is now a thin view over this. Carries NO family/keeper/successor verdict -- that is l2_product_resolution, held for the item-12 ruling. ean_shared flags a second product resolving to the same barcode: a candidate for l2_link_codes_queue, never auto-resolved here.';

CREATE INDEX IF NOT EXISTS l2_ean_resolved_ean_idx    ON public.l2_ean_resolved (store_code, ean) WHERE ean IS NOT NULL;
CREATE INDEX IF NOT EXISTS l2_ean_resolved_shared_idx ON public.l2_ean_resolved (store_code) WHERE ean_shared;

ALTER TABLE public.l2_ean_resolved ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_ean_resolved_read ON public.l2_ean_resolved;
CREATE POLICY l2_ean_resolved_read ON public.l2_ean_resolved FOR SELECT USING (true);
GRANT SELECT ON public.l2_ean_resolved TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_ean_resolved(p_store text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_rows int; v_native int; v_cat int; v_none int; v_shared int; v_real int;
BEGIN
  DELETE FROM l2_ean_resolved WHERE store_code = p_store;

  INSERT INTO l2_ean_resolved
    (store_code, product_code, ean, ean_source, is_real, real_code_count, in_articles)
  WITH native AS (
    SELECT d.store_code, d.product_code, d.barcode_full_v2 AS ean, d.code_kind_v2,
           CASE d.code_kind_v2 WHEN 'FULL13'     THEN 1
                               WHEN 'EAN13_BODY' THEN 1
                               WHEN 'UPCA_BODY'  THEN 2
                               WHEN 'EAN8'       THEN 3
                               ELSE 9 END AS kind_rank
    FROM v_scan_ref_decoded d
    WHERE d.store_code = p_store
      AND d.is_real_v2
      AND d.barcode_full_v2 IS NOT NULL
  ),
  native_pick AS (
    -- canon SS8.4 dedup: real GS1 first (EAN13 > UPC-A > EAN-8), MIN(ean) tiebreak
    SELECT DISTINCT ON (store_code, product_code)
           store_code, product_code, ean, code_kind_v2,
           count(*) OVER (PARTITION BY store_code, product_code) AS real_code_count
    FROM native
    ORDER BY store_code, product_code, kind_rank, ean
  ),
  cat AS (
    -- the retiring fallback: product_catalog (monthly DIWAAIS2 derivative, R25 SS2)
    SELECT DISTINCT ON (store_code, product_code) store_code, product_code, ean
    FROM (
      SELECT pc.store_code,
             NULLIF(regexp_replace(pc.sigma_product_code,'\D','','g'),'')::bigint AS product_code,
             pc.ean,
             CASE pc.ean_category WHEN 'EAN13'          THEN 1
                                  WHEN 'EAN_REAL_SHORT' THEN 2
                                  WHEN 'EAN_SHORT'      THEN 3
                                  WHEN 'PLU'            THEN 4
                                  ELSE 5 END AS cat_rank,
             CASE WHEN pc.ean ~~ (pc.store_code || '%') THEN 1 ELSE 0 END AS store_prefixed
      FROM product_catalog pc
      WHERE pc.store_code = p_store
        AND pc.sigma_product_code ~ '^[0-9]+$'
    ) x
    ORDER BY store_code, product_code, cat_rank, store_prefixed, ean
  ),
  arts AS (
    SELECT store_code, product_code FROM sigma_articles WHERE store_code = p_store
  ),
  base AS (
    -- every identity we know of, from any of the three sources, so nothing is lost
    SELECT store_code, product_code FROM arts
    UNION SELECT store_code, product_code FROM native_pick
    UNION SELECT store_code, product_code FROM cat
  )
  SELECT b.store_code, b.product_code,
         COALESCE(n.ean, c.ean) AS ean,
         CASE
           WHEN n.ean IS NOT NULL AND n.code_kind_v2 IN ('FULL13','EAN13_BODY') THEN 'NATIVE_EAN13'
           WHEN n.ean IS NOT NULL AND n.code_kind_v2 = 'UPCA_BODY'              THEN 'NATIVE_UPCA'
           WHEN n.ean IS NOT NULL AND n.code_kind_v2 = 'EAN8'                   THEN 'NATIVE_EAN8'
           WHEN c.ean IS NOT NULL                                               THEN 'CATALOGUE'
           ELSE 'NONE'
         END AS ean_source,
         (n.ean IS NOT NULL) AS is_real,
         COALESCE(n.real_code_count, 0)::smallint AS real_code_count,
         (a.product_code IS NOT NULL) AS in_articles
  FROM base b
  LEFT JOIN native_pick n ON n.store_code = b.store_code AND n.product_code = b.product_code
  LEFT JOIN cat         c ON c.store_code = b.store_code AND c.product_code = b.product_code
  LEFT JOIN arts        a ON a.store_code = b.store_code AND a.product_code = b.product_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- flag shared barcodes (two products, one key). SURFACED, never resolved here:
  -- these are l2_link_codes_queue candidates (the successor/recode signature).
  UPDATE l2_ean_resolved t SET ean_shared = true
  WHERE t.store_code = p_store AND t.ean IS NOT NULL
    AND EXISTS (SELECT 1 FROM l2_ean_resolved o
                WHERE o.store_code = t.store_code AND o.ean = t.ean
                  AND o.product_code <> t.product_code);

  SELECT count(*) FILTER (WHERE ean_source LIKE 'NATIVE%'),
         count(*) FILTER (WHERE ean_source = 'CATALOGUE'),
         count(*) FILTER (WHERE ean_source = 'NONE'),
         count(*) FILTER (WHERE ean_shared),
         count(*) FILTER (WHERE is_real)
    INTO v_native, v_cat, v_none, v_shared, v_real
  FROM l2_ean_resolved WHERE store_code = p_store;

  -- no silent empties (canon SS8.6 guard 4)
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'refresh_l2_ean_resolved(%): 0 rows -- refusing a false green', p_store;
  END IF;

  RETURN jsonb_build_object(
    'store_code', p_store, 'rows', v_rows,
    'native', v_native, 'catalogue_fallback', v_cat, 'no_key', v_none,
    'real', v_real, 'ean_shared', v_shared,
    'refreshed_at', now());
END $fn$;

-- R30 addendum extension: a MUTATING function ships REVOKE FROM PUBLIC *and*
-- FROM anon by name (Supabase's default privileges grant anon EXECUTE directly,
-- and a role grant survives a REVOKE FROM PUBLIC -- the trap has fired 4x now).
REVOKE ALL     ON FUNCTION public.refresh_l2_ean_resolved(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_ean_resolved(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_ean_resolved(text) TO authenticated;

-- Live at build (2026-07-26), per store: rows / native / catalogue-fallback / no-key / shared
--   10116 70,363 / 54,156 / 3,412 / 12,795 / 44
--   21355 52,913 / 46,569 /    41 /  6,303 /  8
--   80175 55,973 / 46,628 /   963 /  8,382 /  2
--   80176 46,883 / 42,465 /    54 /  4,364 / 10
--   80579 52,066 / 45,812 /    42 /  6,212 /  2
-- Wired into refresh_l2_pipeline immediately after the L2 matview chain and
-- BEFORE every bridge consumer. See sql/create_refresh_l2_pipeline.sql.
