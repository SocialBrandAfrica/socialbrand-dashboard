-- =============================================================================
-- create_v_ean_bridge.sql
-- SB-CC-DASH-SOURCE-002 (SB-INDEX-005 Phase 2) -- shared dashboard bridge.
-- Deployed live via Supabase MCP migration dash_source_002_create_v_ean_bridge.
-- =============================================================================
-- WHY:
--   The dashboard source migration aggregates sigma_sales (keyed by sigma
--   product_code) but the page output is keyed by EAN, so every migrated RPC
--   bridges product_code -> ean via product_catalog. product_catalog can hold
--   MORE THAN ONE ean for a single (store_code, product_code) -- e.g. 10116
--   product 34937 "CAMEL ONE BOX" = '1011642139126' (PLU, store-prefixed
--   10116+42139126) + '42139126' (EAN_REAL_SHORT, the real code). A raw join
--   then counts that product's sales under BOTH eans -> fan-out (10116 +R138.00
--   over a 14-day window; 0.005%).
--
-- FIX (once, shared): this view exposes exactly ONE canonical ean per
--   (store_code, product_code). Every migrated RPC (rpc_focus_top5 / focus_chart
--   / lost_sales_timeline, and the coming rpc_top20 / mv_rate_of_sale) joins
--   THIS, never product_catalog directly, so the fan-out cannot recur.
--
-- DEDUP ORDER (RULE-BOOK section 8.4 ean_kind): real GS1 first (EAN13 >
--   EAN_REAL_SHORT > EAN_SHORT > PLU), store-prefixed derived codes dropped,
--   MIN(ean) as the final deterministic tiebreak.
--
-- Verified live: 42,900 rows == 42,900 distinct (store, product_code) keys
--   (1:1); 34937 -> '42139126'; 10116 14-day reconcile new_delta 0.00 vs the
--   once-per-product_code truth (old raw-catalog bridge was +138.00).
--
-- product_catalog source dup '34937' (and any sibling the dedup collapses)
--   logged to BUG-LOG.md for the Sigma cleanup queue.
-- =============================================================================

CREATE OR REPLACE VIEW v_ean_bridge AS
SELECT DISTINCT ON (store_code, product_code)
       store_code,
       product_code,
       ean
FROM (
  SELECT pc.store_code,
         NULLIF(regexp_replace(pc.sigma_product_code, '\D', '', 'g'), '')::bigint AS product_code,
         pc.ean,
         CASE pc.ean_category
           WHEN 'EAN13'          THEN 1
           WHEN 'EAN_REAL_SHORT' THEN 2
           WHEN 'EAN_SHORT'      THEN 3
           WHEN 'PLU'            THEN 4
           ELSE 5
         END AS cat_rank,
         CASE WHEN pc.ean LIKE pc.store_code || '%' THEN 1 ELSE 0 END AS store_prefixed
  FROM   product_catalog pc
  WHERE  pc.sigma_product_code ~ '^[0-9]+$'
) x
ORDER BY store_code, product_code, cat_rank, store_prefixed, ean;

GRANT SELECT ON v_ean_bridge TO anon, authenticated;
