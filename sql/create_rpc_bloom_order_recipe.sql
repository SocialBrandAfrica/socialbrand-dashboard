-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5 (+ items 7/8, §3b, folded in 2026-07-11 per PM
-- ruling: "keep it, continue to the Recipe screen, fold in the presets +
-- budget wiring"). The profile-driven Recipe RPC: life gate, rhythm-adjusted
-- demand, stock band, order mode, KVI floor, GMROI fill, 82%-budget fit,
-- story per row (R29). Reuses the pantry built in items 1-4 -- reuse before
-- rewrite (governing constraint 1). Tier is NOT a demand input (BLOOM-004 §3
-- item 5) -- l2_stock_position.tier is read here ONLY as a preset pool-filter
-- signal, never to pick a ROS window.
--
-- ORDER MODE (BLOOM-003 §2b.5, PM ruling 2026-07-11 confirming option 1 after
--   a CC confront -- BLOOM-004 §6's "modes replace the selector as the
--   primary control" line reads like a user dropdown; §2b.5's own text is
--   unambiguous once read closely: "mode is a property of the DROP, geared
--   per line by archetype." There is no global min/build/month-end selector.
--   Per line, per delivery date: EVERYDAY archetype never gears (always
--   targets min_band). MONTH_END/EARLY_MONTH archetype lines gear to 'build'
--   (target max_band, anticipatory cover ahead of the archetype's own proven
--   peak) inside a day-of-month run-up window, else 'minimum' (target
--   min_band, already rhythm-adjusted for the current week).
--   Day-of-month windows are a literal translation of §2b.5's prose, DEMO_
--   CALIBRATION config parameters (same precedent as p_days_cover/
--   p_lead_days): MONTH_END build = day-of-month [15,24]; EARLY_MONTH build
--   = day-of-month >= 25.
--   Manual override: p_days_cover_override (or a preset's own flat target)
--   REPLACES the mode/band targeting entirely -- BLOOM-004 §6: "days-cover
--   becomes the manual override."
--
-- KVI FLOOR: enforced by construction (minimum mode targets min_band exactly,
--   which already bakes in the KVI safety-days floor, ENG-001 v2/ENG-004) AND
--   by the budget-fit allocator below (KVI_CRITICAL/IMPORTANT lines are NEVER
--   trimmed, protected first).
--
-- GMROI FILL: two mechanisms. (1) l2_stock_band.gmroi_quartile/gmroi_capped
--   already reflect the bottom-quartile review-days halving (ENG-001 v2),
--   surfaced not recomputed. (2) NEW this pass: the Fit-to-Budget allocator
--   spends the remaining (non-KVI-protected) weekly budget in GMROI-rank
--   order, best return first, per §3b's own definition of the mechanism.
--
-- FIT TO BUDGET (BLOOM-004 §3b item 8, folded in 2026-07-11 -- now unblocked
--   by the weekly order_budget_ledger grain built the same session, item 7):
--   p_fit_to_budget boolean, off by default (recipe proposes full projected
--   need unless asked to trim). When on: (1) every KVI_CRITICAL/KVI_IMPORTANT
--   line's computed packs are NEVER trimmed -- summed first as protected
--   spend; (2) the remaining weekly DC budget (order_budget_ledger,
--   route_key='DC', grain='weekly', most recent week, less committed_amount)
--   is spent down GMROI rank (l2_gmroi_profile.gmroi_rank, best return
--   first) via a running-cumulative window function -- a line fits fully,
--   trims to whatever whole packs remain in headroom, or trims to zero, in
--   that order down the rank. `budget_fit_reason` names which per row (R29):
--   protected_kvi / fits / trimmed_partial / trimmed_to_zero.
--   `packs_before_fit` keeps the pre-trim figure for audit (nothing silently
--   disappears -- the pre-fit demand is always visible).
--   `route_key='DC'` because this recipe's own pool is Z-supplier-link-scoped
--   (DC-ambient), matching the weekly ledger's own DC/DIRECT split.
--
-- PRESETS (§5b, Pieter ruling 2026-07-11):
--   Preset A (order_essentials): flat 10-day cover override (bypasses band/
--     mode targeting) + pool filter (KVI_CRITICAL/IMPORTANT OR l2_bt_heroes
--     OR tier TOP_100/TOP_1000). No budget fit unless the caller separately
--     asks for p_fit_to_budget.
--   Preset B (catch_up): flat 21-day cover target, SAME pool filter as
--     Preset A (KVI/BT/tier -- §5b's "priority set" language, frozen focus
--     and promos not yet engine sets, same honest-not-blocking pattern as
--     Preset A), band-capped at `p_catchup_band_cap_multiple` (default 3.0)
--     x max_band so a single catch-up run can never propose an absurd
--     multiple of the line's own healthy range, and Fit-to-Budget is FORCED
--     ON regardless of the p_fit_to_budget argument -- §5b: "fitted to the
--     82% week budget" is part of Preset B's own definition, not optional.
--   Frozen focus is not yet an engine set (BLOOM-006 withdrawal note) --
--     `frozen_focus_pending` flags this honestly per row when either preset
--     is active, never blocks. Store scope is a CALLER choice (R25), not
--     baked into the RPC.
--
-- EXPLICITLY STILL OUT OF THIS BUILD PASS (not silently dropped -- named):
--   - Promo gearing. Not one of the 8 named steps in BLOOM-004 §3 item 5.
--   - "Deduct Last Order" (§3b). Needs `order_items` (line-item history of
--     submitted orders) -- table does not exist yet; `orders` itself is an
--     empty shell (no submission RPC writes to it, PARITY WP1, item 3
--     scope). Cannot subtract a real last order that isn't captured anywhere.
--   - The order-summary aggregate cards/breakdowns (§3b) -- a separate,
--     thin companion RPC (`rpc_bloom_order_summary`) that aggregates THIS
--     function's own output, same split as Forge's summary/lines pair.
--
-- SCOPE: DC-ambient de-facto (BLOOM-003 §6/§7) via the active Z-supplier-
--   link requirement -- same lnk pattern as rpc_bloom_order_dc, not a
--   hardcoded store/department restriction (R25).
--
-- POOL: l2_stock_band directly (sourced FROM l2_kvi_profile, ENG-003 --
--   verified clean of any ENG-008/ENG-009-class population gate) WHERE
--   band_blocked=false (routes to count, never orders -- ENG-004 SOH-flow)
--   INNER JOIN an active Z-supplier-link (existence REAL + active order
--   link, BLOOM-004 item 2's scope-gate criteria).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,integer,integer,integer);

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
  p_catchup_band_cap_multiple numeric DEFAULT 3.0
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, dept_name text,
  kvi_band text, archetype text, mode text, mode_reason text,
  demand_source text, rhythm_adjusted_demand numeric,
  min_band numeric, max_band numeric, target_level numeric,
  soh numeric, lead_days_used integer, projected_soh numeric,
  need_units numeric, pack_size smallint, pack_cost numeric,
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
  v_anchor date; v_soh_dt date; v_lead int; v_dom int;
  v_override numeric;
  v_preset_essentials boolean;
  v_preset_catchup boolean;
  v_pool_filter_active boolean;
  v_preset_applied text;
  v_fit_to_budget boolean;
  v_weekly_dc_budget numeric;
BEGIN
  SET LOCAL statement_timeout = '30s';
  SELECT MAX(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_lead := GREATEST(p_delivery_date - v_anchor, 0);
  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;
  v_preset_essentials := COALESCE(p_preset = 'order_essentials', false);
  v_preset_catchup := COALESCE(p_preset = 'catch_up', false);
  v_pool_filter_active := v_preset_essentials OR v_preset_catchup;
  v_preset_applied := COALESCE(p_preset, 'standard');
  v_override := CASE
    WHEN v_preset_essentials THEN 10
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
    WITH lnk AS (
      SELECT DISTINCT ON (sl.product_code) sl.product_code,
        GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost
      FROM sigma_supplier_link sl
      JOIN sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr AND sm.supplier_type='Z'
      WHERE sl.store_code=%1$L AND COALESCE(sl.status,'')<>'S' AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%2$L::date),
    bt AS (SELECT DISTINCT product_code FROM l2_bt_heroes WHERE store_code=%1$L),
    pool AS MATERIALIZED (
      SELECT b.store_code, b.product_code,
        b.kvi_band, b.demand_source, b.rhythm_adjusted_demand, b.min_band, b.max_band,
        b.gmroi_quartile, b.gmroi_capped,
        r.archetype,
        lnk.ps, lnk.pack_cost,
        sp.description, sp.dept_name, sp.tier,
        COALESCE(so.soh,0) AS soh_raw,
        (bt.product_code IS NOT NULL) AS is_bt_hero
      FROM l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN l2_rhythm_profile r ON r.store_code=b.store_code AND r.product_code=b.product_code
      LEFT JOIN l2_stock_position sp ON sp.store_code=b.store_code AND sp.product_code=b.product_code
      LEFT JOIN soh so ON so.product_code=b.product_code
      LEFT JOIN bt ON bt.product_code=b.product_code
      WHERE b.store_code=%1$L AND b.band_blocked=false
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
        GREATEST(t.soh_raw,0) - t.rhythm_adjusted_demand * %9$s AS proj,
        GREATEST(t.target_level - (GREATEST(t.soh_raw,0) - t.rhythm_adjusted_demand * %9$s), 0) AS needu
      FROM targeted t
    ),
    packs AS (
      SELECT n.*,
        CASE WHEN n.rhythm_adjusted_demand<=0 THEN 0
             WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)
             ELSE 0 END::int AS suggested_packs_calc
      FROM needc n
    ),
    gmroi AS (
      SELECT g.product_code, g.gmroi_rank FROM l2_gmroi_profile g WHERE g.store_code=%1$L
    ),
    ranked AS (
      SELECT pk.*, gm.gmroi_rank,
        (pk.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) AS is_protected
      FROM packs pk LEFT JOIN gmroi gm ON gm.product_code=pk.product_code
    ),
    budgeted AS (
      SELECT r.*,
        SUM(CASE WHEN r.is_protected THEN r.suggested_packs_calc*r.pack_cost ELSE 0 END) OVER () AS protected_spend,
        -- COALESCE(...,0): the window frame has no preceding rows for the
        -- FIRST row in gmroi_rank order, so the bare SUM(...) OVER(...)
        -- returns NULL there -- which would otherwise propagate through
        -- every CASE comparison below and silently resolve via GREATEST's
        -- NULL-ignoring behavior (the same footgun already caught once this
        -- session in l2_bloom_ros_pantry's window_stockout), wrongly
        -- zero-capping the single BEST-ranked line on every fit-to-budget run.
        COALESCE(SUM(CASE WHEN NOT r.is_protected THEN r.suggested_packs_calc*r.pack_cost ELSE 0 END)
          OVER (ORDER BY r.gmroi_rank NULLS LAST, r.product_code
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS running_before
      FROM ranked r
    ),
    finalp AS (
      SELECT b.*,
        (%13$L::boolean) AS fit_applied,
        CASE
          WHEN NOT %13$L::boolean THEN b.suggested_packs_calc
          WHEN b.is_protected THEN b.suggested_packs_calc
          WHEN b.running_before >= (%14$L::numeric - b.protected_spend) THEN 0
          WHEN b.running_before + (b.suggested_packs_calc*b.pack_cost) <= (%14$L::numeric - b.protected_spend) THEN b.suggested_packs_calc
          ELSE GREATEST(FLOOR(((%14$L::numeric - b.protected_spend) - b.running_before)/NULLIF(b.pack_cost,0)),0)
        END::int AS final_packs,
        CASE
          WHEN NOT %13$L::boolean THEN NULL
          WHEN b.is_protected THEN 'protected_kvi'
          WHEN b.running_before >= (%14$L::numeric - b.protected_spend) THEN 'trimmed_to_zero'
          WHEN b.running_before + (b.suggested_packs_calc*b.pack_cost) <= (%14$L::numeric - b.protected_spend) THEN 'fits'
          ELSE 'trimmed_partial'
        END AS fit_reason
      FROM budgeted b
    )
    SELECT
      %1$L::text, pk.product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')),
      pk.description, pk.dept_name,
      pk.kvi_band, pk.archetype, pk.mode, pk.mode_reason,
      pk.demand_source, ROUND(pk.rhythm_adjusted_demand,4),
      ROUND(pk.min_band,2), ROUND(pk.max_band,2), ROUND(pk.target_level,2),
      pk.soh_raw, %9$s::int, ROUND(pk.proj,2),
      ROUND(pk.needu,2), pk.ps, ROUND(pk.pack_cost,2),
      pk.suggested_packs_calc, pk.final_packs, ROUND((pk.final_packs*pk.pack_cost)::numeric,2),
      pk.gmroi_quartile, pk.gmroi_capped, pk.gmroi_rank,
      pk.fit_applied, pk.fit_reason,
      pk.tier, pk.is_bt_hero, %10$L::text, %3$L::boolean,
      format('%%s tier KVI=%%s, archetype=%%s -> %%s (%%s), band [%%s|%%s], SOH %%s, lead %%s -> proj %%s, need %%s = %%s packs%%s',
        COALESCE(pk.tier,'-'), COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode, pk.mode_reason,
        ROUND(pk.min_band,1), ROUND(pk.max_band,1), pk.soh_raw, %9$s, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.suggested_packs_calc,
        CASE WHEN pk.fit_applied THEN format(' | budget fit: %%s (%%s -> %%s packs)', pk.fit_reason, pk.suggested_packs_calc, pk.final_packs) ELSE '' END)
    FROM finalp pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
    ORDER BY pk.kvi_band NULLS LAST, pk.rhythm_adjusted_demand DESC, pk.product_code
  $q$, p_store_code, v_soh_dt, v_pool_filter_active, v_dom,
       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied,
       v_preset_catchup, p_catchup_band_cap_multiple, v_fit_to_budget, v_weekly_dc_budget);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
