-- =============================================================================
-- create_v_family_days_cover.sql
-- BUG-LOG ENG-073 / SB-CC-BLOOM-020 item 1 -- the DISPLAY-side read.
-- Deployed 2026-08-07 via migration eng073_v_family_days_cover. Canonical source.
-- =============================================================================
-- WHY A VIEW AND NOT A COLUMN ON mv_rate_of_sale.
--   The Top 20 days-cover column and product detail do NOT get cover from
--   rpc_top20 -- that function returns no cover at all. They read
--   `mv_rate_of_sale`, which is one of canon s13's CASCADE-class SEVEN. Adding a
--   column there means DROP + CREATE plus recreating BOTH its indexes
--   (mv_rate_of_sale_pk on (store_code, product_code) -- deliberately NOT ean,
--   see that file's header for the real-vs-synthetic EAN collision -- and
--   mv_rate_of_sale_ean) on the live display chain. Canon s13 rule 3: never
--   hand-paste an engine rebuild into live prod during trading. It was written
--   the day exactly that took the dashboard down.
--   This view carries the same facts with no drop, no cascade and no rebuild, so
--   the screen is corrected now and the matview's own column-level repoint stays
--   a scheduled off-hours job.
--
-- KEYED BOTH WAYS ON PURPOSE. product_code is the true identity; ean is what the
--   Top 20 and product-detail surfaces actually hold. The bridge is LEFT JOINed
--   and never INNER -- an INNER join drops every PLU/scale line, measured at
--   -8.9% to -48% of real sales when that was got wrong on the by-date objects
--   (R20 addendum). 413 lines group-wide have no bridge EAN and are kept.
--
-- MEASURED AT BUILD, 2026-08-07: 679 lines group-wide where the displayed cover
--   understates the family (10116 85 / 21355 203 / 80175 64 / 80176 167 /
--   80579 160), against ENG-005's own stated 729. Worst ratio 2,778x at 10116.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_family_days_cover AS
SELECT
  f.store_code,
  f.product_code,
  b.ean,
  f.family_key,
  f.level,
  f.pack_multiple,
  f.is_stock_holder,
  f.family_member_count,
  f.scan_daily_ros_91d,
  CASE WHEN COALESCE(f.scan_daily_ros_91d,0) > 0
       THEN ROUND(sp.soh / f.scan_daily_ros_91d, 4) END  AS scan_days_cover,
  f.family_daily_ros_91d,
  f.family_soh_singles,
  f.family_days_cover,
  f.family_ratio,
  (f.family_ratio IS NOT NULL AND f.family_ratio >= 1.5)  AS display_understates,
  f.resolution_confidence,
  f.story,
  f.computed_at
FROM l2_family_ros f
JOIN l2_stock_position sp
  ON sp.client_id = f.client_id AND sp.store_code = f.store_code
 AND sp.product_code = f.product_code
LEFT JOIN v_ean_bridge b
  ON b.store_code = f.store_code AND b.product_code = f.product_code;

GRANT SELECT ON public.v_family_days_cover TO anon, authenticated;

COMMENT ON VIEW public.v_family_days_cover IS
  'ENG-073 display read. Family-resolved days cover per (store, product/ean) with the raw scan figures beside it. Additive: no existing object changed, so no canon s13 CASCADE rebuild. mv_rate_of_sale keeps its own scan-keyed columns until its column-level repoint runs off-hours.';
