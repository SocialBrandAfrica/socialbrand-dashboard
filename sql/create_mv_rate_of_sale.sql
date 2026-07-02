-- =============================================================================
-- create_mv_rate_of_sale.sql
-- SB-CC-RETIRE-003 (2026-07-02, CC) -- fully sigma-native repoint.
-- STATUS: DEPLOYED LIVE 2026-07-02 via retire003_mv_rate_of_sale_sigma_native
--   (+ hotfix v2 for the PK collision, see below).
-- =============================================================================
-- WHY (SB-PRIORITY-FRAMEWORK-001 v1.1 sequencing -- this closed BEFORE Bloom
-- code started, per Pieter's ruling that Tier 1 stays clean while Bloom runs
-- as a parallel tributary):
--   daily_ros/days_cover were already sigma-native (SB-CC-DASH-SOURCE-002,
--   2026-06-13 -- see prior header below). But SOH/price/dept facts still came
--   from the frozen daily_snapshots "latest" CTE. PRSSALE write-retired
--   2026-06-28 (SB-CC-PRSSALE-RETIRE-001) -> that CTE's snapshot froze the
--   same day. Every product-detail SOH and days-cover lookup on the platform
--   was therefore up to 4+ days stale, silently, system-wide.
--
-- NEW SOURCE: l2_stock_position (sigma-native, always-latest, refreshed ahead
--   of this matview in refresh_l2_pipeline) already carries soh, unit_cost,
--   sell_price_incl_vat, dept_name, subdept_name, department_nr, merch_group_nr
--   AND daily_ros/days_cover pre-computed from l2_rate_of_sale's 91d window
--   (RULE-BOOK ROS formula) -- reused directly, not recomputed here.
--
-- EAN KEYING (R20 addendum -- coverage, not a total): LEFT JOIN v_ean_bridge +
--   COALESCE synthetic EAN (lpad(store_code,5,'0') || lpad(product_code,8,'0')),
--   identical convention to the RETIRE-002 objects (v_focus_trend etc). PLU/
--   scale lines with no real GS1 EAN still surface a row.
--
-- PK COLLISION (found on first apply, hotfixed same session): UNIQUE
--   (store_code, ean) failed -- product 28880 @ 80176 has a REAL bridged ean
--   (8017600000010, a store-prefixed short code) that is byte-identical to
--   product 10's SYNTHETIC fallback key at the same store (same store prefix +
--   zero-padded product_code format coincide). Real-vs-synthetic namespace
--   collision, not fixable by reformatting the synthetic scheme (any fixed-
--   width scheme risks the same coincidence). l2_stock_position's own PK is
--   (client_id, store_code, product_code) -- rebuilt the unique index on
--   (store_code, product_code), the true identity, with a plain (non-unique)
--   index on (ean, store_code) for the frontend's .eq('ean', ean) lookups.
--   Two product_codes CAN legitimately share a displayed ean after this
--   change (recycled/duplicate-code reality, already documented canon) --
--   frontend ean lookups return all matching rows, same as any other EAN
--   collision in the raw data.
--
-- COLUMN GAPS (R23 L1, same convention as the RETIRE-002 objects):
--   status -- no sigma-native decode yet, NULL (was daily_snapshots.status).
--   internal_ref -- NOT a gap: product_code::text IS the authoritative value
--     (product_catalog.sigma_product_code = internal_ref in daily_snapshots).
--   dept_code / sub_dept_code -- LPAD(department_nr,6,'0') / LPAD(merch_group_nr,9,'0'),
--     same convention as rpc_all_rows (RETIRE-002 obj 10).
--
-- CANON DEBT CLOSED: added to CLEANUP-ENGINE-CANON section 13's mandatory
--   CASCADE-rebuild list (now four objects downstream of l2_stock_position:
--   v_kpi_by_date, mv_kpi_by_date, mv_sparkline_14d, mv_rate_of_sale). Any
--   future l2_stock_position rebuild must recreate this matview + both
--   indexes in the same deploy, or the CASCADE silently drops it (the exact
--   2026-07-01 outage class).
--
-- FRONTEND: zero edits needed. Column set, matview name, REFRESH ...
--   CONCURRENTLY (pg_cron nightly-ros-refresh, 22:30 UTC) unchanged. Verified
--   live consumers (page.jsx x2, ProductDetailPanel.jsx x2) only ever select
--   ean, store_code, store_name, soh, daily_ros, days_cover.
--
-- R22 verified on apply: l2_stock_position.positioned_at = 2026-07-01 20:15
--   UTC (today's pipeline run) vs daily_snapshots frozen 2026-06-28 -- the
--   staleness this repoint fixes, proven. Row counts unchanged per store
--   (10116 70,018 / 21355 52,627 / 80175 55,653 / 80176 46,592 / 80579 51,797).
--
-- Rule 19: DROP + clean CREATE. Rule lineage (R28): effective_from 2026-07-02,
--   scope GENERAL (portable formula, no demo-store constants). Supersedes the
--   2026-06-13 hybrid body below (retired 2026-07-02).
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS public.mv_rate_of_sale CASCADE;

CREATE MATERIALIZED VIEW public.mv_rate_of_sale AS
SELECT
  sp.store_code,
  st.store_name,
  sp.product_code,
  COALESCE(b.ean, lpad(sp.store_code, 5, '0') || lpad(sp.product_code::text, 8, '0')) AS ean,
  sp.description,
  sp.dept_name,
  sp.subdept_name AS sub_dept_name,
  lpad(sp.department_nr::text, 6, '0') AS dept_code,
  lpad(sp.merch_group_nr::text, 9, '0') AS sub_dept_code,
  sp.soh,
  sp.sell_price_incl_vat AS sell_price,
  sp.unit_cost,
  NULL::text AS status,
  sp.product_code::text AS internal_ref,
  sp.daily_ros,
  sp.days_cover
FROM public.l2_stock_position sp
LEFT JOIN public.v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
LEFT JOIN public.stores st ON st.store_code = sp.store_code;

CREATE UNIQUE INDEX mv_rate_of_sale_pk ON public.mv_rate_of_sale (store_code, product_code);
CREATE INDEX mv_rate_of_sale_ean ON public.mv_rate_of_sale (ean, store_code);

GRANT SELECT ON public.mv_rate_of_sale TO anon, authenticated;

-- =============================================================================
-- PRIOR HEADER (2026-06-13, SB-CC-DASH-SOURCE-002) -- kept for history, body
-- retired above:
--   HYBRID migration (per PM qty/ROS ruling): ROS (SALES FACT) -> sigma_sales,
--   daily_ros = SUM(qty over 91d)/91 in selling-units, keyed via v_ean_bridge,
--   91d window anchored on MAX(sale_date). SOH + dims + sell_price + unit_cost
--   + status (STOCK FACTS) STAYED on daily_snapshots pending "the coordinated
--   stock step" -- that step is this file's 2026-07-02 rewrite.
--   Known caveat then (SRC-001 product_catalog dup, 10116 product 34937) is
--   moot now -- ean keying no longer crosses two different sources.
-- =============================================================================
