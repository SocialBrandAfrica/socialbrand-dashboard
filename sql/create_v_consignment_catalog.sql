-- create_v_consignment_catalog.sql
-- SB-CC-PMINI-WIRE-001 (2026-06-17) — single home of the consignment sushi/Chinese rule.
--
-- STATUS: STAGED — DO NOT RUN until PM signs the Pulse Mini close-out plan.
--   This is a read-only VIEW (no DML, no grant to a write role). It is safe in
--   isolation, but it is part of the staged Pulse Mini bundle and lands together.
--
-- WHY THIS VIEW
--   The sushi ('s') vs Chinese/other ('c') split is a MENU attribute, not a
--   behavioural one — there is no sales/SOH signal that distinguishes a sushi
--   platter from a chow-mein. Per R21 §4 that makes it the human-guidance
--   exception path: a curated menu PLU set. We keep that rule in EXACTLY ONE
--   place (this view) so neither the refresh function nor any RPC recomputes
--   classification inline (NORTH_STAR principle, R21 §2/§3).
--
-- R25 NATIVE SOURCE (the actual fix)
--   The old path read sigma_ean_master.barcode and tested (barcode - 200000) in
--   the SUSHI_PLUS set. After the product-code recycling, sigma_ean_master no
--   longer holds 200000+ scale barcodes for these codes, so EVERY line collapsed
--   to 'c' (schema note 2026-06-08). The Sigma-native scan-reference table
--   sigma_scan_refs (dw220sdb.DBREFE) DOES carry the 200000+ scale PLU as a
--   code_kind='PLU' row (e.g. COMBO 1 -> '200653' -> 653). Re-sourcing the rule
--   here restores the split. Proven live 2026-06-17 (store 10116):
--     catalog 102 articles -> 62 sushi / 36 chinese / 4 no-scale-PLU
--     sold June 43 products -> 22 sushi / 21 chinese, 0 combos misclassified.
--   Mirrors v_item_ean's blocked-flag guard (SB-CC-SOURCE-001 / R25).
--
-- GRAIN: one row per (client_id, store_code, product_code) in merch_group 610,
--   after the BREAKFAST/MABELA exclusion (matches l2_consignment_daily scope).
--   Covers all stores' group 610 for portability (R25 config-not-hardcode); only
--   10116 currently runs a consignment counter, and the SUSHI_PLUS menu is its
--   menu — other stores' group 610 (if any) simply classify by the same set.
--
-- KNOWN GAP (flagged to PM, NOT silently patched — R21 §4 / R27.7)
--   COMBO 12 (PLU 833) is absent from SUSHI_PLUS, so it would classify 'c' if it
--   ever sells (it did not sell in June, so no live impact). A more robust general
--   rule would be "description ILIKE 'COMBO%' => 's'" (combos are sushi platters).
--   Left as the existing PLU-set rule pending PM ratification; see the commented
--   COMBO clause below to flip it on.

-- Rule 19: DROP first, then clean CREATE.
DROP VIEW IF EXISTS v_consignment_catalog;

CREATE VIEW v_consignment_catalog AS
WITH plu AS (
  SELECT
    a.client_id,
    a.store_code,
    a.product_code,
    a.description,
    -- The Sigma scale PLU = the 200000+ DBREFE scan code minus 200000.
    -- An article carries two PLU rows (e.g. '200653' and the short '65301');
    -- only the 200000-299999 form decodes cleanly to the menu PLU.
    MAX(CASE
          WHEN sr.code_kind = 'PLU'
           AND sr.barcode_full ~ '^[0-9]+$'
           AND sr.barcode_full::bigint BETWEEN 200000 AND 299999
          THEN sr.barcode_full::bigint - 200000
        END) AS plu_num
  FROM sigma_articles a
  LEFT JOIN sigma_scan_refs sr
    ON  sr.client_id    = a.client_id
    AND sr.store_code   = a.store_code
    AND sr.product_code = a.product_code
    AND COALESCE(sr.blocked_flag, '0') NOT IN ('1', '-1')   -- mirror v_item_ean
  WHERE a.merch_group_nr = 610
    AND a.description NOT ILIKE 'BREAKFAST%'
    AND a.description NOT ILIKE 'MABELA%'
  GROUP BY a.client_id, a.store_code, a.product_code, a.description
)
SELECT
  client_id,
  store_code,
  product_code,
  description,
  plu_num,
  CASE
    -- WHEN description ILIKE 'COMBO%' THEN 's'   -- PROPOSED combo rule (PM ratify)
    WHEN plu_num = ANY(ARRAY[
      653,650,895,888,863,851,846,844,843,841,835,533,831,824,818,810,792,790,
      785,778,773,767,766,749,747,832,762,737,722,744,718,715,9677,710,700,736,
      632,638,597,307,308,309,889,924,930,599,699,694,693,696,695,697,698,840,
      836,897,834,809,806,803,784,771,748,753
    ]::bigint[]) THEN 's'
    ELSE 'c'
  END AS item_type
FROM plu;

COMMENT ON VIEW v_consignment_catalog IS
  E'GRADE: CALCULATED. Consignment menu classification per group-610 article, mapped from the Sigma scale PLU.
'
  'Consignment menu classifier (SB-CC-PMINI-WIRE-001). One row per group-610 '
  'article per store. item_type s/c from the Sigma-native scale PLU '
  '(sigma_scan_refs DBREFE 200000+ code minus 200000) vs the SUSHI_PLUS menu set. '
  'Single home of the sushi/Chinese rule (R21). Read by refresh_l2_consignment_daily '
  'and rpc_consignment_lines. R25 native source — replaces sigma_ean_master.';

GRANT SELECT ON v_consignment_catalog TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verification (run AFTER deploy, store 10116) — expect ~62 s / ~36 c / 4 none:
--   SELECT item_type, COUNT(*) FROM v_consignment_catalog
--   WHERE store_code='10116' GROUP BY item_type ORDER BY item_type;
-- ---------------------------------------------------------------------------
