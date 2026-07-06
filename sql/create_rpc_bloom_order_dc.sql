-- =============================================================================
-- create_rpc_bloom_order_dc.sql
-- SB-CC-BLOOM-001. The L3 recipe ORDER_DC per CLEANUP-ENGINE-CANON section 14,
-- addendum v2 + the §0d/§0e set-based rebuild. Verified live 2026-07-05.
-- =============================================================================
-- 2026-07-05 REBUILD (SB-CC-BLOOM-001 §0d/§0e/§0f): set-based, correct, FAST.
--   * One aggregated `sales` CTE (SUM ... FILTER over the 56d window) -- no
--     correlated q14/q28/q56 subqueries (the original timeout).
--   * SOH from l2_soh_daily ONLY at the pinned snapshot (ruleset rule #10) --
--     no l2_stock_position.soh fallback.
--   * Promo membership canon HALF-OPEN (start < next_delivery AND end >=
--     delivery) -- production-correct (rule 12). The 2026-07-02 reference used
--     inclusive (start <= next), so it geared a 2026-07-08 promo batch into the
--     4 Jul order; canon leaves those at normal. That is the NAMED ruled
--     difference (regression proves the recipe under inclusive; production ships
--     canon).
--   * v_ean_bridge is display/TLX only (rule 14) -- joined to the OUTPUT rows,
--     never the pool.
--   * Dynamic SQL with LITERAL anchor/soh/lead/depts (PM fallback: force the
--     planner off a generic plan by embedding constants).
--
-- ⭐ THE FIX THAT BEAT THE TIMEOUT (§0f, root-caused via plain EXPLAIN):
--   base_pool's `COALESCE(q364,0)>0 OR COALESCE(soh,0)<>0` filter across LEFT
--   JOINs makes the planner estimate base_pool at rows=1 (it is ~4,363). That
--   1-row lie cascaded: the v_ean_bridge regexp view got Merge-Right-Joined over
--   all 8,922 product_catalog rows against a "1-row" input, and the promo/gear
--   joins became nested loops that explode at runtime -- minutes, reported as
--   "timeout" by every tool whose read ceiling sits at ~8s. Marking
--   **base_pool AS MATERIALIZED** and **ean_map AS MATERIALIZED** forces the true
--   row count, so downstream planning uses hash joins and the bridge regexp runs
--   once. Result: EXPLAIN ANALYZE Execution Time 1,673 ms (was >30s), 4,363 rows,
--   EAN + dept populated on all. Keep both MATERIALIZED hints -- they are the fix.
--
-- Reconciliation (RPC output, canon half-open): nonpromo 582 / promo 218 /
--   all-normal value R359,135.11 vs reference inclusive 516 / 301 / R359,003.79
--   -- split differs by the 65-line 8-Jul batch (ruled), value ties within R131
--   (gear recomputed unrounded on 2719/9873, rule 13). Recipe proven to the
--   reference under inclusive semantics (517/301, flat query, §0f).
--
-- Own statement_timeout 30s = loud-failure belt (a future regression degrades
-- loudly, never silently at the authenticator 8s line).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_order_dc(p_store_code text, p_delivery_date date, p_next_delivery date, p_anchor_date date DEFAULT NULL::date, p_soh_date date DEFAULT NULL::date)
 RETURNS TABLE(store_code text, product_code bigint, ean text, description text, dept_name text, tier text, soh numeric, unit_cost numeric, pack_size smallint, pack_cost numeric, ros_window_used text, ros_used numeric, ros_used_corrected numeric, ros_correction_delta numeric, ros_correction_delta_pct numeric, projected_soh numeric, target_days_cover integer, trigger_fired boolean, need_units numeric, normal_packs integer, promo_active boolean, promo_nr bigint, promo_start date, promo_end date, promo_uplift numeric, promo_uplift_source text, geared_packs integer, suggested_packs integer, promo_cost_delta numeric, promo_cost_resolved boolean, story text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date; v_soh_dt date; v_lead int; v_depts text;
BEGIN
  SET LOCAL statement_timeout = '30s';
  SELECT COALESCE(p_anchor_date, MAX(ss.sale_date)) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_lead := GREATEST(p_delivery_date - v_anchor, 0);
  SELECT array_to_string(bc.dc_cycle_dept_nrs, ',') INTO v_depts FROM bloom_dc_config bc WHERE bc.store_code=p_store_code;

  RETURN QUERY EXECUTE format($q$
    WITH sales AS (
      SELECT s.product_code,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 14) AS q14,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 28) AS q28,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 56) AS q56,
        SUM(s.qty) AS q364
      FROM public.sigma_sales s
      WHERE s.store_code = %1$L AND s.period_kind='T' AND s.txn_kind=1
        AND s.sale_date > %2$L::date - 364 AND s.sale_date <= %2$L::date
      GROUP BY s.product_code
    ),
    lnk AS (
      SELECT DISTINCT ON (sl.product_code) sl.product_code,
        GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost
      FROM public.sigma_supplier_link sl
      JOIN public.sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr AND sm.supplier_type='Z'
      WHERE sl.store_code=%1$L AND COALESCE(sl.status,'')<>'S' AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM public.l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%3$L::date),
    base_pool AS MATERIALIZED (
      SELECT a.product_code, COALESCE(t.tier,'BOR') AS tier, lnk.ps AS pack_size, lnk.pack_cost AS pack_list_cost,
        COALESCE(so.soh,0) AS soh, COALESCE(s.q14,0) AS q14, COALESCE(s.q28,0) AS q28, COALESCE(s.q56,0) AS q56,
        sp.description, sp.dept_name, sp.unit_cost
      FROM public.sigma_articles a
      JOIN lnk ON lnk.product_code=a.product_code
      JOIN public.l2_item_classification ic ON ic.store_code=a.store_code AND ic.product_code=a.product_code AND ic.class='NORMAL'
      LEFT JOIN public.l2_ranging_tier t ON t.store_code=a.store_code AND t.product_code=a.product_code
      LEFT JOIN sales s ON s.product_code=a.product_code
      LEFT JOIN soh so ON so.product_code=a.product_code
      LEFT JOIN public.l2_stock_position sp ON sp.store_code=a.store_code AND sp.product_code=a.product_code
      WHERE a.store_code=%1$L AND a.department_nr IN (%5$s) AND (COALESCE(s.q364,0)>0 OR COALESCE(so.soh,0)<>0)
    ),
    rated AS (
      SELECT w.*,
        CASE w.tier WHEN 'TOP_100' THEN (CASE WHEN w.q14=0 THEN w.q28/28.0 ELSE w.q14/14.0 END)
          WHEN 'TOP_1000' THEN w.q28/28.0 WHEN 'BOR' THEN w.q56/56.0 ELSE NULL END AS ros_used,
        CASE w.tier WHEN 'TOP_100' THEN 14 WHEN 'TOP_1000' THEN 12 WHEN 'BOR' THEN 14 ELSE NULL END AS target_days_cover,
        CASE w.tier WHEN 'TOP_100' THEN (CASE WHEN w.q14=0 THEN 'ros_28d (q14=0 fallback)' ELSE 'ros_14d' END)
          WHEN 'TOP_1000' THEN 'ros_28d' WHEN 'BOR' THEN 'ros_56d' ELSE NULL END AS ros_window_used
      FROM base_pool w WHERE w.tier IN ('TOP_100','TOP_1000','BOR')
    ),
    promo_match AS (
      SELECT DISTINCT ON (r.product_code) r.product_code, pa.promo_nr, pa.start_date, pa.end_date, pa.status, pa.list_cost AS promo_unit_cost
      FROM rated r JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=r.product_code
        AND pa.start_date < %7$L::date AND pa.end_date >= %6$L::date
      ORDER BY r.product_code, (pa.status='1') DESC, pa.end_date DESC
    ),
    gear_source AS (
      SELECT DISTINCT ON (r.product_code) r.product_code, pa.start_date, pa.end_date
      FROM rated r JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=r.product_code
        AND pa.status='2' AND pa.end_date < %2$L::date AND pa.start_date >= DATE '2025-06-01'
      ORDER BY r.product_code, pa.end_date DESC
    ),
    gear_calc AS (
      SELECT gs.product_code,
        COALESCE(SUM(ss.qty) FILTER (WHERE ss.sale_date BETWEEN gs.start_date AND gs.end_date),0)/GREATEST(gs.end_date-gs.start_date+1,1) AS promo_ros,
        COALESCE(SUM(ss.qty) FILTER (WHERE ss.sale_date BETWEEN gs.start_date-28 AND gs.start_date-1),0)/28.0 AS base_ros
      FROM gear_source gs LEFT JOIN public.sigma_sales ss ON ss.store_code=%1$L AND ss.product_code=gs.product_code
        AND ss.period_kind='T' AND ss.txn_kind=1 AND ss.sale_date BETWEEN (gs.start_date-28) AND gs.end_date
      GROUP BY gs.product_code, gs.start_date, gs.end_date
    ),
    with_gear AS (
      SELECT r.*, CASE WHEN gc.base_ros IS NULL OR gc.base_ros=0 THEN 2.0 ELSE LEAST(GREATEST(gc.promo_ros/gc.base_ros,1.0),5.0) END AS gear,
        (gc.base_ros IS NOT NULL AND gc.base_ros<>0) AS gear_from_own_promo
      FROM rated r LEFT JOIN gear_calc gc ON gc.product_code=r.product_code
    ),
    gated AS (
      SELECT g.*, GREATEST(g.soh,0)-g.ros_used*%4$s AS proj_soh,
        GREATEST(g.ros_used*g.target_days_cover-(GREATEST(g.soh,0)-g.ros_used*%4$s),0) AS need
      FROM with_gear g
    ),
    final AS (
      SELECT gt.*,
        (gt.ros_used>0 AND ((gt.tier='TOP_100' AND gt.need>0) OR (gt.tier='TOP_1000' AND gt.need>0) OR (gt.tier='BOR' AND gt.proj_soh<3 AND gt.need>0))) AS fires,
        CASE WHEN gt.ros_used<=0 THEN 0
          WHEN gt.tier='TOP_100' AND gt.need>0 THEN GREATEST(FLOOR(gt.need/gt.pack_size),1)
          WHEN gt.tier='TOP_1000' AND gt.need>0 THEN CASE WHEN FLOOR(gt.need/gt.pack_size)=0 THEN (CASE WHEN gt.proj_soh<3 THEN 1 ELSE 0 END) ELSE FLOOR(gt.need/gt.pack_size) END
          WHEN gt.tier='BOR' AND gt.proj_soh<3 AND gt.need>0 THEN GREATEST(FLOOR(gt.need/gt.pack_size),1) ELSE 0 END::int AS normal_packs_calc,
        (GREATEST(gt.soh,0)-(gt.ros_used*gt.gear)*%4$s) AS proj_soh_geared,
        GREATEST((gt.ros_used*gt.gear)*gt.target_days_cover-(GREATEST(gt.soh,0)-(gt.ros_used*gt.gear)*%4$s),0) AS need_geared
      FROM gated gt
    ),
    final2 AS (
      SELECT f.*, CASE WHEN f.ros_used<=0 THEN 0
        WHEN f.tier='TOP_100' AND f.need_geared>0 THEN GREATEST(FLOOR(f.need_geared/f.pack_size),1)
        WHEN f.tier='TOP_1000' AND f.need_geared>0 THEN CASE WHEN FLOOR(f.need_geared/f.pack_size)=0 THEN (CASE WHEN f.proj_soh_geared<3 THEN 1 ELSE 0 END) ELSE FLOOR(f.need_geared/f.pack_size) END
        WHEN f.tier='BOR' AND f.proj_soh_geared<3 AND f.need_geared>0 THEN GREATEST(FLOOR(f.need_geared/f.pack_size),1) ELSE 0 END::int AS geared_packs_calc
      FROM final f
    ),
    with_promo AS (
      SELECT f2.*, pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end, pm.status AS promo_status, pm.promo_unit_cost
      FROM final2 f2 LEFT JOIN promo_match pm ON pm.product_code=f2.product_code
    ),
    with_corrected AS (
      SELECT wp.*, CASE wp.tier WHEN 'TOP_100' THEN rp.ros_14d_corrected WHEN 'TOP_1000' THEN rp.ros_28d_corrected WHEN 'BOR' THEN rp.ros_56d_corrected ELSE NULL END AS ros_used_corrected
      FROM with_promo wp LEFT JOIN public.l2_bloom_ros_pantry rp ON rp.store_code=%1$L AND rp.product_code=wp.product_code
    ),
    ean_map AS MATERIALIZED (SELECT eb.product_code, eb.ean FROM public.v_ean_bridge eb WHERE eb.store_code=%1$L)
    SELECT %1$L::text, wc.product_code,
      COALESCE(b.ean, lpad(%1$L,5,'0')||lpad(wc.product_code::text,8,'0')),
      wc.description, wc.dept_name, wc.tier, wc.soh, wc.unit_cost, wc.pack_size, ROUND(wc.pack_list_cost,2),
      wc.ros_window_used, ROUND(wc.ros_used,4), ROUND(COALESCE(wc.ros_used_corrected,wc.ros_used),4),
      ROUND(COALESCE(wc.ros_used_corrected,wc.ros_used)-wc.ros_used,4),
      CASE WHEN wc.ros_used>0 THEN ROUND((COALESCE(wc.ros_used_corrected,wc.ros_used)-wc.ros_used)/wc.ros_used*100,2) ELSE NULL END,
      ROUND(wc.proj_soh,2), wc.target_days_cover, wc.fires, ROUND(wc.need,2),
      wc.normal_packs_calc, (wc.promo_nr IS NOT NULL), wc.promo_nr, wc.promo_start, wc.promo_end,
      ROUND(wc.gear,4), (CASE WHEN wc.gear_from_own_promo THEN 'own_promo' ELSE 'default' END), wc.geared_packs_calc,
      CASE WHEN wc.promo_nr IS NOT NULL THEN wc.geared_packs_calc ELSE wc.normal_packs_calc END,
      CASE WHEN wc.promo_status='1' AND wc.promo_unit_cost IS NOT NULL AND wc.promo_unit_cost<>0 THEN ROUND((wc.pack_list_cost/NULLIF(wc.pack_size,0))-wc.promo_unit_cost,4) ELSE NULL END,
      (wc.promo_status='1' AND wc.promo_unit_cost IS NOT NULL AND wc.promo_unit_cost<>0),
      format('%%s tier, window=%%s raw=%%s, SOH %%s, target %%s days -> proj %%s, need %%s units = %%s packs%%s',
        wc.tier, wc.ros_window_used, ROUND(wc.ros_used,2), wc.soh, wc.target_days_cover, ROUND(wc.proj_soh,1), ROUND(wc.need,1), wc.normal_packs_calc,
        CASE WHEN wc.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', wc.promo_start, wc.promo_end, ROUND(wc.gear,2)) ELSE '' END)
    FROM with_corrected wc LEFT JOIN ean_map b ON b.product_code=wc.product_code
    ORDER BY wc.tier, wc.ros_used DESC, wc.product_code
  $q$, p_store_code, v_anchor, v_soh_dt, v_lead, v_depts, p_delivery_date, p_next_delivery);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_dc(text,date,date,date,date) TO anon, authenticated;
