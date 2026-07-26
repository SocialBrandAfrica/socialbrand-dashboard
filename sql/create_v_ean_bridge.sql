-- =============================================================================
-- create_v_ean_bridge.sql
-- THE CANONICAL EAN BRIDGE. One EAN per (store_code, product_code).
-- =============================================================================
-- Version : 2.0 (Identity Phase 2 -- native-first)
-- Date    : 2026-07-26
-- Ref     : CANON SS17 (Identity Layer), RULE-BOOK SS8 (R20 + the R20/R25 note),
--           reference_v_ean_bridge
-- Owner   : CC
-- Applied : migration phase2_02_v_ean_bridge_native_first_over_resolved_identity
--
-- WHAT CHANGED IN v2. The bridge is now a THIN VIEW over l2_ean_resolved
-- (native sigma_scan_refs first via v_scan_ref_decoded, product_catalog only as
-- fallback). Before, it was built ENTIRELY on product_catalog -- the monthly
-- DIWAAIS2 spreadsheet, 2.2%-43% coverage per store, last pulled 2026-05-24 --
-- while native sigma_scan_refs refreshed nightly at 83%-94%. That was the
-- R25 SS2 break: a canonical object standing on a derivative. It is retired.
--
-- The v1 fan-out fix it replaces is PRESERVED, not discarded: the canon SS8.4
-- dedup order (real GS1 first EAN13 > UPC-A > EAN-8, store-prefixed derived
-- codes deprioritised, MIN(ean) deterministic tiebreak) now lives inside
-- refresh_l2_ean_resolved. The CAMEL ONE BOX case v1 was written for
-- (10116 product 34937 carrying both '1011642139126' PLU and '42139126' real)
-- still resolves to exactly one key, and the +R138 fan-out still cannot recur.
--
-- CREATE OR REPLACE, deliberately NOT a DROP. The column contract
-- (store_code text, product_code bigint, ean text) is unchanged, so none of the
-- 31 live dependents move. That list was re-derived from the catalog 2026-07-26
-- because CANON SS17's "7 DB dependents" was stale -- the same defect class as
-- the twice-stale l2_stock_position dependent list (canon SS13). The true set:
--   views/matviews (4): mv_rate_of_sale, v_diwaais, v_focus_trend,
--     v_top_products_by_date
--   functions (27): refresh_l2_bloom_promo_pantry, refresh_l2_bloom_ros_pantry,
--     refresh_l2_bt_heroes, refresh_l2_bt_tail, refresh_l2_export_key,
--     refresh_l2_kvi_cross_store, rpc_all_rows, rpc_bloom_order_dc,
--     rpc_bloom_order_direct_beer, rpc_bloom_order_recipe,
--     rpc_bloom_relist_queue, rpc_dept_summary, rpc_focus_chart,
--     rpc_focus_top5, rpc_ghost_stock_report, rpc_kpi_dept_counts,
--     rpc_lost_sales_oos, rpc_lost_sales_timeline, rpc_pmini_sales_history,
--     rpc_pmini_snapshot, rpc_product_detail, rpc_report_rows,
--     rpc_search_products, rpc_stock_integrity_report,
--     rpc_stock_report_engine, rpc_top20, upsert_search_index
-- Re-derive with pg_get_viewdef / pg_proc.prosrc ILIKE '%v_ean_bridge%' before
-- ever rebuilding this object -- a dependent list is a snapshot, not a fact.
--
-- FAN-OUT SAFETY (R20) UNCHANGED: (store_code, product_code) is unique --
-- verified live 240,142 rows / 240,142 distinct keys / 0 dupes (v1 was 42,900).
--
-- ⚠️ AN EAN IS *NOT* UNIQUE WITHIN A STORE. 66 products share a barcode with
-- another product (l2_ean_resolved.ean_shared, 33 groups). The v1 catalogue
-- bridge showed 0 such cases only because its coverage was too thin to see them.
-- These are the recode/successor signature (same description, same pack_content,
-- a newer code shadowing an older one) and they are emitted to
-- l2_link_codes_queue as CANDIDATES. Consumers that key on ean alone --
-- product_search_index is PK'd on ean -- MERGE those products into one row,
-- which is correct for a genuine duplicate identity and was verified not to
-- error (upsert_search_index + REFRESH mv_rate_of_sale both clean, 2026-07-26).
--
-- R22 GATE THAT MUST HOLD ON ANY CHANGE HERE (R20 addendum): every EAN-grain
-- SALES aggregate LEFT JOINs this bridge and COALESCEs a synthetic key, so the
-- store total must still equal the raw sigma_sales total. Verified at the
-- repoint: delta R0.0000 on all five stores.
--
-- COVERAGE WON (measured ×5): native real-EAN vs the v1 catalogue bridge --
-- 10116 77.4% vs 43.0% · 21355 88.4% vs 2.5% · 80175 83.7% vs 16.0% ·
-- 80176 91.1% vs 2.6% · 80579 88.4% vs 2.2%. On mv_rate_of_sale the key is now
-- 78-91% real per store, which RETIRES canon's "treat TOPS EAN-grain coverage
-- as synthetic-dominant" (RULE-BOOK SS8 R20/R25 note).
--
-- product_catalog is NOT retired by this change -- it survives as the fallback
-- inside l2_ean_resolved (4,512 rows group-wide still resolve only through it).
-- Retiring it is Phase 3, once those have native homes.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_ean_bridge AS
SELECT store_code, product_code, ean
FROM public.l2_ean_resolved
WHERE ean IS NOT NULL;

COMMENT ON VIEW public.v_ean_bridge IS
  'Canonical EAN bridge: one EAN per (store_code, product_code). Identity Phase 2 (2026-07-26) -- now a thin view over l2_ean_resolved (native sigma_scan_refs first via v_scan_ref_decoded, product_catalog fallback only), retiring the R25 SS2 break. Output contract unchanged for its 31 dependents. Fan-out safety unchanged: (store_code, product_code) is unique. NOTE: an ean is NOT unique within a store -- 66 products share a barcode with another product (l2_ean_resolved.ean_shared), surfaced as l2_link_codes_queue candidates, never auto-resolved.';

GRANT SELECT ON public.v_ean_bridge TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
