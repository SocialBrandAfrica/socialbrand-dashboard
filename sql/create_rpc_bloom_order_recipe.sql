-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5. The profile-driven Recipe RPC: life gate, rhythm-
-- adjusted demand, stock band, order mode, KVI floor, GMROI fill, story per
-- row (R29). Reuses the pantry built in items 1-4 -- reuse before rewrite
-- (governing constraint 1). Tier is NOT a demand input (BLOOM-004 §3 item 5:
-- "l2_stock_band has no tier column... do not splice the retired §14 tiered-
-- window baseline into the recipe that replaces it") -- l2_stock_position.tier
-- is read here ONLY as a Preset A pool-filter signal, never to pick a ROS
-- window.
--
-- ORDER MODE (BLOOM-003 §2b.5, PM ruling 2026-07-11 confirming option 1 after
--   a CC confront -- BLOOM-004 §6's "modes replace the selector as the
--   primary control" line reads like a user dropdown; §2b.5's own text is
--   unambiguous once read closely: "mode is a property of the DROP, geared
--   per line by archetype." There is no global min/build/month-end selector.
--   Per line, per delivery date: EVERYDAY archetype never gears (always
--   targets min_band, "every drop fills to the steady band"). MONTH_END/
--   EARLY_MONTH archetype lines gear to 'build' (target max_band, anticipatory
--   cover ahead of a payday/pension peak the archetype itself already proved,
--   canon rhythm archetype) inside a day-of-month run-up window, else
--   'minimum' (target min_band, which is ALREADY rhythm-adjusted for the
--   current week via l2_stock_band's own week_index -- ordering during the
--   peak week itself is just keeping the already-elevated floor topped up,
--   not a separate anticipatory build).
--   Day-of-month windows are a literal translation of §2b.5's prose ("last 3
--   drops before the 25th" / "ease from 2 drops before the 8th" for
--   MONTH_END; "last 2 drops before month-start" / "ease after the 7th" for
--   EARLY_MONTH) using the twice-weekly (~3.5-day) drop-spacing assumption
--   already established as the interim lead-time lever (p_lead_days=3.5,
--   SB-CC-BLOOM-003 §2b.4). DEMO_CALIBRATION, config PARAMETERS with
--   defaults (same precedent as p_days_cover/p_lead_days/
--   p_gmroi_cap_review_factor) -- never hardcoded, superseded when a real
--   per-store delivery calendar lands:
--     MONTH_END build window: day-of-month in [15, 24] (~25 minus 3 drops).
--     EARLY_MONTH build window: day-of-month >= 25 (~last week, anticipating
--       next month's 1st-7th pension peak).
--   Manual override: p_days_cover_override (or Preset A's own flat 10-day
--   default) REPLACES the mode/band targeting entirely with a flat
--   rhythm_adjusted_demand x days-cover target -- BLOOM-004 §6: "days-cover
--   becomes the manual override."
--
-- KVI FLOOR: already enforced by construction -- 'minimum' mode targets
--   min_band exactly, and min_band already bakes in the KVI safety-days floor
--   (ENG-001 v2 / ENG-004). No separate clamp needed; kvi_band is surfaced
--   per row for the story (R29).
--
-- GMROI FILL: l2_stock_band.gmroi_quartile/gmroi_capped already reflect the
--   bottom-quartile review-days halving (ENG-001 v2). Surfaced, not
--   recomputed -- the SPEND-remaining-budget-by-GMROI-rank allocator is a
--   DIFFERENT mechanism (Fit to Budget, BLOOM-004 §3b item 8), explicitly
--   sequenced AFTER this item ("Fit to Budget adapts the order LAST").
--
-- EXPLICITLY OUT OF THIS BUILD PASS (not silently dropped -- named here):
--   - Promo gearing. Not one of the 8 named steps in BLOOM-004 §3 item 5;
--     rpc_bloom_order_dc's promo/gear CTEs are a separate, sizeable piece of
--     logic, left for a follow-on pass once this core lands and R22-verifies.
--   - 82%-of-forecast budget fit / Fit to Budget toggle (BLOOM-004 §3b items
--     7-8). Needs `order_budget_ledger` at WEEKLY grain -- the table only
--     carries monthly `year_month` today. Building a budget-fit here would be
--     guessing at an unbuilt dependency.
--   - Preset B ("Catch-up to the 21-day floor... fitted to the 82% week
--     budget", §5b). Structurally depends on the same unbuilt weekly budget
--     grain AND the GMROI-rank Fit-to-Budget allocator. Shipping a 21-day-
--     cover catch-up order on the KVI/priority pool with NO budget ceiling
--     is exactly the kind of unbounded-order risk the ceiling exists to
--     prevent -- stopped here rather than guessed. Preset A (order_essentials)
--     has no such dependency (a flat days-cover target, no budget fit) and
--     IS built in this pass.
--
-- SCOPE: DC-ambient de-facto (BLOOM-003 §6/§7: "fine-tuning focus moves to DC
--   ambient in the SPAR stores first") via the active Z-supplier-link
--   requirement -- same lnk pattern as rpc_bloom_order_dc, not a hardcoded
--   store/department restriction (R25: the engine is general, the caller
--   picks which store to call it for).
--
-- POOL: l2_stock_band directly (its own pool is sourced FROM l2_kvi_profile,
--   ENG-003, which is the FULL l2_stock_position class='NORMAL' population --
--   verified before this build that it carries NO ENG-008/ENG-009-class
--   scan-window population gate) WHERE band_blocked=false (a line whose
--   ledger won't reconcile routes to count, never to order -- canon, ENG-004
--   SOH-flow post-condition) INNER JOIN an active Z-supplier-link (existence
--   REAL + active order link, BLOOM-004 item 2's scope-gate criteria, already
--   satisfied by construction here).
--
-- Preset A (order_essentials, §5b, Pieter ruling 2026-07-11): flat 10-day
--   cover (bypasses band/mode targeting) + pool filter (KVI_CRITICAL/
--   KVI_IMPORTANT OR l2_bt_heroes OR tier TOP_100/TOP_1000). Frozen focus is
--   not yet an engine set (BLOOM-006 withdrawal note) -- `frozen_focus_pending`
--   flags this honestly per row when the preset is active, never blocks.
--   Store scope (10116+80175) is a CALLER choice, not baked into the RPC.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe(
  p_store_code text,
  p_delivery_date date,
  p_next_delivery date DEFAULT NULL::date,
  p_soh_date date DEFAULT NULL::date,
  p_preset text DEFAULT NULL::text,
  p_days_cover_override numeric DEFAULT NULL::numeric,
  p_month_end_build_start_day integer DEFAULT 15,
  p_month_end_build_end_day integer DEFAULT 24,
  p_early_month_build_start_day integer DEFAULT 25
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, dept_name text,
  kvi_band text, archetype text, mode text, mode_reason text,
  demand_source text, rhythm_adjusted_demand numeric,
  min_band numeric, max_band numeric, target_level numeric,
  soh numeric, lead_days_used integer, projected_soh numeric,
  need_units numeric, pack_size smallint, pack_cost numeric, suggested_packs integer, value numeric,
  gmroi_quartile integer, gmroi_capped boolean,
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
  v_preset_applied text;
BEGIN
  SET LOCAL statement_timeout = '30s';
  SELECT MAX(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_lead := GREATEST(p_delivery_date - v_anchor, 0);
  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;
  v_preset_essentials := COALESCE(p_preset = 'order_essentials', false);
  v_preset_applied := COALESCE(p_preset, 'standard');
  v_override := COALESCE(p_days_cover_override, CASE WHEN v_preset_essentials THEN 10 ELSE NULL END);

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
          WHEN %8$L IS NOT NULL THEN m.rhythm_adjusted_demand * %8$L::numeric
          WHEN m.mode='build' THEN m.max_band
          ELSE m.min_band
        END AS target_level,
        CASE
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
    )
    SELECT
      %1$L::text, pk.product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')),
      pk.description, pk.dept_name,
      pk.kvi_band, pk.archetype, pk.mode, pk.mode_reason,
      pk.demand_source, ROUND(pk.rhythm_adjusted_demand,4),
      ROUND(pk.min_band,2), ROUND(pk.max_band,2), ROUND(pk.target_level,2),
      pk.soh_raw, %9$s::int, ROUND(pk.proj,2),
      ROUND(pk.needu,2), pk.ps, ROUND(pk.pack_cost,2), pk.suggested_packs_calc, ROUND((pk.suggested_packs_calc*pk.pack_cost)::numeric,2),
      pk.gmroi_quartile, pk.gmroi_capped,
      pk.tier, pk.is_bt_hero, %10$L::text, %3$L::boolean,
      format('%%s tier KVI=%%s, archetype=%%s -> %%s (%%s), band [%%s|%%s], SOH %%s, lead %%s -> proj %%s, need %%s = %%s packs',
        COALESCE(pk.tier,'-'), COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode, pk.mode_reason,
        ROUND(pk.min_band,1), ROUND(pk.max_band,1), pk.soh_raw, %9$s, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.suggested_packs_calc)
    FROM packs pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
    ORDER BY pk.kvi_band NULLS LAST, pk.rhythm_adjusted_demand DESC, pk.product_code
  $q$, p_store_code, v_soh_dt, v_preset_essentials, v_dom,
       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,integer,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,integer,integer,integer) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
