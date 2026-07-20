-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5 -- the profile-driven Recipe RPC.
--
-- =========================== BLOOM-008 POST-WALK RECOVERY (v10, 2026-07-12) ==
-- CLEANUP-ENGINE-CANON SS14 ADDENDUM v10 (Pieter's floorwalk, WALK-FINDINGS
-- W1-W33) -- recovers BLOOM-008 items 1-4, the redefinition that was
-- CANONISED (SS14 v8) and PM-tested at 10116 on 2026-07-12 BEFORE this
-- build, but never actually wired into the recipe. The live recipe was
-- frozen at BLOOM-007 (the flat 21-day essentials build) the whole time,
-- so essentials breached its own max band on 558/558 ordered lines
-- (W20 root-cause finding). This is RECOVERY of already-ruled logic, not a
-- rewrite of the engine's own demand/promo/band machinery below (ENG-012
-- through ENG-018, the demand-window resolution, the promo-uplift ladder --
-- all UNCHANGED, reused exactly as they were, per R21/R27's own "the
-- pantry stocks it, the recipe picks" discipline and this session's
-- explicit instruction: "reuse, do not reinvent").
--
-- ITEM 1 -- RANGE STATE (W27, canon v10). Every pool line now carries one
--   of HERO/CORE/SLOW/MARKDOWN/DERANGE/VERIFY from the new l2_range_state
--   pantry table (sql/create_l2_range_state.sql) -- assembled from signals
--   that already exist (l2_bt_heroes, l2_kvi_profile.passes_life_gate,
--   l2_classification buckets). This fact now DRIVES depth and scope,
--   replacing the old flat-day-cover preset system entirely.
--
-- ITEM 2 -- DEPTH + THE UNIVERSAL MAX-BAND CEILING (W22, W31a). HERO always
--   targets max_band (never empty, ordered to the order-up-to level, budget
--   permitting). CORE targets "the band" (min_band in minimum mode,
--   max_band in build/month-end mode -- UNCHANGED archetype mechanism,
--   ENG-012's order-time recompute untouched). SLOW/MARKDOWN/DERANGE/VERIFY
--   NEVER order (target = current SOH, need = 0) -- they still RETURN in
--   the result set with their range_state + reason (R21 SS5, never hidden),
--   just at zero depth. max_band is now a HARD CEILING IN EVERY SCENARIO,
--   no exception: a line whose minimum ONE pack would push stock past its
--   own max_band is not ordered at all -- `pack_forced_review=true`,
--   `suggested_packs=0`, routes to a human review flag instead (closes the
--   461-line pack-forced breach W30 red-team found; retires the old
--   canon v9 items 2/3 "pack-size exception", superseded with lineage --
--   v10 makes the ceiling universal). A HERO tripping this same edge gets
--   its own `hero_pack_over_max=true` flag (never silently under-served,
--   never silently forced over cap -- a genuine collision between
--   hero-never-empty and never-over-max that only a human can resolve:
--   smaller pack, loose unit, or a deliberate one-pack call).
--
-- ITEM 3 -- SCENARIOS AS SCOPE OVER STATES (W23, W24, W31b, canon v10).
--   The scope/depth split retires every old preset-specific flat-day
--   override:
--     FULL      (p_preset NULL, p_fit_to_budget=false) -- HERO + CORE,
--       whole selling range, each at its own normal band depth.
--     FITTED    (p_preset NULL, p_fit_to_budget=true)  -- FULL's own order,
--       then item 4's cash fit (below).
--     ESSENTIALS (p_preset='order_essentials') -- HERO always to max; CORE
--       lines that are KVI (kvi_band CRITICAL/IMPORTANT) OR promo_active
--       get their NORMAL band depth (same as full); every other CORE line
--       gets MIN-BAND PRESENCE ONLY (never build-mode max), regardless of
--       archetype. No tail (SLOW/MARKDOWN/DERANGE/VERIFY) ever orders. The
--       old flat 21-day/10-day cash-gated essentials cover (canon v7 item 3)
--       RETIRES WITH LINEAGE here -- `order_budget_ledger.cash_constrained`
--       stays live for any other reader, just no longer consulted by this
--       preset.
--     CATCH_UP  (p_preset='catch_up') -- the STORE-LEVEL restore program
--       (W23/W31b, pin closed: "standard order-up-to level, not the bare
--       reorder trigger"). Eligible pool = HERO union CORE with real demand
--       (ros_final>0). HERO is unconditionally filled first (never subject
--       to the cutoff, per HERO's own never-empty rule). CORE lines rank
--       (kvi_band priority, then gmroi_rank ASC) and fill top-down to their
--       own max_band, walking down the range until the FIRST of: (a) the
--       cumulative aggregate stock-days-of-cover across the whole eligible
--       pool reaches `p_store_target_days` (21, DEMO_CALIBRATION), using
--       the SAME stock-at-cost / daily-cost-demand formula as
--       rpc_bloom_stock_state (item 7) for a consistent reading between the
--       instrument and the order; or (b) the cumulative committed value
--       reaches this week's budget. Lines beyond the cutoff return at 0
--       packs, reason 'catchup_below_cutoff', never silently dropped from
--       the result set. GEARED = the identical order with promo-active
--       lines' quantities lifted (unchanged dual normal/geared mechanism,
--       item 5/6 stretch -- not touched this pass).
--
-- ITEM 4 -- FIT-TO-CASH, PROPORTIONAL, FLOOR-PROTECTED (W25, W30 red-team
--   fix #1, canon v10). p_fit_to_budget=true (FULL->FITTED; CATCH_UP has
--   its OWN budget-aware walk above and does not run this branch a second
--   time): compute the scenario's own order first (unchanged), then
--   PROTECT every HERO line and every KVI_CRITICAL/KVI_IMPORTANT CORE line
--   at its full computed quantity (`budget_fit_reason='protected_kvi_hero'`,
--   the W30 fix -- the OLD GMROI-waterfall trim that could shave a KVI line
--   to zero is RETIRED WITH LINEAGE), then scale ONLY the remaining
--   (non-KVI CORE) quantities DOWN proportionally, in the same ratios, so
--   their combined value fits the cash remaining after the protected spend
--   (never scales UP past 1.0 -- fit only trims). Manual budget overrides
--   (W5/W14, `order_budget_ledger.budget_manual_override`, already shipped)
--   need no change here -- they only change how `v_weekly_budget` itself
--   was seeded, which this function already reads verbatim.
--
-- ITEMS 5/6 -- gearing law cap (band headroom / 1.5x) + the buy-in-for-
--   profit toy -- STRETCH, explicitly NOT built this pass (W33 priority:
--   items 1-4 tonight, 5-6 tomorrow). The existing promo-uplift gear
--   mechanism is UNCHANGED, but geared quantities now ALSO respect the
--   same universal max_band ceiling as everything else (never silently
--   MORE permissive than the ungeared path while the buy-in-for-profit
--   exception that would justify exceeding it does not exist yet) --
--   geared_packs is capped at the maximum whole packs that fit under
--   max_band, never force-zeroed like a breached NORMAL/HERO minimum.
--
-- =========================== PRE-v10 HISTORY (UNCHANGED MECHANISM, kept for
-- provenance -- ENG-012 order-time band recompute, ENG-013 SAB ledger
-- route, ENG-014 count_first claim-sign split, ENG-015 tiered demand
-- resolution (scan/draw GREATEST, the ENG-005 family-draw precedent),
-- ENG-016 budget-week attribution, ENG-017 promo buy-in window + naming,
-- ENG-019 NULL-guard on the three build-day params. Full narrative in prior
-- commits of this file (git history) -- not restated here since none of
-- these formulas changed in the v10 pass, only WHERE their output feeds
-- (target_level, scope) changed.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text);

CREATE FUNCTION public.rpc_bloom_order_recipe(
  p_store_code text,
  p_delivery_date date,
  p_next_delivery date DEFAULT NULL::date,
  p_soh_date date DEFAULT NULL::date,
  p_preset text DEFAULT NULL::text,
  p_days_cover_override numeric DEFAULT NULL::numeric,
  p_fit_to_budget boolean DEFAULT false,
  p_month_end_build_start_day integer DEFAULT 15,
  p_month_end_build_end_day integer DEFAULT 24,
  p_early_month_build_start_day integer DEFAULT 25,
  p_catchup_band_cap_multiple numeric DEFAULT 3.0,  -- RETIRED v10 (max_band ceiling is now universal); kept for signature compat, unused.
  p_route text DEFAULT NULL::text,
  p_soh_override jsonb DEFAULT NULL::jsonb,
  p_store_target_days integer DEFAULT 21,  -- v10 item 3, DEMO_CALIBRATION -- catch_up's aggregate stock-days target.
  p_max_order_stock_days numeric DEFAULT 35  -- canon v9 item 2 constant, made universal by v10 (no pack-size exception): a single forced pack that alone would sit longer than this many days does not order, routes to review.
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, dept_name text,
  route text, kvi_band text, archetype text, tier text, mode text, mode_reason text,
  range_state text, range_state_reason text,
  demand_source text, ros_window_used text, rhythm_adjusted_demand numeric,
  min_band numeric, max_band numeric, target_level numeric,
  soh numeric, lead_days_used integer, lead_days_source text, projected_soh numeric,
  count_first boolean, band_blocked_reason text,
  pack_forced_review boolean, hero_pack_over_max boolean,
  need_units numeric, pack_size smallint, pack_cost numeric,
  normal_packs integer, promo_active boolean, promo_nr bigint, promo_start date, promo_end date,
  promo_uplift numeric, promo_uplift_source text, promo_suffix text, promo_naming_gap boolean,
  geared_packs integer,
  packs_before_fit integer, suggested_packs integer, value numeric,
  gmroi_quartile integer, gmroi_capped boolean, gmroi_rank integer,
  budget_fit_applied boolean, budget_fit_reason text,
  budget_week_start date, budget_week_source text,
  is_bt_hero boolean, preset_applied text, frozen_focus_pending boolean,
  story text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int;
  v_override numeric;
  v_preset_essentials boolean;
  v_preset_catchup boolean;
  v_preset_applied text;
  v_fit_to_budget boolean;
  v_weekly_budget numeric;
  v_next_delivery date;
  v_format_group text;
  v_dept_nrs smallint[];
  v_ledger_route text;
  v_week_start date;
  v_week_source text;
  v_dows smallint[];
  v_buyin_lead_days int;
  v_band_violations int;
  v_sql text;
  v_direct_supplier_nrs bigint[];
BEGIN
  SET LOCAL statement_timeout = '30s';

  p_month_end_build_start_day := COALESCE(p_month_end_build_start_day, 15);
  p_month_end_build_end_day := COALESCE(p_month_end_build_end_day, 24);
  p_early_month_build_start_day := COALESCE(p_early_month_build_start_day, 25);
  p_store_target_days := COALESCE(p_store_target_days, 21);
  p_max_order_stock_days := COALESCE(p_max_order_stock_days, 35);

  IF p_route IS NULL THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk (canon SS14 v7 item 1 / v9 item 7)';
  END IF;

  IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN
    SELECT dc.dc_cycle_dept_nrs, dc.format_group INTO v_dept_nrs, v_format_group
    FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
    IF v_dept_nrs IS NULL THEN
      RAISE EXCEPTION 'no RULED bloom_dc_config row for store %', p_store_code;
    END IF;
    IF (p_route = 'DC_AMBIENT' AND v_format_group <> 'SPAR')
       OR (p_route = 'DC_TOPS' AND v_format_group <> 'TOPS') THEN
      RAISE EXCEPTION 'p_route % does not match store % (format %)', p_route, p_store_code, v_format_group;
    END IF;
  ELSIF p_route = 'DIRECT_BEER' THEN
    NULL;
  ELSIF p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN
    SELECT rc.direct_supplier_nrs INTO v_direct_supplier_nrs
    FROM bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = p_route AND rc.status = 'RULED';
    IF v_direct_supplier_nrs IS NULL THEN
      RAISE EXCEPTION 'no RULED bloom_route_config row for store % route %', p_store_code, p_route;
    END IF;
  ELSE
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk (canon SS14 v7 item 1 / v9 item 7)';
  END IF;

  v_ledger_route := CASE
    WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'
    WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'
    ELSE 'DC'
  END;

  SELECT sc.delivery_dows, sc.promo_buyin_lead_days INTO v_dows, v_buyin_lead_days
  FROM supplier_calendar sc WHERE sc.store_code = p_store_code AND sc.route_key = p_route;
  v_dows := COALESCE(v_dows, ARRAY[1,2,3,4,5,6,7]::smallint[]);
  v_buyin_lead_days := COALESCE(v_buyin_lead_days, 7);

  SELECT MAX(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;

  IF p_next_delivery IS NOT NULL THEN
    v_next_delivery := p_next_delivery;
    v_lead := GREATEST(p_next_delivery - p_delivery_date, 0);
    v_lead_source := 'calendar';
  ELSE
    v_next_delivery := p_delivery_date + 7;
    v_lead := GREATEST(p_delivery_date - v_anchor, 0);
    v_lead_source := 'fallback_anchor_gap';
  END IF;

  v_week_start := p_delivery_date - ((EXTRACT(ISODOW FROM p_delivery_date)::int + 1) % 7);

  SELECT obl.year_month INTO v_week_start
  FROM order_budget_ledger obl
  WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
    AND obl.year_month = v_week_start
  LIMIT 1;

  IF v_week_start IS NOT NULL THEN
    v_week_source := 'delivery_week_exact';
  ELSE
    v_week_start := p_delivery_date - ((EXTRACT(ISODOW FROM p_delivery_date)::int + 1) % 7);
    SELECT obl.year_month INTO v_week_start
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
      AND obl.year_month <= v_week_start
    ORDER BY obl.year_month DESC LIMIT 1;
    v_week_source := CASE WHEN v_week_start IS NOT NULL THEN 'nearest_past_week_fallback' ELSE 'no_ledger_row' END;
  END IF;

  v_preset_essentials := COALESCE(p_preset = 'order_essentials', false);
  v_preset_catchup := COALESCE(p_preset = 'catch_up', false);
  v_preset_applied := COALESCE(p_preset, 'standard');

  -- v10: the old flat 21d/10d cash-gated essentials cover retires with
  -- lineage. p_days_cover_override still passes through UNCHANGED as the
  -- diagnostic flat-cover branch used by the ENG-018 yardstick and the
  -- stock-state instrument's own pool call -- neither preset ever supplies
  -- it (both scenario_overview and every real desk call pass NULL here).
  v_override := p_days_cover_override;
  v_fit_to_budget := COALESCE(p_fit_to_budget, false);

  SELECT COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0) INTO v_weekly_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key=v_ledger_route AND obl.grain='weekly'
    AND obl.year_month = v_week_start;
  v_weekly_budget := COALESCE(v_weekly_budget, 0);

  v_sql := format($q$
    WITH route_beer_cfg AS (
      SELECT rc.merch_group_nrs, rc.excluded_supplier_types
      FROM bloom_route_config rc WHERE rc.store_code=%1$L AND rc.route_key='DIRECT_BEER'
    ),
    lnk AS (
      SELECT DISTINCT ON (sl.product_code) sl.product_code,
        GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost
      FROM sigma_supplier_link sl
      LEFT JOIN sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr
      LEFT JOIN route_beer_cfg rbc ON true
      WHERE sl.store_code=%1$L AND COALESCE(sl.status,'')<>'S' AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sm.supplier_type='Z')
          OR (%15$L::text = 'DIRECT_BEER' AND sm.status='A' AND NOT (sm.supplier_type = ANY(rbc.excluded_supplier_types)))
          OR (%15$L::text LIKE 'DIRECT\_%%' ESCAPE '\' AND %15$L::text <> 'DIRECT_BEER' AND sl.supplier_nr = ANY(%25$L::bigint[]))
        )
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%2$L::date),
    soh_override AS (
      SELECT (kv.key)::bigint AS product_code, (kv.value)::numeric AS soh
      FROM jsonb_each_text(COALESCE(%26$L::jsonb, '{}'::jsonb)) kv
    ),
    -- v10 item 1: cost28 (pure sales-history daily cost demand, matches
    -- rpc_bloom_stock_state's own formula exactly) -- feeds the catch_up
    -- aggregate stock-days walk so the instrument and the order agree.
    cost28 AS (
      SELECT s.product_code, SUM(s.cost_value) AS cost28
      FROM sigma_sales s
      WHERE s.store_code=%1$L AND s.period_kind='T' AND s.txn_kind=1
        AND s.sale_date > %2$L::date - 28 AND s.sale_date <= %2$L::date
      GROUP BY s.product_code
    ),
    sales AS (
      SELECT s.product_code,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 14) AS q14,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 28) AS q28,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 56) AS q56
      FROM sigma_sales s
      WHERE s.store_code = %1$L AND s.period_kind='T' AND s.txn_kind=1
        AND s.sale_date > %2$L::date - 56 AND s.sale_date <= %2$L::date
      GROUP BY s.product_code
    ),
    -- v10 item 1: the range-state pantry fact. EXCLUDED rows are dropped
    -- from the pool outright (accounting/cost-error/production/deposit --
    -- never orderable, same discipline as everywhere else these buckets
    -- are excluded). A missing row (l2_range_state not yet refreshed for
    -- this product) falls back to SLOW -- the safe, no-depth default,
    -- never a silent full-band order on an unclassified line.
    rs AS (SELECT product_code, range_state, state_reason FROM l2_range_state WHERE store_code=%1$L),
    pool AS MATERIALIZED (
      SELECT b.store_code, b.product_code,
        b.kvi_band, b.gmroi_quartile, b.gmroi_capped, b.band_blocked, b.band_blocked_reason,
        r.archetype,
        lnk.ps, lnk.pack_cost,
        sp.description, sp.dept_name, sp.tier, sp.department_nr, sp.merch_group_nr,
        COALESCE(sov.soh, so.soh, 0) AS soh_raw,
        COALESCE(rs.range_state, 'SLOW') AS range_state,
        COALESCE(rs.state_reason, 'no l2_range_state row -- defaulted to SLOW, no depth') AS range_state_reason,
        (COALESCE(rs.range_state,'') = 'HERO') AS is_bt_hero,
        COALESCE(sa.q14,0) AS q14, COALESCE(sa.q28,0) AS q28, COALESCE(sa.q56,0) AS q56,
        COALESCE(c28.cost28,0)/28.0 AS daily_cost_demand,
        rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected,
        rop.ros_draw_14d_corrected, rop.ros_draw_28d_corrected, rop.ros_draw_56d_corrected,
        rop.p_sell_estimate AS p_sell_scan, rop.p_sell_estimate_draw AS p_sell_draw,
        COALESCE(rop.unit_incommensurable, true) AS unit_incommensurable
      FROM l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN l2_rhythm_profile r ON r.store_code=b.store_code AND r.product_code=b.product_code
      LEFT JOIN l2_stock_position sp ON sp.store_code=b.store_code AND sp.product_code=b.product_code
      LEFT JOIN soh so ON so.product_code=b.product_code
      LEFT JOIN soh_override sov ON sov.product_code=b.product_code
      LEFT JOIN rs ON rs.product_code=b.product_code
      LEFT JOIN sales sa ON sa.product_code=b.product_code
      LEFT JOIN cost28 c28 ON c28.product_code=b.product_code
      LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code=b.store_code AND rop.product_code=b.product_code
      WHERE b.store_code=%1$L
        AND COALESCE(rs.range_state,'') <> 'EXCLUDED'
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(%16$L::smallint[]))
          OR (%15$L::text = 'DIRECT_BEER' AND sp.merch_group_nr IN (SELECT unnest(merch_group_nrs) FROM route_beer_cfg) AND EXISTS (SELECT 1 FROM sigma_movements mbr JOIN sigma_supplier_master smbr ON smbr.store_code = mbr.store_code AND smbr.supplier_nr = mbr.supplier_nr AND smbr.supplier_type <> 'Z' WHERE mbr.store_code = %1$L AND mbr.product_code = sp.product_code AND mbr.movement_type = 'R' AND mbr.movement_process = 'W' AND mbr.movement_date >= CURRENT_DATE - 182))
          -- ENG-029 (canon 7d, receipts not links): DIRECT_BEER requires a real non-Z DIRECT RECEIPT,
          -- not just a beer-merch-group link. Excludes link-only DC-supplied beer (Distell/Diageo/
          -- Heineken/DGB/Isicebi = zero direct receipts, arrive on the DC truck) that was double-counting
          -- against DC_TOPS. 21355 SAB order 41 -> 28 lines, double-count 19 -> 7. The 7 remaining are
          -- genuine SAB beers ALSO DC-orderable (dual-sourced) -- their DC-side exclusion is a routing
          -- ruling owed to PM. R22: isolated (DC_AMBIENT/DC_TOPS/DIRECT_<brand> byte-identical before/after).
          OR (%15$L::text LIKE 'DIRECT\_%%' ESCAPE '\' AND %15$L::text <> 'DIRECT_BEER')
        )
    ),
    tiered AS (
      SELECT p.*,
        CASE p.tier WHEN 'TOP_100' THEN (CASE WHEN p.q14=0 THEN p.q28/28.0 ELSE p.q14/14.0 END)
          WHEN 'TOP_1000' THEN p.q28/28.0 ELSE p.q56/56.0 END AS scan_raw,
        CASE p.tier WHEN 'TOP_100' THEN (CASE WHEN p.q14=0 THEN p.ros_draw_28d_corrected ELSE p.ros_draw_14d_corrected END)
          WHEN 'TOP_1000' THEN p.ros_draw_28d_corrected ELSE p.ros_draw_56d_corrected END AS draw_corrected,
        (CASE p.tier WHEN 'TOP_100' THEN (CASE WHEN p.q14=0 THEN 'ros_28d (q14=0 fallback)' ELSE 'ros_14d' END)
          WHEN 'TOP_1000' THEN 'ros_28d' ELSE 'ros_56d' END) AS ros_window_used
      FROM pool p
    ),
    guarded AS (
      SELECT t.*,
        ROUND(COALESCE(t.p_sell_draw,0) * 182) AS draw_selling_days,
        (NOT t.unit_incommensurable
          AND (t.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(t.p_sell_draw,0)*182 >= 8)) AS draw_eligible
      FROM tiered t
    ),
    demand_resolved AS (
      SELECT g.*,
        (CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END) AS draw_used,
        GREATEST(g.scan_raw, COALESCE((CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END),0)) AS ros_final,
        (g.draw_eligible AND COALESCE(g.draw_corrected,0) > g.scan_raw) AS demand_from_draw
      FROM guarded g
    ),
    moded AS (
      SELECT d.*,
        CASE
          WHEN d.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'
          WHEN d.archetype = 'EARLY_MONTH' AND %4$s >= %7$s THEN 'build'
          ELSE 'minimum'
        END AS mode,
        CASE d.kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END AS safety_days
      FROM demand_resolved d
    ),
    banded AS (
      SELECT m.*,
        (m.ros_final * %9$s) + (m.safety_days * m.ros_final) AS min_band_ot,
        (CASE WHEN m.gmroi_capped THEN %9$s * 0.5 ELSE %9$s END) AS review_days_ot
      FROM moded m
    ),
    banded2 AS (
      SELECT b.*, (b.min_band_ot + (b.ros_final * b.review_days_ot)) AS max_band_ot
      FROM banded b
    ),
    -- promo match/naming moved AHEAD of depth resolution (v10) -- essentials'
    -- CORE-elevated-by-promo rule (item 3) needs promo_active BEFORE the
    -- target_level is computed, not after. Query bodies UNCHANGED from the
    -- pre-v10 file, only the source CTE (banded2 instead of packs) and
    -- position moved.
    promo_match AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.promo_nr, pa.start_date, pa.end_date, pa.status,
        pa.list_cost AS promo_unit_cost, sp2.description AS promo_description
      FROM banded2 pk
      JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
      LEFT JOIN public.sigma_promotions sp2 ON sp2.store_code=%1$L AND sp2.promo_nr=pa.promo_nr
      WHERE %23$L::date >= (pa.start_date - %22$L::int)
        AND %23$L::date <= (
          SELECT MAX(gs) FROM generate_series(pa.end_date - 6, pa.end_date, interval '1 day') gs
          WHERE EXTRACT(ISODOW FROM gs)::smallint = ANY(%21$L::smallint[])
        )
      ORDER BY pk.product_code, (pa.status='1') DESC, pa.end_date DESC
    ),
    with_promo_flag AS (
      SELECT b.*, (pm.promo_nr IS NOT NULL) AS promo_active, pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end,
        pm.promo_unit_cost, pm.promo_description,
        COALESCE(
          substring(pm.promo_description from '\(([A-Za-z0-9]+)\)\s*$'),
          substring(pm.promo_description from 'DC Promotion Number\s+(\S+)')
        ) AS promo_suffix_calc
      FROM banded2 b LEFT JOIN promo_match pm ON pm.product_code=b.product_code
    ),
    -- v10 items 2/3: DEPTH resolution. target_level_v10 per range_state x
    -- scenario x kvi_band x promo x mode. max_band_ot is now the universal
    -- ceiling every branch respects (never assigned above it).
    depthed AS (
      SELECT w.*,
        (CASE
           WHEN w.range_state = 'HERO' THEN w.max_band_ot
           WHEN w.range_state = 'CORE' AND %11$L::boolean THEN w.max_band_ot  -- catch_up: HERO+CORE both to order-up-to; the walk below decides WHICH core lines survive the cutoff, not the per-line target itself.
           WHEN w.range_state = 'CORE' AND %24$L::boolean THEN  -- order_essentials
             (CASE WHEN w.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR w.promo_active
                   THEN (CASE WHEN w.mode='build' THEN w.max_band_ot ELSE w.min_band_ot END)
                   ELSE w.min_band_ot END)
           WHEN w.range_state = 'CORE' THEN  -- full / fitted
             (CASE WHEN w.mode='build' THEN w.max_band_ot ELSE w.min_band_ot END)
           ELSE GREATEST(w.soh_raw, 0)  -- SLOW/MARKDOWN/DERANGE/VERIFY: no depth, target = current position
         END) AS target_level_v10,
        (CASE
           WHEN w.range_state IN ('HERO','CORE') THEN 'range_state=' || w.range_state
                || CASE WHEN w.range_state='CORE' AND %24$L::boolean AND NOT (w.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR w.promo_active) THEN ' (essentials: min-band presence only)'
                        WHEN w.range_state='CORE' AND %11$L::boolean THEN ' (catch-up: order-up-to, subject to the aggregate-days walk)'
                        ELSE format(' (%%s mode)', w.mode) END
           ELSE 'range_state=' || w.range_state || ': ' || w.range_state_reason
         END) AS target_reason
      FROM with_promo_flag w
    ),
    -- v10 item 2: the flat-day-cover override branch (p_days_cover_override
    -- non-NULL) is a DIAGNOSTIC path only -- used by rpc_bloom_stock_state's
    -- own pool call and the ENG-018 yardstick, never by a real scenario
    -- (both scenario_overview and every live desk call pass NULL here).
    -- When present it OVERRIDES target_level_v10 outright, unchanged
    -- behaviour from the pre-v10 file.
    targeted AS (
      SELECT d.*,
        CASE WHEN %8$L IS NOT NULL THEN LEAST(d.ros_final * %8$L::numeric, d.max_band_ot)
             ELSE d.target_level_v10 END AS target_level,
        CASE WHEN %8$L IS NOT NULL THEN format('flat %%s-day cover override (diagnostic)', %8$L::text)
             ELSE d.target_reason END AS mode_reason
      FROM depthed d
    ),
    needc AS (
      SELECT t.*,
        t.band_blocked AS count_first,
        (CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END) AS soh_used,
        GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s AS proj,
        -- v10 item 2: SLOW/MARKDOWN/DERANGE/VERIFY get need=0 EXPLICITLY,
        -- never derived. Their target_level_v10 = current soh_raw (a static
        -- snapshot) minus the lead-time depletion subtraction below would
        -- otherwise manufacture a positive "need to replenish back up to
        -- today's position" for any line with real demand -- exactly the
        -- "no depth" rule this state exists to enforce, defeated by the
        -- same formula HERO/CORE use. Explicit beats implicit here.
        (CASE WHEN t.range_state NOT IN ('HERO','CORE') THEN 0
         ELSE GREATEST(t.target_level - (GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s), 0)
         END) AS needu
      FROM targeted t
    ),
    -- v10 item 2: the universal max_band ceiling. A NORMAL/HERO minimum
    -- (>=1 pack forced by need>0) that would push post-order stock past
    -- max_band_ot is NEVER ordered -- pack_forced_review routes it to a
    -- human instead. HERO tripping this gets its own flag on top (the W31
    -- hero-never-empty-vs-never-over-max collision -- no auto-resolution).
    packs AS (
      SELECT n.*,
        (CASE WHEN n.ros_final<=0 THEN 0
              WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)
              ELSE 0 END)::int AS normal_packs_raw
      FROM needc n
    ),
    -- v10 item 2 / canon v9 item 2, made universal (no pack-size exception):
    -- the ceiling is DAYS OF STOCK a single forced pack would create
    -- (soh + one pack) / demand vs p_max_order_stock_days (35) -- NOT
    -- max_band_ot directly. max_band_ot is a tight (~3-7 day) reorder-cycle
    -- figure; comparing a single indivisible pack against it force-reviewed
    -- ~98%% of real need (verified live) because most pack sizes simply
    -- exceed a few days of demand -- completely normal retail ordering,
    -- not the extreme case v9/v30 named (AQUAFRESH 670 days, Select Rice
    -- 448 days). The 35-day figure is v9's own named constant; v10's
    -- change is removing the exception that let pack-forced lines through
    -- past it, not shrinking the ceiling itself to the reorder band.
    packs_ceiled AS (
      SELECT p.*,
        (p.normal_packs_raw >= 1 AND p.ros_final > 0
          AND (GREATEST(p.soh_used,0) + p.normal_packs_raw * p.ps) / p.ros_final > %28$s
        ) AS pack_forced_review,
        (CASE
           WHEN p.normal_packs_raw >= 1 AND p.ros_final > 0
             AND (GREATEST(p.soh_used,0) + p.normal_packs_raw * p.ps) / p.ros_final > %28$s
           THEN 0
           ELSE p.normal_packs_raw
         END)::int AS normal_packs_calc
      FROM packs p
    ),
    gear_source AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.start_date, pa.end_date
      FROM packs_ceiled pk JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
        AND pa.status='2' AND pa.end_date < %2$L::date AND pa.start_date >= DATE '2025-06-01'
      ORDER BY pk.product_code, pa.end_date DESC
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
      SELECT pk.*, CASE WHEN gc.base_ros IS NULL OR gc.base_ros=0 THEN 2.0 ELSE LEAST(GREATEST(gc.promo_ros/gc.base_ros,1.0),5.0) END AS gear,
        (gc.base_ros IS NOT NULL AND gc.base_ros<>0) AS gear_from_own_promo
      FROM packs_ceiled pk LEFT JOIN gear_calc gc ON gc.product_code=pk.product_code
    ),
    geared_calc AS (
      SELECT wg.*,
        GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s AS proj_geared,
        -- v10 item 2: same "tail states never get a manufactured need" fix
        -- as needc.needu, applied here too -- needu_geared subtracts the
        -- GEARED (up to 5x) depletion from a STATIC soh-snapshot target,
        -- which would otherwise fabricate an even larger phantom need on a
        -- promo-active SLOW/MARKDOWN/DERANGE/VERIFY line than the ungeared
        -- path did (caught live: 8 tail lines ordering under FULL/FITTED
        -- after the needc fix alone).
        (CASE WHEN wg.range_state NOT IN ('HERO','CORE') THEN 0
         ELSE GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s), 0)
         END) AS needu_geared
      FROM with_gear wg
    ),
    geared AS (
      -- v10: geared packs respect the SAME 35-day tolerance as normal packs
      -- (real bug caught in R22 verification: an EARLIER draft capped geared
      -- packs at "must fit entirely under max_band, zero tolerance" while
      -- normal packs got the 35-day allowance -- inconsistent, and it
      -- silently zeroed an OUT-OF-STOCK HERO (SPAR OLIVE OIL SA, soh=0,
      -- promo-eligible, max_band=1.0 vs pack_size=6) the instant a promo
      -- made it price on the geared path instead of normal. Same forced-
      -- minimum-with-35-day-review logic, using the GEARED rate (ros_final
      -- x gear) as the demand denominator since that is the line's own
      -- accelerated consumption during the promo.
      SELECT g.*,
        (CASE WHEN g.ros_final<=0 THEN 0
              WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1)
              ELSE 0 END)::int AS geared_packs_raw
      FROM geared_calc g
    ),
    geared_ceiled AS (
      -- v10: denominator is the TRUE (ungeared) ros_final, not ros_final*gear
      -- -- same yardstick packs_ceiled uses for normal packs. Using the
      -- geared (promo-inflated, up to 5x) rate as the denominator let a
      -- promo line pass the 35-day check on an assumption that only holds
      -- DURING the promo window -- caught live: IMANA GRAVY ROAST CHICKEN
      -- cleared geared_ceiled at "35 days" on the geared rate while its real
      -- days-of-stock (true ros_final) was 159.6. This is the exact tension
      -- W29/W30 named and explicitly deferred to items 5/6 (buy-in-for-
      -- profit needs its own proven sell-through, not assumed promo-rate
      -- persistence) -- the conservative default here (measure against the
      -- real rate) is the safe placeholder until that toy exists, never the
      -- inflated one.
      SELECT g.*,
        (CASE
           WHEN g.geared_packs_raw >= 1 AND g.ros_final > 0
             AND (GREATEST(g.soh_used,0) + g.geared_packs_raw * g.ps) / g.ros_final > %28$s
           THEN 0
           ELSE g.geared_packs_raw
         END)::int AS geared_packs_calc
      FROM geared g
    ),
    resolved AS (
      SELECT g.*,
        CASE
          WHEN %24$L::boolean THEN g.normal_packs_calc  -- W2: essentials never gears
          WHEN g.promo_active THEN g.geared_packs_calc
          ELSE g.normal_packs_calc
        END AS resolved_packs_calc
      FROM geared_ceiled g
    ),
    gmroi AS (
      SELECT g.product_code, g.gmroi_rank FROM l2_gmroi_profile g WHERE g.store_code=%1$L
    ),
    ranked AS (
      SELECT r.*, gm.gmroi_rank,
        (r.range_state = 'HERO' OR r.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) AS is_protected,
        (CASE r.kvi_band WHEN 'KVI_CRITICAL' THEN 1 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 3 END) AS kvi_priority
      FROM resolved r LEFT JOIN gmroi gm ON gm.product_code=r.product_code
    ),
    -- v10 item 3: THE CATCH-UP WALK. HERO is unconditionally included
    -- (never subject to the cutoff, "never empty"). Eligible CORE lines
    -- (demand>0) rank by (HERO first / KVI priority / gmroi_rank), fill
    -- top-down to their own order-up-to (resolved_packs_calc, already
    -- max_band-ceilinged above), and the running cumulative aggregate
    -- stock-days (SAME cost formula as rpc_bloom_stock_state) OR the
    -- week's budget decides the cutoff -- whichever binds first.
    catchup_ranked AS (
      SELECT r.*,
        (r.range_state = 'HERO') AS cu_always_in,
        (r.range_state IN ('HERO','CORE') AND r.ros_final > 0) AS cu_eligible,
        ROW_NUMBER() OVER (
          ORDER BY (CASE WHEN r.range_state='HERO' THEN 0 ELSE 1 END), r.kvi_priority, r.gmroi_rank NULLS LAST, r.product_code
        ) AS cu_rank
      FROM ranked r
    ),
    catchup_totals AS (
      SELECT
        SUM(GREATEST(soh_used,0) * (pack_cost / NULLIF(ps,0))) FILTER (WHERE cu_eligible) AS baseline_stock_cost_raw,
        -- HERO's own catch-up order is unconditional (never subject to the
        -- walk/cutoff) -- fold it into the baseline BEFORE judging how far
        -- into CORE to fill, and reserve its rand out of the week's budget
        -- before CORE gets a look-in. Never trimmed, same floor-protection
        -- discipline as item 4's fit (W30 red-team fix).
        SUM(resolved_packs_calc * pack_cost) FILTER (WHERE cu_always_in) AS hero_added_value,
        SUM(daily_cost_demand) FILTER (WHERE cu_eligible) AS total_daily_cost_demand
      FROM catchup_ranked
    ),
    catchup_walk AS (
      SELECT c.*,
        (c.resolved_packs_calc * c.pack_cost) AS cu_added_value,
        COALESCE(SUM(CASE WHEN c.cu_eligible AND NOT c.cu_always_in THEN c.resolved_packs_calc * c.pack_cost ELSE 0 END)
          OVER (ORDER BY c.cu_rank ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cu_value_before,
        (COALESCE(ct.baseline_stock_cost_raw,0) + COALESCE(ct.hero_added_value,0)) AS baseline_stock_cost,
        COALESCE(ct.hero_added_value,0) AS hero_added_value,
        ct.total_daily_cost_demand
      FROM catchup_ranked c CROSS JOIN catchup_totals ct
    ),
    catchup_decided AS (
      SELECT w.*,
        (CASE WHEN COALESCE(w.total_daily_cost_demand,0) > 0
              THEN (COALESCE(w.baseline_stock_cost,0) + w.cu_value_before) / w.total_daily_cost_demand
              ELSE NULL END) AS cu_days_before,
        (w.cu_always_in
          OR (w.cu_eligible
              AND (COALESCE(w.total_daily_cost_demand,0) = 0
                   OR (COALESCE(w.baseline_stock_cost,0) + w.cu_value_before) / w.total_daily_cost_demand < %27$s)
              AND w.cu_value_before < GREATEST(%14$s - w.hero_added_value, 0))
        ) AS cu_include
      FROM catchup_walk w
    ),
    finalp AS (
      SELECT b.*,
        (%13$L::boolean OR %11$L::boolean) AS fit_applied,
        CASE
          WHEN %11$L::boolean THEN  -- catch_up: its own walk decides, generic fit never re-runs on top
            (CASE WHEN b.cu_include THEN b.resolved_packs_calc ELSE 0 END)
          WHEN NOT %13$L::boolean THEN b.resolved_packs_calc
          WHEN b.is_protected THEN b.resolved_packs_calc
          WHEN protected_totals.protected_spend >= %14$L::numeric THEN 0
          ELSE FLOOR(b.resolved_packs_calc * LEAST(
                 (%14$L::numeric - protected_totals.protected_spend) / NULLIF(protected_totals.unprotected_spend, 0), 1.0))
        END::int AS final_packs,
        CASE
          WHEN %11$L::boolean THEN (CASE WHEN b.cu_include THEN 'catchup_priority_fill' ELSE 'catchup_below_cutoff' END)
          WHEN NOT %13$L::boolean THEN NULL
          WHEN b.is_protected THEN 'protected_kvi_hero'
          WHEN protected_totals.protected_spend >= %14$L::numeric THEN 'scaled_to_budget (protected spend alone exceeds budget)'
          WHEN protected_totals.unprotected_spend = 0 THEN 'fits'
          WHEN (%14$L::numeric - protected_totals.protected_spend) / NULLIF(protected_totals.unprotected_spend,0) >= 1.0 THEN 'fits'
          ELSE 'scaled_to_budget'
        END AS fit_reason
      FROM catchup_decided b
      CROSS JOIN (
        SELECT
          SUM(CASE WHEN is_protected THEN resolved_packs_calc*pack_cost ELSE 0 END) AS protected_spend,
          SUM(CASE WHEN NOT is_protected THEN resolved_packs_calc*pack_cost ELSE 0 END) AS unprotected_spend
        FROM catchup_decided
      ) protected_totals
    )
    SELECT
      %1$L::text AS store_code, pk.product_code AS product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')) AS ean,
      pk.description AS description, pk.dept_name AS dept_name, %15$L::text AS route,
      pk.kvi_band AS kvi_band, pk.archetype AS archetype, pk.tier AS tier, pk.mode AS mode, pk.mode_reason AS mode_reason,
      pk.range_state AS range_state, pk.range_state_reason AS range_state_reason,
      (CASE WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END) AS demand_source, pk.ros_window_used AS ros_window_used,
      ROUND(pk.ros_final,4) AS rhythm_adjusted_demand,
      ROUND(pk.min_band_ot,2) AS min_band, ROUND(pk.max_band_ot,2) AS max_band, ROUND(pk.target_level,2) AS target_level,
      pk.soh_raw AS soh, %9$s::int AS lead_days_used, %17$L::text AS lead_days_source, ROUND(pk.proj,2) AS projected_soh,
      pk.count_first AS count_first, pk.band_blocked_reason AS band_blocked_reason,
      pk.pack_forced_review AS pack_forced_review, (pk.pack_forced_review AND pk.range_state='HERO') AS hero_pack_over_max,
      ROUND(pk.needu,2) AS need_units, pk.ps AS pack_size, ROUND(pk.pack_cost,2) AS pack_cost,
      pk.normal_packs_calc AS normal_packs, pk.promo_active AS promo_active, pk.promo_nr AS promo_nr, pk.promo_start AS promo_start, pk.promo_end AS promo_end,
      ROUND(pk.gear,4) AS promo_uplift, (CASE WHEN pk.gear_from_own_promo THEN 'own_promo' ELSE 'default' END) AS promo_uplift_source,
      pk.promo_suffix_calc AS promo_suffix, (pk.promo_active AND pk.promo_suffix_calc IS NULL) AS promo_naming_gap,
      pk.geared_packs_calc AS geared_packs,
      pk.resolved_packs_calc AS packs_before_fit, pk.final_packs AS suggested_packs, ROUND((pk.final_packs*pk.pack_cost)::numeric,2) AS value,
      pk.gmroi_quartile AS gmroi_quartile, pk.gmroi_capped AS gmroi_capped, pk.gmroi_rank AS gmroi_rank,
      pk.fit_applied AS budget_fit_applied, pk.fit_reason AS budget_fit_reason,
      %19$L::date AS budget_week_start, %20$L::text AS budget_week_source,
      pk.is_bt_hero AS is_bt_hero, %10$L::text AS preset_applied, false AS frozen_focus_pending,
      format('%%s [%%s] tier KVI=%%s, archetype=%%s -> %%s, window=%%s demand=%%s, band [%%s|%%s], SOH %%s, lead %%s(%%s) -> proj %%s, need %%s = %%s packs%%s%%s%%s%%s',
        COALESCE(pk.tier,'-'), pk.range_state, COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode_reason,
        pk.ros_window_used, ROUND(pk.ros_final,2),
        ROUND(pk.min_band_ot,1), ROUND(pk.max_band_ot,1), pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.resolved_packs_calc,
        CASE WHEN pk.pack_forced_review THEN format(' | PACK_FORCED_REVIEW: one pack alone (%%s units) exceeds max_band (%%s) -- not ordered, %%s',
               pk.ps, ROUND(pk.max_band_ot,1), CASE WHEN pk.range_state='HERO' THEN 'HERO: needs a human call (smaller pack/loose unit)' ELSE 'route to derange/review' END) ELSE '' END,
        CASE WHEN pk.count_first THEN format(' | COUNT_FIRST: %%s', CASE WHEN pk.soh_raw < 0 THEN 'negative claim, SOH treated as 0' ELSE 'positive claim, ordered on it, count still rides' END) ELSE '' END,
        CASE WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,
        CASE WHEN pk.fit_applied THEN format(' | budget fit: %%s (%%s -> %%s packs)', pk.fit_reason, pk.resolved_packs_calc, pk.final_packs) ELSE '' END) AS story
    FROM finalp pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
  $q$, p_store_code, v_soh_dt, NULL::boolean, v_dom,
       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied,
       v_preset_catchup, p_catchup_band_cap_multiple, v_fit_to_budget, v_weekly_budget,
       p_route, v_dept_nrs, v_lead_source, v_next_delivery, v_week_start, v_week_source,
       v_dows, v_buyin_lead_days, p_delivery_date, v_preset_essentials, v_direct_supplier_nrs, p_soh_override,
       p_store_target_days, p_max_order_stock_days);

  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
  EXECUTE format('CREATE TEMP TABLE _bloom_recipe_out AS %s', v_sql);

  -- v10 item 2: population-level ceiling proof, flag never block (R21/R22 --
  -- this is now the load-bearing invariant the old canon v7 item 9 band
  -- check used to be). Measured against p_max_order_stock_days (the ceiling
  -- actually enforced by packs_ceiled/geared_ceiled), never max_band itself
  -- -- max_band is a tight (~3-7 day) reorder-cycle figure a single
  -- indivisible pack legitimately overshoots on ordinary retail pack sizes;
  -- comparing against it here would flag routine, correct rounding as a
  -- false violation (verified live: 900+ false positives at 10116 before
  -- this fix).
  EXECUTE format(
    'SELECT count(*) FROM _bloom_recipe_out WHERE suggested_packs > 0 AND rhythm_adjusted_demand > 0
       AND (soh + suggested_packs*pack_size) / rhythm_adjusted_demand > %s',
    p_max_order_stock_days)
    INTO v_band_violations;
  IF v_band_violations > 0 THEN
    RAISE WARNING 'canon v10 item 2: % row(s) exceed the %-day order-stock ceiling (store=%, route=%, delivery=%, preset=%)',
      v_band_violations, p_max_order_stock_days, p_store_code, p_route, p_delivery_date, v_preset_applied;
  END IF;

  RETURN QUERY EXECUTE 'SELECT * FROM _bloom_recipe_out ORDER BY rhythm_adjusted_demand DESC, product_code';
  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
