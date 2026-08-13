-- =============================================================================
-- 2026-08-13_bloom_recipe_eng083_v16.sql
-- ENG-083 / canon SS14 v16 + 16.7 leg 2 -- the DC ambient Standard order over-order fix.
-- Pieter ruling 2026-08-13 ("churn and test and then implement").
--
-- Deployed live 2026-08-13 as migration `fix_bloom_recipe_dc_over_order_eng083_v16`
-- (built + R22-validated as the rpc_bloom_order_recipe_v16 shadow, then renamed onto the
-- live function; CREATE OR REPLACE preserved grants + SECURITY DEFINER).
--
-- This file is the reproducible record of the change. It is idempotent (re-running is a
-- no-op once applied). The monolithic sql/create_rpc_bloom_order_recipe.sql full-body
-- regen from live is OWED and rides with the ENG-063 reconcile pass (that file was already
-- diverged from live before this change -- do not treat this delta as the only divergence).
--
-- TWO COUPLED DEFECTS in public.rpc_bloom_order_recipe:
--   Bug 1 (demand basis, v16): in the Standard preset + minimum mode, both demand legs
--     (scan_raw, draw_corrected) read the stockout-corrected wide window
--     (ros_56d_published / ros_draw_56d_published), not the raw 14-day spike that
--     ros_final = GREATEST(scan_raw, draw_used) was locking in. Build mode and the geared
--     path keep the responsive short window by design. Essentials/catch-up/full/fitted are
--     untouched (%10$L = 'standard' gate). Scan-side ros_56d_published added to pool scope.
--   Bug 2 (build timing, 16.7 leg 2 / ENG-056a successor): the month-end build window is
--     DERIVED from the route's own delivery_dows around the community payday
--     (config key month_end_build_anchor_dom, DEMO_CALIBRATION = 25), never the hardcoded
--     day 15. Standard preset + real DC supplier_calendar row only.
--   R29: demand_source / ros_window_used report the stable basis when it fires.
--
-- R22 (live, to the rand): 80175 DC_AMBIENT 15 Aug R353,017 -> R274,108; 10116 R909,053 ->
-- R781,387. Essentials/catch-up byte-identical. TOPS +2.6% (stockout-aware). Direct flat.
-- =============================================================================

-- 1. Config anchor (idempotent).
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT 'month_end_build_anchor_dom', '*', 25, 'DEMO_CALIBRATION', CURRENT_DATE,
  'Community salary payday day-of-month (SB-VIS-001 s4.2 = the 25th). The month-end DC build window is DERIVED as the last two delivery-day drops strictly before this date (canon 14 v16 build-timing + 16.7 leg 2; Pieter ruling 2026-08-13). DEMO_CALIBRATION: store #6 sets its own payday; the derivation from delivery_dows is GENERAL.'
WHERE NOT EXISTS (SELECT 1 FROM public.forge_config WHERE config_key='month_end_build_anchor_dom' AND retired_on IS NULL);

-- 2. The function transformation (idempotent: no-op if already applied).
DO $do$
DECLARE
  src text := pg_get_functiondef('public.rpc_bloom_order_recipe'::regproc);
BEGIN
  IF position('v16 std-min' IN src) > 0 THEN
    RAISE NOTICE 'ENG-083 v16 fix already applied to rpc_bloom_order_recipe -- skipping';
    RETURN;
  END IF;

  -- Bug 2: declare the derived-build-window vars
  src := replace(src, $bo$  v_relevant_min_cover_days numeric;
BEGIN$bo$, $bn$  v_relevant_min_cover_days numeric;
  v_build_start_dom int;
  v_build_end_dom int;
  v_payday_dom int;
BEGIN$bn$);

  -- Bug 2: derive the month-end build window from delivery_dows + payday anchor
  src := replace(src, $co$  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;$co$,
$cn$  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;

  IF p_route IN ('DC_AMBIENT','DC_TOPS') AND COALESCE(p_preset,'standard')='standard'
     AND EXISTS (SELECT 1 FROM supplier_calendar sc2 WHERE sc2.store_code=p_store_code AND sc2.route_key=p_route) THEN
    SELECT fc.value_num::int INTO v_payday_dom FROM forge_config fc
      WHERE fc.config_key='month_end_build_anchor_dom' AND fc.store_format='*' AND fc.retired_on IS NULL LIMIT 1;
    IF v_payday_dom IS NOT NULL THEN
      SELECT MAX(CASE WHEN rk=2 THEN dom END), MAX(CASE WHEN rk=1 THEN dom END)
        INTO v_build_start_dom, v_build_end_dom
      FROM (
        SELECT EXTRACT(DAY FROM d)::int AS dom, row_number() OVER (ORDER BY d DESC) AS rk
        FROM generate_series(date_trunc('month', p_delivery_date)::date,
                             (date_trunc('month', p_delivery_date) + interval '1 month - 1 day')::date,
                             interval '1 day') g(d)
        WHERE EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows)
          AND EXTRACT(DAY FROM d)::int < v_payday_dom
      ) ranked;
    END IF;
  END IF;$cn$);

  -- Bug 1: scan-side ros_56d_published into pool scope
  src := replace(src, $d2o$        rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected,$d2o$,
                      $d2n$        rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected, rop.ros_56d_published,$d2n$);

  -- Bug 1: demand basis -> stable stockout-corrected wide window (Standard + minimum only)
  src := replace(src, $eo$        GREATEST(g.scan_raw, COALESCE((CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END),0)) AS ros_final,$eo$,
$en$        CASE WHEN %10$L = 'standard' AND NOT (
               (g.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s)
            OR (g.archetype = 'EARLY_MONTH' AND %4$s >= %7$s))
             THEN GREATEST(
                    COALESCE(g.ros_56d_published, g.q56/56.0),
                    COALESCE((CASE WHEN g.draw_eligible THEN COALESCE(g.ros_draw_56d_published, g.draw_raw_56d) ELSE NULL END),0))
             ELSE GREATEST(g.scan_raw, COALESCE((CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END),0))
        END AS ros_final,$en$);

  -- Bug 2: feed the derived doms into the mode CASE args
  src := replace(src, $fo$       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,$fo$,
                      $fn$       COALESCE(v_build_start_dom, p_month_end_build_start_day), COALESCE(v_build_end_dom, p_month_end_build_end_day), p_early_month_build_start_day,$fn$);

  -- R29: demand_source + ros_window_used honest when the stable basis fires
  src := replace(src, $go$      (CASE WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END) AS demand_source, pk.ros_window_used AS ros_window_used,$go$,
                      $gn$      (CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'stable_56d' WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END) AS demand_source, (CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'ros_56d STABLE (v16 std-min)' ELSE pk.ros_window_used END) AS ros_window_used,$gn$);

  -- R29: story window token
  src := replace(src, $ho$        pk.ros_window_used, ROUND(pk.ros_final,2),$ho$,
                      $hn$        CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'ros_56d STABLE (v16 std-min)' ELSE pk.ros_window_used END, ROUND(pk.ros_final,2),$hn$);

  EXECUTE src;
  RAISE NOTICE 'ENG-083 v16 fix applied to rpc_bloom_order_recipe';
END $do$;

SELECT pg_notify('pgrst', 'reload schema');
