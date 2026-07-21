-- =============================================================================
-- create_l2_export_key.sql
-- TRACK A ITEM 1 (PM ruling 2026-07-21) -- THE EXPORT-ELIGIBILITY PANTRY FACT.
-- Applied 2026-07-21, migrations a1_l2_export_key_pantry_fact
-- + a1_wire_l2_export_key_into_pipeline.
--
-- Closes BUG-LOG ENG-031: all three exportTlx() builders in src/app/bloom/page.jsx
-- guard with `if (q <= 0 || !l.ean) continue`, and the comment beside it states that
-- no-EAN lines never ride the TLX. That guard has been DEAD CODE since 2026-06-30 --
-- the R20-addendum COALESCE made `ean` never null, so manufactured store-prefixed
-- keys ride the TLX, Sigma cannot match them on import and silently drops the lines.
-- The buyer sees 1,891 exported and Sigma receives 1,845, with nothing on screen
-- saying so. That is the bad failure mode (R22, no silent drops). Canon SS8.4
-- ("synthetic NEVER exports to TLX") and SS14 v7 item 11 ("unresolvable lines never
-- ride it") both already forbade it; nothing enforced it.
--
-- PLACEMENT (PM ruling): ONE L2 pantry fact per (store_code, product_code),
-- engine-owned and native-sourced, read by desks and exporters alike. The frontend
-- never decides what a real barcode is (R21, R30). R32 clean -- a pantry debt paid
-- in L2 for everyone, never a bespoke patch for one screen.
--
-- ⭐ THE TEST IS DELIBERATELY NARROW, and this is the load-bearing choice.
-- A line is INELIGIBLE only where the key is one WE MANUFACTURED:
--   (a) SYNTHETIC_FALLBACK   -- no v_ean_bridge row at all, so the R20 COALESCE built
--                               store_code || lpad(product_code,8) itself;
--   (b) BRIDGE_PLU_SYNTHETIC -- a bridge row exists but it is a product_catalog
--                               PLU-category row, whose `ean` is that same
--                               store-prefix construction (v_ean_bridge ranks PLU
--                               last but still returns it when it is all there is).
-- It does NOT judge whether Sigma holds a given REAL code. That is precisely the
-- `DBREFE.type_flag = 3` question Track B Phase 0 must read at source, and pre-empting
-- it here would cost real orders on a hypothesis -- so the 45 short-but-real barcodes
-- stay on the TLX.
--
-- Both ineligible classes carry a structural belt: the key must ALSO literally be the
-- store-prefixed construction. A PLU-category row whose code is NOT store-prefixed is
-- a mis-categorised real short code and stays ELIGIBLE. The conservative direction is
-- deliberate: a wrong exclusion costs a real order, a wrong inclusion costs one
-- dropped TLX line which the reason column now surfaces anyway.
--
-- PERMANENT, not interim (PM). Once Track B repairs identity, more lines earn a real
-- key and ride; the gate keeps holding and the excluded set shrinks. The fact's SHAPE
-- does not change, and Phase 2's `l2_product_resolution` absorbs it rather than
-- replacing it.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_export_key (
  client_id         text        NOT NULL DEFAULT 'socialbrand',
  store_code        text        NOT NULL,
  product_code      bigint      NOT NULL,
  export_key        text        NOT NULL,   -- the key an export WOULD emit today
  key_source        text        NOT NULL,   -- BRIDGE_EAN13 | BRIDGE_EAN_REAL_SHORT | BRIDGE_EAN_SHORT | BRIDGE_OTHER | BRIDGE_PLU_SYNTHETIC | SYNTHETIC_FALLBACK
  export_eligible   boolean     NOT NULL,
  ineligible_reason text,                   -- NULL exactly when eligible (CHECK below)
  resolved_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code),
  CONSTRAINT l2_export_key_reason_ck
    CHECK ((export_eligible AND ineligible_reason IS NULL)
        OR (NOT export_eligible AND ineligible_reason IS NOT NULL))
);

COMMENT ON TABLE public.l2_export_key IS
  'Track A item 1 / ENG-031. One row per (store_code, product_code): the key an export would emit today, where it came from, and whether Sigma can match it. Ineligible ONLY when the key is one we manufactured (no bridge row, or a PLU-category store-prefixed catalogue key). Never judges whether Sigma holds a real code -- that is Track B Phase 0. Read by the TLX exporters via rpc_bloom_export_eligibility; the frontend never re-derives identity.';

CREATE INDEX IF NOT EXISTS l2_export_key_ineligible_idx
  ON public.l2_export_key (store_code) WHERE NOT export_eligible;

