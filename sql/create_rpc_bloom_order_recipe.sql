-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5 (+ items 7/8, §3b) -- the profile-driven Recipe RPC.
--
-- =========================== SB-CC-BLOOM-007 REWRITE (2026-07-11) ==========
-- Pieter walked the shipped Recipe screen and it missed the mark -- not the
-- maths, the wrapping. Corrective rulings: CLEANUP-ENGINE-CANON SS14
-- ADDENDUM v7. Brief: Bloom/SB-CC-BLOOM-007-order-desks-and-deviation-
-- corrections.md. Five deviations corrected here (items 2-6 of that brief),
-- NO formula changes to the 8-step engine itself -- every change below is
-- scope, inputs or an additive leg, per the brief's own governing constraint.
--
-- ITEM 2 -- ROUTE SCOPE (was: no route scope, pool mixed ambient/TOPS/beer).
--   New REQUIRED param p_route ('DC_AMBIENT'|'DC_TOPS'|'DIRECT_BEER'). A
--   call without it is a defect (canon v7 item 1), so it errors loudly
--   rather than silently defaulting. DC_AMBIENT/DC_TOPS read
--   bloom_dc_config.dc_cycle_dept_nrs (validated against the store's own
--   format_group -- calling DC_AMBIENT on a TOPS store is also a defect).
--   DIRECT_BEER reads bloom_route_config exactly as rpc_bloom_order_direct_
--   beer already does (merch_group_nrs + excluded_supplier_types) -- same
--   lnk pattern ported verbatim, not reinvented.
--
-- ITEM 3 -- DROP COVER (was: p_next_delivery accepted but never read, a
--   fixed anchor-to-delivery gap used instead). v_lead (the recipe's own
--   SOH-projection lead, output as lead_days_used) now reads
--   GREATEST(p_next_delivery - p_delivery_date, 0) -- "days from this
--   delivery to the next on the same route" per canon v7 item 2 -- when the
--   caller supplies p_next_delivery (the desk screen always will, prepop'd
--   from rpc_bloom_next_deliveries). Falls back to the old anchor-gap
--   constant only when p_next_delivery is NULL (legacy/manual calls).
--   lead_days_source names which per row (R29).
--   NOTE, scope boundary named plainly: l2_stock_band's OWN internal
--   lead_days_used/target_cover_days_used columns are a SEPARATE, currently
--   flat (3.5/7 uniform) constant baked into that matview's own formula --
--   "the band formulas (ENG-001 v2 form stands)" is explicitly protected
--   in the brief's own build-order table, and l2_stock_band has 24+ proven
--   dependents (CLEANUP-ENGINE-CANON SS13) -- touching its refresh is a much
--   larger, separate-session change. This rewrite only touches THIS
--   function's own local lead variable, which is what the brief's proof
--   point tests (a row's own lead_days_used output). Named gap, not silent.
--
-- ITEM 4 -- COUNT_FIRST REVERSION (was: WHERE b.band_blocked=false excluded
--   the line from the pool entirely). Removed. A band_blocked line now
--   orders with soh_raw forced to 0 (conservative SOH per canon v7 item 5)
--   and carries count_first=true + band_blocked_reason on the row -- the
--   count list "rides the response" as these flagged rows, not a separate
--   table (matches the existing COUNT-FIRST pink-wash pattern already used
--   for selling-negative lines on the DC screen).
--
-- ITEM 5 -- 21-DAY WEEKLY MINIMUM on the order_essentials preset (was: flat
--   10-day override always). New order_budget_ledger.cash_constrained
--   column (added this migration set, see create_order_budget_ledger_
--   cash_constrained.sql) is read for the store's current DC week: FALSE
--   (default, 82%-forecast basis) -> 21-day cover; TRUE (80% cash-
--   constrained week) -> flat 10-day preset cover, per canon v7 item 3.
--   catch_up's 21-day target is UNCHANGED (already 21, not touched).
--
-- ITEM 6 -- NORMAL VS GEARED (was: no promo leg at all). Ported verbatim
--   from rpc_bloom_order_dc's own promo_match/gear_calc pattern: a line
--   inside an active-or-adjacent promo window gears its demand (promo ROS
--   / pre-promo baseline ROS, clamped [1.0,5.0], default 2.0 with no own-
--   promo history), computes geared packs alongside normal packs using the
--   SAME target_level, and suggested_packs = promo_active ? geared : normal
--   -- exactly DC's own rule, never reinvented.
--
-- Reuses the pantry built in items 1-4 -- reuse before rewrite (governing
-- constraint 1). Tier is NOT a demand input (BLOOM-004 §3 item 5) --
-- l2_stock_position.tier is read here ONLY as a preset pool-filter signal.
-- =============================================================================
--
-- ORDER MODE (BLOOM-003 §2b.5): mode is a property of the DROP, geared per
--   line by archetype. EVERYDAY never gears (always targets min_band).
--   MONTH_END/EARLY_MONTH gear to 'build' (target max_band) inside a
--   day-of-month run-up window, else 'minimum' (target min_band). Manual
--   override: p_days_cover_override (or a preset's own flat target)
--   REPLACES mode/band targeting entirely.
--
-- KVI FLOOR: enforced by construction (minimum mode targets min_band, which
--   bakes in the KVI safety-days floor) AND by the budget-fit allocator
--   (KVI_CRITICAL/IMPORTANT lines never trimmed, protected first).
--
-- GMROI FILL: l2_stock_band.gmroi_quartile/gmroi_capped surfaced not
--   recomputed; the Fit-to-Budget allocator spends remaining budget in
--   GMROI-rank order, best return first.
--
-- FIT TO BUDGET: p_fit_to_budget boolean, off by default. When on: every
--   KVI_CRITICAL/KVI_IMPORTANT line's packs are NEVER trimmed (protected
--   spend, summed first); the remaining weekly DC budget (order_budget_
--   ledger, route_key='DC', grain='weekly', most recent week, less
--   committed_amount) is spent down GMROI rank via a running-cumulative
--   window function. budget_fit_reason names which per row: protected_kvi /
--   fits / trimmed_partial / trimmed_to_zero. packs_before_fit keeps the
--   pre-trim (promo-resolved) figure for audit.
--
-- PRESETS: order_essentials = item-5 cover (21 or 10, cash-basis-gated) +
--   pool filter (KVI_CRITICAL/IMPORTANT OR l2_bt_heroes OR tier IN
--   TOP_100/TOP_1000). catch_up = flat 21-day target, same pool filter,
--   band-capped at p_catchup_band_cap_multiple x max_band, Fit-to-Budget
--   FORCED ON. Frozen focus is not yet an engine set (BLOOM-004 item 7,
--   trails into next week per the landing window) -- frozen_focus_pending
--   flags this honestly per row when either preset is active.
--
-- POOL: l2_stock_band (sourced FROM l2_kvi_profile) INNER JOIN an active
--   supplier link matching the route (Z for DC routes, non-excluded types
--   for DIRECT_BEER).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric);

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
  p_catchup_band_cap_multiple numeric DEFAULT 3.0,
  p_route text DEFAULT NULL::text
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, dept_name text,
  route text, kvi_band text, archetype text, mode text, mode_reason text,
  demand_source text, rhythm_adjusted_demand numeric,
  min_band numeric, max_band numeric, target_level numeric,
  soh numeric, lead_days_used integer, lead_days_source text, projected_soh numeric,
  count_first boolean, band_blocked_reason text,
  need_units numeric, pack_size smallint, pack_cost numeric,
  normal_packs integer, promo_active boolean, promo_nr bigint, promo_start date, promo_end date,
  promo_uplift numeric, promo_uplift_source text, geared_packs integer,
  packs_before_fit integer, suggested_packs integer, value numeric,
  gmroi_quartile integer, gmroi_capped boolean, gmroi_rank integer,
  budget_fit_applied boolean, budget_fit_reason text,
  tier text, is_bt_hero boolean, preset_applied text, frozen_focus_pending boolean,
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
  v_pool_filter_active boolean;
  v_preset_applied text;
  v_fit_to_budget boolean;
  v_weekly_dc_budget numeric;
  v_next_delivery date;
  v_format_group text;
  v_dept_nrs smallint[];
  v_cash_constrained boolean;
  v_essentials_days numeric;
