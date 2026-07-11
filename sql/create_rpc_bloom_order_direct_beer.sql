-- =============================================================================
-- rpc_bloom_order_direct_beer -- SB-CC-BLOOM-003 Ship 1.
-- The direct-beer route recipe: SAME tier/ROS/life-gate shape as canon §14 /
-- rpc_bloom_order_dc (raw ROS, no rhythm/KVI yet -- that is Ship 2), scoped to
-- bloom_route_config's DIRECT_BEER merch groups instead of the DC dept cycle,
-- plus a sibling/family roll-up (case<->single, canon §8.12/parent-child rule)
-- so a quiet pack code is not blocked by the life gate when its single (or
-- vice versa) proves live demand. Every row carries its story (R29).
--
-- Uses the same dynamic-SQL-with-literals pattern as rpc_bloom_order_dc
-- (format() + EXECUTE) -- not just for planner reasons here (the pool is much
-- smaller, a few hundred rows), but because RETURNS TABLE's own output column
-- names (product_code, soh, tier, description, ...) shadow bare CTE column
-- references inside plain plpgsql, causing "ambiguous column" errors. Dynamic
-- SQL text is parsed standalone, sidestepping the shadowing entirely.
-- =============================================================================
-- ENG-009 (2026-07-11, SB-CC-BLOOM-005 item 4, PM ruling 2026-07-10). This
--   recipe rated demand on RAW calendar ROS only (the `sales` CTE, scan-only,
--   no stockout correction, no family draw) -- under-ordering SAB/direct beer
--   ~3x group-wide, 5.8x at 80176 (BUG-LOG ENG-009). Live baseline before this
--   fix, 80176/24169 BLACK LABEL RB: ros_used=18.79/day raw, 3 packs,
--   R554.22 -- against a ~R9k in-stock-days need.
--
--   FIX (identical pattern to rpc_bloom_order_dc post-ENG-005 and
--   l2_stock_band's ENG-004 guard system -- brief's own required precedent):
--   base_pool now LEFT JOINs l2_bloom_ros_pantry (corrected scan + family-draw
--   rates, same 14d/28d/56d windows the tier already resolves to, plus each
--   side's own p_sell_estimate) and l2_kvi_profile (kvi_band, for eligibility).
--   Two sides guarded INDEPENDENTLY before combining:
--     1. Eligibility: KVI_CRITICAL/KVI_IMPORTANT eligible by default; all
--        other tiers/bands need >=8 selling days in the trailing 182d (read
--        off the pantry's own p_sell_estimate x 182). Draw side additionally
--        requires NOT unit_incommensurable (weighed lines carry no valid
--        ledger-qty draw -- moot for beer, EA only, kept for parity).
--     2. Cap: eligible corrected value capped at 2.0x this row's own raw
--        value on that side.
--     3. Ineligible/uncapped-missing sides fall back to raw (scan) or NULL
--        (draw) -- never a wrong number standing in for a real one.
--   Then ros_final = GREATEST(scan_used, COALESCE(draw_used,0)), same
--   governing law as ENG-005/ENG-004: a real till scan is a floor, family
--   draw can raise demand but a ledger gap never lowers it below scan.
--   New output column `demand_source` ('scan' | 'family_draw'), story
--   extended with a family-draw note when it wins (R29). Packs now round UP
--   (CEIL, was FLOOR) per the brief's explicit instruction -- this recipe
--   covers a week, not a floor minimum. RETURNS TABLE signature changed
--   (demand_source added) -- DROP + CREATE (RULE-BOOK §8 function-change
--   protocol, same as ENG-005's dc fix).
--
--   SECOND FIX, folded in as a NECESSARY corollary (found verifying this
--   item, not separately briefed -- same defect CLASS as ENG-008's DC
--   scope-gate, flagged and fixed together rather than left to silently
--   defeat the demand fix): base_pool's OWN population filter was
--   `(q364>0 OR soh<>0)`, a rolling 364-day scan window -- exactly the
--   ENG-008 failure mode. Live proof at 80176: of 293 orderable beer lines
--   (active supplier link, in-route merch group), only 98 have sold inside
--   their own 364d scan window; the other 195 -- precisely the long-OOS
--   lines this fix exists to correct -- were invisible to the pool no matter
--   how good the pantry's corrected rate is. Repointed to the SAME gate
--   ENG-008 established: `l2_stock_position.never_sold=false` (lifetime
--   ever-sold). Safe to widen for the identical reason ENG-008 was safe:
--   base_pool still INNER JOINs `lnk` (active, non-suspended supplier link)
--   and the sibling/own-gate life filter still applies after -- a product
--   with no real order route or no live-or-family-proven demand still
--   cannot get packs suggested, no matter how permissive the history gate is.
--
--   Acceptance (BLOOM-005 §Acceptance): 80176/24169 sizes toward the
--   in-stock-days need, not the raw scan; DC beer (rpc_bloom_order_dc)
--   unchanged (this migration touches only this function); ×3 TOPS stores,
--   0 invariant issues; Capital Tied / KVI band counts unchanged (touches
--   demand math only, this function never reads or writes l2_classification).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_direct_beer(text,date,date,date,date,integer);

CREATE FUNCTION public.rpc_bloom_order_direct_beer(
  p_store_code text, p_delivery_date date, p_next_delivery date,
  p_anchor_date date DEFAULT NULL::date, p_soh_date date DEFAULT NULL::date,
  p_days_cover integer DEFAULT 7
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, merch_group_name text,
  tier text, soh numeric, pack_size smallint, pack_cost numeric,
  ros_window_used text, ros_used numeric, demand_source text, projected_soh numeric, target_days_cover integer,
  trigger_fired boolean, need_units numeric, suggested_packs integer, value numeric,
  family_key text, sibling_gated boolean, supplier_nr bigint, supplier_type text,
  last_receipt_date date, story text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date; v_soh_dt date; v_lead int;
BEGIN
  SET LOCAL statement_timeout = '30s';
  SELECT COALESCE(p_anchor_date, MAX(ss.sale_date)) INTO v_anchor
    FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt
    FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_lead := GREATEST(p_delivery_date - v_anchor, 0);

  RETURN QUERY EXECUTE format($q$
  WITH cfg AS (
    SELECT rc.merch_group_nrs, rc.excluded_supplier_types
    FROM bloom_route_config rc
    WHERE rc.store_code = %1$L AND rc.route_key = 'DIRECT_BEER'
  ),
  lnk AS (
    SELECT DISTINCT ON (sl.product_code) sl.product_code,
      GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost,
      sl.supplier_nr, sm.supplier_type
    FROM sigma_supplier_link sl
    JOIN sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr AND sm.status='A'
    CROSS JOIN cfg
    WHERE sl.store_code = %1$L AND COALESCE(sl.status,'')<>'S'
      AND NOT (sm.supplier_type = ANY(cfg.excluded_supplier_types))
    ORDER BY sl.product_code, sl.cost_date DESC NULLS LAST
  ),
  last_receipt AS (
    SELECT m.product_code, MAX(m.movement_date) AS last_receipt_date
    FROM sigma_movements m
    WHERE m.store_code = %1$L AND m.movement_type IN ('R','W')
    GROUP BY m.product_code
  ),
  sales AS (
    SELECT s.product_code,
      SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 14) AS q14,
      SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 28) AS q28,
      SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 56) AS q56,
      SUM(s.qty) AS q364
    FROM sigma_sales s
    WHERE s.store_code = %1$L AND s.period_kind='T' AND s.txn_kind=1
      AND s.sale_date > %2$L::date - 364 AND s.sale_date <= %2$L::date
    GROUP BY s.product_code
  ),
  soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%3$L::date),
  base_pool AS MATERIALIZED (
    SELECT a.product_code, a.description, mg.name AS merch_group_name,
      COALESCE(t.tier,'BOR') AS tier, lnk.ps, lnk.pack_cost, lnk.supplier_nr, lnk.supplier_type,
      COALESCE(so.soh,0) AS soh_raw, COALESCE(s.q14,0) AS q14, COALESCE(s.q28,0) AS q28, COALESCE(s.q56,0) AS q56,
      COALESCE(s.q364,0) AS q364, lr.last_receipt_date,
      kv.kvi_band,
      rp.ros_14d_corrected AS scan14c, rp.ros_28d_corrected AS scan28c, rp.ros_56d_corrected AS scan56c,
      rp.ros_draw_14d_corrected AS draw14c, rp.ros_draw_28d_corrected AS draw28c, rp.ros_draw_56d_corrected AS draw56c,
      rp.p_sell_estimate AS p_sell_scan, rp.p_sell_estimate_draw AS p_sell_draw,
      COALESCE(rp.unit_incommensurable, true) AS unit_incommensurable,
      a.merch_group_nr::text || '|' ||
        trim(regexp_replace(
          regexp_replace(upper(a.description),
            '\s*(CASE|C/PACK|CRATE|BOTTLE|NRB|RB|WNR|WR|QRT|_[0-9]+|[0-9]+\s*PACK|[0-9]+PK|PK)\s*$', '', 'g'),
          '\s+', ' ', 'g')) || '|' || COALESCE(a.pack_content,'')
        AS family_key
    FROM sigma_articles a
    CROSS JOIN cfg
    JOIN lnk ON lnk.product_code = a.product_code
    JOIN l2_item_classification c ON c.store_code=a.store_code AND c.product_code=a.product_code AND c.class='NORMAL'
    LEFT JOIN sigma_subdepts mg ON mg.store_code=a.store_code AND mg.merch_group_nr=a.merch_group_nr
    LEFT JOIN l2_ranging_tier t ON t.store_code=a.store_code AND t.product_code=a.product_code
    LEFT JOIN sales s ON s.product_code=a.product_code
    LEFT JOIN soh so ON so.product_code=a.product_code
    LEFT JOIN last_receipt lr ON lr.product_code=a.product_code
    LEFT JOIN l2_stock_position sp ON sp.store_code=a.store_code AND sp.product_code=a.product_code
    LEFT JOIN l2_bloom_ros_pantry rp ON rp.store_code=a.store_code AND rp.product_code=a.product_code
    LEFT JOIN l2_kvi_profile kv ON kv.store_code=a.store_code AND kv.product_code=a.product_code
    WHERE a.store_code = %1$L AND a.merch_group_nr = ANY(cfg.merch_group_nrs)
      AND COALESCE(sp.never_sold,true) = false
  ),
  family AS (
    SELECT bp.family_key,
      bool_or(bp.q364 > 0) AS family_sold_364,
      count(*) AS family_size
    FROM base_pool bp
    GROUP BY bp.family_key
  ),
  gated AS (
    SELECT bp.*, f.family_sold_364, f.family_size,
      (bp.q56 > 0) AS own_gate,
      (bp.q56 = 0 AND f.family_sold_364 AND f.family_size > 1) AS sibling_gated
    FROM base_pool bp JOIN family f ON f.family_key = bp.family_key
  ),
  calc AS (
    SELECT g.*,
      CASE g.tier WHEN 'TOP_100' THEN (CASE WHEN g.q14=0 THEN g.q28/28.0 ELSE g.q14/14.0 END)
        WHEN 'TOP_1000' THEN g.q28/28.0 ELSE g.q56/56.0 END AS ros,
      CASE g.tier WHEN 'TOP_100' THEN (CASE WHEN g.q14=0 THEN g.scan28c ELSE g.scan14c END)
        WHEN 'TOP_1000' THEN g.scan28c ELSE g.scan56c END AS scan_corrected,
      CASE g.tier WHEN 'TOP_100' THEN (CASE WHEN g.q14=0 THEN g.draw28c ELSE g.draw14c END)
        WHEN 'TOP_1000' THEN g.draw28c ELSE g.draw56c END AS draw_corrected,
      %4$s::int AS target
    FROM gated g
    WHERE g.own_gate OR g.sibling_gated
  ),
  guarded AS (
    -- ENG-009: guard each side (scan, family draw) independently, same
    -- pattern as ENG-004 (l2_stock_band) -- KVI floor bands eligible by
    -- default, else >=8 selling days/182d off the pantry's own
    -- p_sell_estimate; each side capped at 2.0x its own raw before GREATEST.
    SELECT c.*,
      ROUND(COALESCE(c.p_sell_scan,0) * 182) AS scan_selling_days,
      ROUND(COALESCE(c.p_sell_draw,0) * 182) AS draw_selling_days,
      (c.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(c.p_sell_scan,0)*182 >= 8) AS scan_eligible,
      (NOT c.unit_incommensurable
        AND (c.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(c.p_sell_draw,0)*182 >= 8)) AS draw_eligible
    FROM calc c
  ),
  capped AS (
    SELECT g.*,
      CASE WHEN g.scan_eligible AND g.scan_corrected IS NOT NULL
           THEN LEAST(g.scan_corrected, 2.0*g.ros) ELSE g.ros END AS scan_used,
      CASE WHEN g.draw_eligible AND g.draw_corrected IS NOT NULL
           THEN LEAST(g.draw_corrected, 2.0*g.ros) ELSE NULL END AS draw_used
    FROM guarded g
  ),
  resolved AS (
    SELECT c.*,
      GREATEST(c.scan_used, COALESCE(c.draw_used,0)) AS ros_final,
      (COALESCE(c.draw_used,0) > c.scan_used) AS demand_from_draw
    FROM capped c
  ),
  needc AS (
    SELECT r.*, GREATEST(r.soh_raw,0) - r.ros_final*%5$s AS proj,
      GREATEST(r.ros_final*r.target - (GREATEST(r.soh_raw,0) - r.ros_final*%5$s), 0) AS needu
    FROM resolved r
  ),
  packs AS (
    SELECT n.*,
      CASE
        WHEN n.sibling_gated AND n.ros_final = 0 THEN 1
        WHEN n.ros_final <= 0 THEN 0
        WHEN n.needu > 0 THEN GREATEST(CEIL(n.needu/n.ps), 1)
        ELSE 0
      END::int AS suggested_packs_calc
    FROM needc n
  )
  SELECT
    %1$L::text, pk.product_code,
    COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')),
    pk.description, pk.merch_group_name, pk.tier, pk.soh_raw, pk.ps, ROUND(pk.pack_cost,2),
    (CASE pk.tier WHEN 'TOP_100' THEN (CASE WHEN pk.q14=0 THEN 'ros_28d (q14=0 fallback)' ELSE 'ros_14d' END)
       WHEN 'TOP_1000' THEN 'ros_28d' ELSE 'ros_56d' END),
    ROUND(pk.ros_final,4),
    (CASE WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END),
    ROUND(pk.proj,2), pk.target, (pk.needu > 0 OR pk.suggested_packs_calc > 0),
    ROUND(pk.needu,2), pk.suggested_packs_calc, ROUND((pk.suggested_packs_calc * pk.pack_cost)::numeric,2),
    pk.family_key, pk.sibling_gated, pk.supplier_nr, pk.supplier_type, pk.last_receipt_date,
    format('%%s tier, %%s raw=%%s used=%%s, SOH %%s, target %%s days -> proj %%s, need %%s = %%s packs%%s%%s%%s',
      pk.tier,
      (CASE pk.tier WHEN 'TOP_100' THEN 'ros_14d' WHEN 'TOP_1000' THEN 'ros_28d' ELSE 'ros_56d' END),
      ROUND(pk.ros,2), ROUND(pk.ros_final,2), pk.soh_raw, pk.target, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.suggested_packs_calc,
      CASE WHEN pk.sibling_gated THEN format(' | door reopen: family %%s sold, this code quiet (56d=0)', pk.family_key) ELSE '' END,
      CASE WHEN pk.last_receipt_date IS NULL OR pk.last_receipt_date < %2$L::date - 90
        THEN format(' | last receipt %%s', COALESCE(pk.last_receipt_date::text,'never')) ELSE '' END,
      CASE WHEN pk.demand_from_draw THEN ' | family draw used (ledger, not scan)' ELSE '' END
    )
  FROM packs pk
  LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
  ORDER BY pk.tier, pk.ros_final DESC, pk.product_code
  $q$, p_store_code, v_anchor, v_soh_dt, p_days_cover, v_lead);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_direct_beer(text,date,date,date,date,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_direct_beer(text,date,date,date,date,integer) TO anon, authenticated;