ALTER TABLE public.l2_export_key ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_export_key_read ON public.l2_export_key;
CREATE POLICY l2_export_key_read ON public.l2_export_key FOR SELECT USING (true);
GRANT SELECT ON public.l2_export_key TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_export_key(p_store text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_rows int; v_inelig int; v_plu int; v_nobridge int;
BEGIN
  DELETE FROM l2_export_key WHERE store_code = p_store;

  INSERT INTO l2_export_key (store_code, product_code, export_key, key_source, export_eligible, ineligible_reason)
  SELECT k.store_code, k.product_code, k.export_key, k.key_source,
         k.key_source NOT IN ('SYNTHETIC_FALLBACK','BRIDGE_PLU_SYNTHETIC') AS export_eligible,
         CASE k.key_source
           WHEN 'SYNTHETIC_FALLBACK'   THEN 'no_bridge_row_key_manufactured'
           WHEN 'BRIDGE_PLU_SYNTHETIC' THEN 'plu_synthetic_key'
         END
  FROM (
    SELECT a.store_code, a.product_code,
           -- byte-identical to rpc_bloom_order_recipe's own key construction, so the
           -- fact describes the key the export actually carries (R22-verified: 0
           -- mismatches across 1,802 ordered lines at 10116 DC_AMBIENT).
           COALESCE(b.ean, lpad(a.store_code,5,'0') || lpad(a.product_code::text,8,'0')) AS export_key,
           CASE
             WHEN b.ean IS NULL THEN 'SYNTHETIC_FALLBACK'
             WHEN pc.ean_category = 'PLU'
                  AND b.ean = lpad(a.store_code,5,'0') || lpad(NULLIF(regexp_replace(COALESCE(pc.plu_raw,''), '\D', '', 'g'), '')::text, 8, '0')
               THEN 'BRIDGE_PLU_SYNTHETIC'
             WHEN pc.ean_category = 'EAN13'          THEN 'BRIDGE_EAN13'
             WHEN pc.ean_category = 'EAN_REAL_SHORT' THEN 'BRIDGE_EAN_REAL_SHORT'
             WHEN pc.ean_category = 'EAN_SHORT'      THEN 'BRIDGE_EAN_SHORT'
             ELSE 'BRIDGE_OTHER'
           END AS key_source
    FROM sigma_articles a
    LEFT JOIN v_ean_bridge b     ON b.store_code = a.store_code AND b.product_code = a.product_code
    LEFT JOIN product_catalog pc ON pc.store_code = a.store_code AND pc.ean = b.ean
    WHERE a.store_code = p_store
  ) k;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT count(*) FILTER (WHERE NOT export_eligible),
         count(*) FILTER (WHERE ineligible_reason = 'plu_synthetic_key'),
         count(*) FILTER (WHERE ineligible_reason = 'no_bridge_row_key_manufactured')
    INTO v_inelig, v_plu, v_nobridge
  FROM l2_export_key WHERE store_code = p_store;

  -- no silent empties (canon SS8.6 guard 4)
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'refresh_l2_export_key(%): 0 rows -- store has no sigma_articles, refusing a false green', p_store;
  END IF;

  RETURN jsonb_build_object(
    'store_code', p_store, 'rows', v_rows,
    'ineligible', v_inelig, 'plu_synthetic_key', v_plu,
    'no_bridge_row_key_manufactured', v_nobridge,
    'refreshed_at', now());
END $fn$;

REVOKE ALL ON FUNCTION public.refresh_l2_export_key(text) FROM PUBLIC;
-- anon MUST be revoked BY NAME. Supabase's default-privilege auto-grant hands new
-- functions EXECUTE to anon and a plain REVOKE ... FROM PUBLIC does not clear it
-- (RULE-BOOK R30 addendum 2026-07-07; same class caught on the BLOOM-004 write RPCs
-- 2026-07-11). Verified live after applying: acl carries no anon entry. This function
-- MUTATES and is SECURITY DEFINER -- anon EXECUTE on it would be a real hole.
REVOKE EXECUTE ON FUNCTION public.refresh_l2_export_key(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.refresh_l2_export_key(text) TO authenticated;

-- Wired into refresh_l2_pipeline after the last_counted loop (per-store guarded, same
-- pattern as every other loop). See sql/create_refresh_l2_pipeline.sql.
--
-- Live at build (2026-07-21), whole-catalogue counts -- the ineligible share is large
-- because v_ean_bridge itself covers only 2.2%-43% of articles per store (that is
-- ENG-032, a separate defect this fact merely MEASURES rather than causes):
--   10116 70,243 rows / 43,053 ineligible (2,981 PLU + 40,072 no-bridge)
--   80175 55,914 / 47,781 (818 + 46,963)
--   21355 52,865 / 51,546 (5 + 51,541)
--   80176 46,829 / 45,640 (20 + 45,620)
--   80579 52,021 / 50,868 (13 + 50,855)
-- The number that matters is on ORDERED lines: 10116 DC_AMBIENT, 1,802 ordered lines
-- / R772,780.28, of which 44 lines / R11,107.10 are ineligible (26 PLU-synthetic +
-- 18 no-bridge). That reproduces ENG-031's own independent measurement (46 lines /
-- R11,439 on a 1,891-line order 12 days out) within order-date drift.