BEGIN
  SET LOCAL statement_timeout = '30s';

  -- ITEM 2: route scope is mandatory (canon v7 item 1 -- a call without a
  -- route is a defect, not a wider order).
  IF p_route IS NULL OR p_route NOT IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER') THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS or DIRECT_BEER (canon SS14 v7 item 1)';
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
  END IF;

  SELECT MAX(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;

  -- ITEM 3: drop cover replaces the fixed anchor-gap lead where the caller
  -- supplies the real next-delivery date (the desk screen always will).
  IF p_next_delivery IS NOT NULL THEN
    v_next_delivery := p_next_delivery;
    v_lead := GREATEST(p_next_delivery - p_delivery_date, 0);
    v_lead_source := 'calendar';
  ELSE
    v_next_delivery := p_delivery_date + 7;
    v_lead := GREATEST(p_delivery_date - v_anchor, 0);
    v_lead_source := 'fallback_anchor_gap';
  END IF;

  v_preset_essentials := COALESCE(p_preset = 'order_essentials', false);
  v_preset_catchup := COALESCE(p_preset = 'catch_up', false);
  v_pool_filter_active := v_preset_essentials OR v_preset_catchup;
  v_preset_applied := COALESCE(p_preset, 'standard');

  -- ITEM 5: the 21-day weekly minimum on order_essentials, gated on the
  -- week's cash basis (canon v7 item 3). catch_up's 21-day target is
  -- unchanged (not gated -- it is already the flat target by definition).
  IF v_preset_essentials THEN
    SELECT COALESCE(obl.cash_constrained, false) INTO v_cash_constrained
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code AND obl.route_key = 'DC' AND obl.grain = 'weekly'
    ORDER BY obl.year_month DESC LIMIT 1;
    v_essentials_days := CASE WHEN COALESCE(v_cash_constrained, false) THEN 10 ELSE 21 END;
  END IF;

  v_override := CASE
    WHEN v_preset_essentials THEN v_essentials_days
    WHEN v_preset_catchup THEN 21
    ELSE p_days_cover_override
  END;
  v_fit_to_budget := COALESCE(p_fit_to_budget, false) OR v_preset_catchup;

  SELECT COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0) INTO v_weekly_dc_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key='DC' AND obl.grain='weekly'
  ORDER BY obl.year_month DESC LIMIT 1;
  v_weekly_dc_budget := COALESCE(v_weekly_dc_budget, 0);

  RETURN QUERY EXECUTE format($q$
    WITH route_beer_cfg AS (
      SELECT rc.merch_group_nrs, rc.excluded_supplier_types
      FROM bloom_route_config rc WHERE rc.store_code=%1$L AND rc.route_key='DIRECT_BEER'
    ),
    lnk AS (
      -- ITEM 2: route-aware supplier link. DC routes stay Z-supplier-link
      -- scoped exactly as before; DIRECT_BEER ports rpc_bloom_order_direct_
      -- beer's own lnk pattern verbatim (non-excluded active link types).
      SELECT DISTINCT ON (sl.product_code) sl.product_code,
        GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost
      FROM sigma_supplier_link sl
      LEFT JOIN sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr
      LEFT JOIN route_beer_cfg rbc ON true
      WHERE sl.store_code=%1$L AND COALESCE(sl.status,'')<>'S' AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sm.supplier_type='Z')
          OR (%15$L::text = 'DIRECT_BEER' AND sm.status='A' AND NOT (sm.supplier_type = ANY(rbc.excluded_supplier_types)))
        )
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%2$L::date),
    bt AS (SELECT DISTINCT product_code FROM l2_bt_heroes WHERE store_code=%1$L),
    pool AS MATERIALIZED (
      SELECT b.store_code, b.product_code,
        b.kvi_band, b.demand_source, b.rhythm_adjusted_demand, b.min_band, b.max_band,
        b.gmroi_quartile, b.gmroi_capped, b.band_blocked, b.band_blocked_reason,
        r.archetype,
        lnk.ps, lnk.pack_cost,
        sp.description, sp.dept_name, sp.tier, sp.department_nr, sp.merch_group_nr,
        COALESCE(so.soh,0) AS soh_raw,
        (bt.product_code IS NOT NULL) AS is_bt_hero
      FROM l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN l2_rhythm_profile r ON r.store_code=b.store_code AND r.product_code=b.product_code
      LEFT JOIN l2_stock_position sp ON sp.store_code=b.store_code AND sp.product_code=b.product_code
      LEFT JOIN soh so ON so.product_code=b.product_code
      LEFT JOIN bt ON bt.product_code=b.product_code
      WHERE b.store_code=%1$L
        -- ITEM 2: route-scoped pool. DC routes filter on the ambient dept
        -- cycle (bloom_dc_config); DIRECT_BEER filters on the beer merch
        -- groups (bloom_route_config) -- never both, never neither.
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(%16$L::smallint[]))
          OR (%15$L::text = 'DIRECT_BEER' AND sp.merch_group_nr IN (SELECT unnest(merch_group_nrs) FROM route_beer_cfg))
        )
        -- ITEM 4: band_blocked=false exclusion REMOVED (COUNT_FIRST
        -- reversion) -- band_blocked lines stay in the pool, handled below.
        AND (NOT %3$L::boolean
             OR b.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')
             OR bt.product_code IS NOT NULL
             OR sp.tier IN ('TOP_100','TOP_1000'))
    ),
    moded AS (
      SELECT p.*,
        CASE
          WHEN p.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'
          WHEN p.archetype = 'EARLY_MONTH' AND %4$s >= %7$s THEN 'build'
          ELSE 'minimum'
        END AS mode
      FROM pool p
    ),
    targeted AS (
      SELECT m.*,
        CASE
          WHEN %8$L IS NOT NULL AND %11$L::boolean THEN LEAST(m.rhythm_adjusted_demand * %8$L::numeric, m.max_band * %12$s)
          WHEN %8$L IS NOT NULL THEN m.rhythm_adjusted_demand * %8$L::numeric
          WHEN m.mode='build' THEN m.max_band
          ELSE m.min_band
        END AS target_level,
        CASE
          WHEN %8$L IS NOT NULL AND %11$L::boolean THEN 'catch-up: 21-day target, band-capped'
          WHEN %8$L IS NOT NULL THEN format('flat %%s-day cover override', %8$L::text)
          WHEN m.mode='build' THEN 'build: anticipatory, targets max_band ahead of the archetype peak'
          ELSE 'minimum: targets min_band (KVI-safety reorder point)'
        END AS mode_reason
      FROM moded m
    ),
    needc AS (
      SELECT t.*,
        -- ITEM 4: COUNT_FIRST reversion -- band_blocked lines project on a
        -- conservative (zero) SOH, never on the (untrusted) raw figure.
        (t.band_blocked AND t.soh_raw <> 0) AS count_first,
        CASE WHEN t.band_blocked THEN 0 ELSE t.soh_raw END AS soh_used,
        GREATEST(CASE WHEN t.band_blocked THEN 0 ELSE t.soh_raw END,0) - t.rhythm_adjusted_demand * %9$s AS proj,
        GREATEST(t.target_level - (GREATEST(CASE WHEN t.band_blocked THEN 0 ELSE t.soh_raw END,0) - t.rhythm_adjusted_demand * %9$s), 0) AS needu
      FROM targeted t
    ),
    packs AS (
      SELECT n.*,
        CASE WHEN n.rhythm_adjusted_demand<=0 THEN 0
             WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)
             ELSE 0 END::int AS normal_packs_calc
      FROM needc n
    ),
    -- ITEM 6: normal vs geared, ported verbatim from rpc_bloom_order_dc.
    promo_match AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.promo_nr, pa.start_date, pa.end_date, pa.status, pa.list_cost AS promo_unit_cost
      FROM packs pk JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
        AND pa.start_date < %18$L::date AND pa.end_date >= %2$L::date
      ORDER BY pk.product_code, (pa.status='1') DESC, pa.end_date DESC
    ),
    gear_source AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.start_date, pa.end_date
      FROM packs pk JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
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
      FROM packs pk LEFT JOIN gear_calc gc ON gc.product_code=pk.product_code
    ),
    geared_calc AS (
      SELECT wg.*,
        GREATEST(wg.soh_used,0) - (wg.rhythm_adjusted_demand*wg.gear) * %9$s AS proj_geared,
        GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.rhythm_adjusted_demand*wg.gear) * %9$s), 0) AS needu_geared
      FROM with_gear wg
    ),
    geared AS (
      SELECT g.*,
        CASE WHEN g.rhythm_adjusted_demand<=0 THEN 0
             WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1)
             ELSE 0 END::int AS geared_packs_calc
      FROM geared_calc g
    ),
    with_promo AS (
      SELECT g.*, pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end, pm.status AS promo_status, pm.promo_unit_cost
      FROM geared g LEFT JOIN promo_match pm ON pm.product_code=g.product_code
    ),
    resolved AS (
      SELECT wp.*,
        CASE WHEN wp.promo_nr IS NOT NULL THEN wp.geared_packs_calc ELSE wp.normal_packs_calc END AS resolved_packs_calc
      FROM with_promo wp
    ),
    gmroi AS (
      SELECT g.product_code, g.gmroi_rank FROM l2_gmroi_profile g WHERE g.store_code=%1$L
    ),
    ranked AS (
      SELECT r.*, gm.gmroi_rank,
        (r.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) AS is_protected
      FROM resolved r LEFT JOIN gmroi gm ON gm.product_code=r.product_code
    ),
    budgeted AS (
      SELECT r.*,
        SUM(CASE WHEN r.is_protected THEN r.resolved_packs_calc*r.pack_cost ELSE 0 END) OVER () AS protected_spend,
        -- COALESCE(...,0): the window frame has no preceding rows for the
        -- FIRST row in gmroi_rank order, so the bare SUM(...) OVER(...)
        -- returns NULL there -- which would otherwise propagate through
        -- every CASE comparison below and silently resolve via GREATEST's
        -- NULL-ignoring behavior, wrongly zero-capping the single BEST-
        -- ranked line on every fit-to-budget run.
        COALESCE(SUM(CASE WHEN NOT r.is_protected THEN r.resolved_packs_calc*r.pack_cost ELSE 0 END)
          OVER (ORDER BY r.gmroi_rank NULLS LAST, r.product_code
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS running_before
      FROM ranked r
    ),
    finalp AS (
      SELECT b.*,
        (%13$L::boolean) AS fit_applied,
        CASE
          WHEN NOT %13$L::boolean THEN b.resolved_packs_calc
          WHEN b.is_protected THEN b.resolved_packs_calc
          WHEN b.running_before >= (%14$L::numeric - b.protected_spend) THEN 0
          WHEN b.running_before + (b.resolved_packs_calc*b.pack_cost) <= (%14$L::numeric - b.protected_spend) THEN b.resolved_packs_calc
          ELSE GREATEST(FLOOR(((%14$L::numeric - b.protected_spend) - b.running_before)/NULLIF(b.pack_cost,0)),0)
        END::int AS final_packs,
        CASE
          WHEN NOT %13$L::boolean THEN NULL
          WHEN b.is_protected THEN 'protected_kvi'
          WHEN b.running_before >= (%14$L::numeric - b.protected_spend) THEN 'trimmed_to_zero'
          WHEN b.running_before + (b.resolved_packs_calc*b.pack_cost) <= (%14$L::numeric - b.protected_spend) THEN 'fits'
          ELSE 'trimmed_partial'
        END AS fit_reason
      FROM budgeted b
    )
    SELECT
      %1$L::text, pk.product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')),
      pk.description, pk.dept_name, %15$L::text,
      pk.kvi_band, pk.archetype, pk.mode, pk.mode_reason,
      pk.demand_source, ROUND(pk.rhythm_adjusted_demand,4),
      ROUND(pk.min_band,2), ROUND(pk.max_band,2), ROUND(pk.target_level,2),
      pk.soh_raw, %9$s::int, %17$L::text, ROUND(pk.proj,2),
      pk.count_first, pk.band_blocked_reason,
      ROUND(pk.needu,2), pk.ps, ROUND(pk.pack_cost,2),
      pk.normal_packs_calc, (pk.promo_nr IS NOT NULL), pk.promo_nr, pk.promo_start, pk.promo_end,
      ROUND(pk.gear,4), (CASE WHEN pk.gear_from_own_promo THEN 'own_promo' ELSE 'default' END), pk.geared_packs_calc,
      pk.resolved_packs_calc, pk.final_packs, ROUND((pk.final_packs*pk.pack_cost)::numeric,2),
      pk.gmroi_quartile, pk.gmroi_capped, pk.gmroi_rank,
      pk.fit_applied, pk.fit_reason,
      pk.tier, pk.is_bt_hero, %10$L::text, %3$L::boolean,
      format('%%s tier KVI=%%s, archetype=%%s -> %%s (%%s), band [%%s|%%s], SOH %%s, lead %%s(%%s) -> proj %%s, need %%s = %%s packs%%s%%s%%s',
        COALESCE(pk.tier,'-'), COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode, pk.mode_reason,
        ROUND(pk.min_band,1), ROUND(pk.max_band,1), pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.resolved_packs_calc,
        CASE WHEN pk.count_first THEN ' | COUNT_FIRST: band_blocked, SOH treated as 0' ELSE '' END,
        CASE WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,
        CASE WHEN pk.fit_applied THEN format(' | budget fit: %%s (%%s -> %%s packs)', pk.fit_reason, pk.resolved_packs_calc, pk.final_packs) ELSE '' END)
    FROM finalp pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
    ORDER BY pk.kvi_band NULLS LAST, pk.rhythm_adjusted_demand DESC, pk.product_code
  $q$, p_store_code, v_soh_dt, v_pool_filter_active, v_dom,
       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied,
       v_preset_catchup, p_catchup_band_cap_multiple, v_fit_to_budget, v_weekly_dc_budget,
       p_route, v_dept_nrs, v_lead_source, v_next_delivery);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
