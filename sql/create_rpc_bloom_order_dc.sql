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
-- 2026-07-06 (SB-CC-BLOOM-002): added p_days_cover integer DEFAULT 7 -- ONE
-- cover target across every tier, replacing the fixed per-tier targets
-- (T100 14 / T1000 12 / BOR 14). Pieter floor-checked the 14-day normal-basis
-- order against a right-sized order and found it over-ordered ~100% -- the
-- DC delivers twice a week, so a flat 14-day cover buys a fortnight of stock
-- three days before the next truck. 7 days is the new default; 10/14 remain
-- selectable. Per-tier targets retired: scope DEMO_CALIBRATION, effective
-- 2026-07-06, superseded by this parameter (R28 lineage, folded into
-- CLEANUP-ENGINE-CANON §14 at handover). Interim lever -- the durable fix is
-- cover-to-next-delivery (cadence-aware), parked as a follow-on.
-- =============================================================================
-- ENG-005 REOPENED / CLOSED FOR REAL (2026-07-09/10, SB-CC-BLOOM-004 item 1,
--   PM ruling 2026-07-09). The pantry object (l2_bloom_ros_pantry, ros_draw)
--   was built and correct (BUG-LOG ENG-005B) but this RPC -- the ACTUAL live
--   order -- never read it. `rated` computed `ros_used` from its own inline
--   `sales` CTE (raw scan only); the pantry was only joined later
--   (`with_corrected`) to expose `ros_used_corrected` as a REPORTED delta --
--   the quantity math (`need`, `normal_packs`, `geared_packs`) never touched
--   it. Live proof of the bug: 10116/1674 (SPAR MILK, the family holder)
--   proposed 0 packs on scan ~33.8/day while the pantry carried ~469-609/day
--   family draw, depending on window -- the exact ENG-005 gap, un-repointed.
--
--   FIX: `base_pool` now LEFT JOINs `l2_bloom_ros_pantry` for
--   `ros_draw_14d_corrected` / `_28d_corrected` / `_56d_corrected`. `rated`'s
--   `ros_used` is now GREATEST(scan value, draw-corrected value) on the SAME
--   window the tier already resolves to (TOP_100 -> 14d, with the existing
--   q14=0 fallback to 28d carried through to the draw side too; TOP_1000 ->
--   28d; BOR -> 56d) -- "same window + correction" per the ruling, never a
--   different window than what scan already picked. LEFT JOIN + COALESCE(
--   draw,0) means an absent pantry row (population drift, or a weighed line
--   the pantry correctly excludes) falls back to scan-only, never a wrong
--   number standing in for a missing one. `ros_used_corrected` (the DF-2
--   stockout-correction delta column) is UNCHANGED -- still scan-side only,
--   a separate, already-correct piece of provenance (R29); this fix touches
--   the DEMAND DRIVER, not that reporting column.
--
--   New output column `demand_source` ('scan' | 'family_draw') and a story
--   suffix name which side won, per row (R29 -- the reason travels with the
--   number). RETURNS TABLE signature changed -- DROP + CREATE (Postgres does
--   not allow CREATE OR REPLACE across a return-type change, RULE-BOOK §8
--   function-change protocol).
--
--   Acceptance (PM, 2026-07-09): 10116/1674 proposes >0 packs, ros_used near
--   the ~480/day family draw, not the ~34-38/day scan; Capital Tied
--   (v_l2_capital_by_store) and l2_kvi_profile bands unchanged (this fix
--   touches only the DC recipe's demand math, never l2_classification scope
--   or the KVI pantry). Roll out and verify all 5 stores.
-- =============================================================================
-- SCOPE-GATE (2026-07-10, SB-CC-BLOOM-004 item 2, scoped form -- PM ruling
--   2026-07-09/10, ordered AFTER the CLEANUP-ENGINE-CANON s13 dependent-list
--   audit). base_pool's population gate was `COALESCE(q364,0)>0 OR
--   COALESCE(soh,0)<>0` -- a rolling 364-day scan window. A line that has been
--   out of stock long enough that its OWN 364-day scan window is empty (soh=0
--   AND q364=0) fell out of the pool entirely -- absent, not excluded, exactly
--   the failure mode the brief warned about, though the live culprit here is
--   the 364-day rolling scan window, not `l2_classification`'s soh<>0 scope
--   (this RPC never reads `l2_classification` at all; it reads
--   `l2_item_classification.class='NORMAL'` only, a different, unscoped
--   object). Live proof: 48 KVI_CRITICAL/KVI_IMPORTANT lines at 10116 are
--   currently OOS (soh=0); only 17 were visible to this pool, 31 invisible --
--   all 31 have `l2_stock_position.never_sold=false` (they HAVE sold, just
--   not inside the current 364-day window).
--
--   FIX: population gate repointed to `l2_stock_position.never_sold=false`
--   (lifetime ever-sold, the SAME gate `l2_bloom_ros_pantry`'s dc_pool already
--   uses) instead of the rolling-window heuristic. Safe to widen because the
--   "orderable slice" gate the brief calls for is ALREADY structurally
--   enforced independently: `base_pool` INNER JOINs `lnk` (an active,
--   non-suspended Z-supplier link), so a product with no real, current order
--   route still cannot enter the pool no matter how permissive the sales-
--   history gate is. `l2_classification`'s own soh<>0 scope (Capital Tied,
--   the KVI band) is UNTOUCHED -- this migration reads and writes nothing in
--   that object. Do NOT read this as the full "one verdict, three gates"
--   lift of the article verdict out of the cascade -- that stays gated
--   pending Pieter's ruling on the R5.86M vs R7.96M explanation; this is
--   only the DC recipe's own population filter.
--
--   Acceptance: the 31 previously-invisible OOS KVI lines at 10116 now enter
--   the pool; `v_l2_capital_by_store` and `l2_kvi_profile` band counts
--   unchanged (verified -- this migration touches neither object).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_dc(text,date,date,date,date,integer);

CREATE FUNCTION public.rpc_bloom_order_dc(p_store_code text, p_delivery_date date, p_next_delivery date, p_anchor_date date DEFAULT NULL::date, p_soh_date date DEFAULT NULL::date, p_days_cover integer DEFAULT 7)
 RETURNS TABLE(store_code text, product_code bigint, ean text, description text, dept_name text, tier text, soh numeric, unit_cost numeric, pack_size smallint, pack_cost numeric, ros_window_used text, ros_used numeric, ros_used_corrected numeric, ros_correction_delta numeric, ros_correction_delta_pct numeric, demand_source text, projected_soh numeric, target_days_cover integer, trigger_fired boolean, need_units numeric, normal_packs integer, promo_active boolean, promo_nr bigint, promo_start date, promo_end date, promo_uplift numeric, promo_uplift_source text, geared_packs integer, suggested_packs integer, promo_cost_delta numeric, promo_cost_resolved boolean, story text)
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
        rp.ros_draw_14d_corrected AS draw14, rp.ros_draw_28d_corrected AS draw28, rp.ros_draw_56d_corrected AS draw56,
        sp.description, sp.dept_name, sp.unit_cost
      FROM public.sigma_articles a
      JOIN lnk ON lnk.product_code=a.product_code
      JOIN public.l2_item_classification ic ON ic.store_code=a.store_code AND ic.product_code=a.product_code AND ic.class='NORMAL'
      LEFT JOIN public.l2_ranging_tier t ON t.store_code=a.store_code AND t.product_code=a.product_code
      LEFT JOIN sales s ON s.product_code=a.product_code
      LEFT JOIN soh so ON so.product_code=a.product_code
      LEFT JOIN public.l2_stock_position sp ON sp.store_code=a.store_code AND sp.product_code=a.product_code
      LEFT JOIN public.l2_bloom_ros_pantry rp ON rp.store_code=a.store_code AND rp.product_code=a.product_code
      WHERE a.store_code=%1$L AND a.department_nr IN (%5$s) AND COALESCE(sp.never_sold,true)=false
    ),
    rated AS (
      -- ENG-005: demand = GREATEST(scan, family draw corrected) on the SAME
      -- window the tier already resolves to. LEFT JOIN + COALESCE(x,0) means
      -- a missing pantry row (population drift, or a weighed line the pantry
      -- correctly excludes) never boosts demand -- it just falls back to the
      -- pre-existing scan-only value.
      SELECT w.*,
        CASE w.tier
          WHEN 'TOP_100' THEN
            CASE WHEN w.q14=0
              THEN GREATEST(w.q28/28.0, COALESCE(w.draw28,0))
              ELSE GREATEST(w.q14/14.0, COALESCE(w.draw14,0))
            END
          WHEN 'TOP_1000' THEN GREATEST(w.q28/28.0, COALESCE(w.draw28,0))
          WHEN 'BOR' THEN GREATEST(w.q56/56.0, COALESCE(w.draw56,0))
          ELSE NULL
        END AS ros_used,
        CASE w.tier
          WHEN 'TOP_100' THEN (CASE WHEN w.q14=0 THEN COALESCE(w.draw28,0) > w.q28/28.0 ELSE COALESCE(w.draw14,0) > w.q14/14.0 END)
          WHEN 'TOP_1000' THEN COALESCE(w.draw28,0) > w.q28/28.0
          WHEN 'BOR' THEN COALESCE(w.draw56,0) > w.q56/56.0
          ELSE false
        END AS demand_from_draw,
        %8$s::int AS target_days_cover,
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
      (CASE WHEN wc.demand_from_draw THEN 'family_draw' ELSE 'scan' END),
      ROUND(wc.proj_soh,2), wc.target_days_cover, wc.fires, ROUND(wc.need,2),
      wc.normal_packs_calc, (wc.promo_nr IS NOT NULL), wc.promo_nr, wc.promo_start, wc.promo_end,
      ROUND(wc.gear,4), (CASE WHEN wc.gear_from_own_promo THEN 'own_promo' ELSE 'default' END), wc.geared_packs_calc,
      CASE WHEN wc.promo_nr IS NOT NULL THEN wc.geared_packs_calc ELSE wc.normal_packs_calc END,
      CASE WHEN wc.promo_status='1' AND wc.promo_unit_cost IS NOT NULL AND wc.promo_unit_cost<>0 THEN ROUND((wc.pack_list_cost/NULLIF(wc.pack_size,0))-wc.promo_unit_cost,4) ELSE NULL END,
      (wc.promo_status='1' AND wc.promo_unit_cost IS NOT NULL AND wc.promo_unit_cost<>0),
      format('%%s tier, window=%%s raw=%%s, SOH %%s, target %%s days -> proj %%s, need %%s units = %%s packs%%s%%s',
        wc.tier, wc.ros_window_used, ROUND(wc.ros_used,2), wc.soh, wc.target_days_cover, ROUND(wc.proj_soh,1), ROUND(wc.need,1), wc.normal_packs_calc,
        CASE WHEN wc.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', wc.promo_start, wc.promo_end, ROUND(wc.gear,2)) ELSE '' END,
        CASE WHEN wc.demand_from_draw THEN ' | family draw used (ledger, not scan)' ELSE '' END)
    FROM with_corrected wc LEFT JOIN ean_map b ON b.product_code=wc.product_code
    ORDER BY wc.tier, wc.ros_used DESC, wc.product_code
  $q$, p_store_code, v_anchor, v_soh_dt, v_lead, v_depts, p_delivery_date, p_next_delivery, p_days_cover);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_dc(text,date,date,date,date,integer) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
