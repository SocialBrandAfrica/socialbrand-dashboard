-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5 -- the profile-driven Recipe RPC.
--
-- =========================== BLOOM-007 MONDAY-LIST REWRITE (2026-07-11) =====
-- PM's order-audit walk found six more defects after the first BLOOM-007
-- pass landed. BUG-LOG ENG-012/013/014/015/016 + CLEANUP-ENGINE-CANON SS14
-- ADDENDUM v7 item 4's corrected wording (item 4 "FOCUS AFTER GENERATION",
-- superseded same evening). No new formulas -- every fix below reuses an
-- ALREADY-PROVEN pattern from rpc_bloom_order_direct_beer (ENG-009) or
-- l2_stock_band's own refresh function, applied where it was missing.
--
-- ENG-012 -- ORDER-TIME BAND RECOMPUTE. l2_stock_band's min_band/max_band
--   are nightly facts built on FIXED lead=3.5/review=7 (uniform, every
--   line, every store). BLOOM-007's first pass fed the calendar-derived
--   drop cover into the SOH projection (lead_days_used) but left min_band/
--   max_band on the stale nightly figures -- milk 10116/1674 kept ordering
--   off a 7.5d/14.5d band on an actual 2-day drop, ~15% over. Fixed: the
--   recipe now recomputes min_band/max_band AT ORDER TIME using v_lead
--   (the calendar drop cover, or the anchor-gap fallback) as BOTH the lead
--   and the review period -- "the drop window as the review period" per
--   canon v7 item 2. Same formula l2_stock_band already uses
--   (min = demand*lead + safety_days*demand; max = min + demand*review,
--   gmroi-capped lines get review*0.5), just re-derived with the real
--   per-order lead instead of the nightly constant. l2_stock_band itself
--   is UNTOUCHED (still the standing nightly fact, still feeds Capital
--   Tied/KPIs) -- only this RPC's own order-time working figures change.
--
-- ENG-013 -- SAB DESK ROUTES THROUGH THE RECIPE, ROUTE BUDGET CORRECT.
--   The DIRECT_BEER route already worked structurally (BLOOM-007 item 2)
--   but read the DC weekly budget row for its Fit-to-Budget ceiling --
--   wrong route's money. Fixed: the ledger route key is now
--   `p_route IN ('DC_AMBIENT','DC_TOPS') -> 'DC'`, `'DIRECT_BEER' ->
--   'DIRECT_BEER'` (a real, separate route in order_budget_ledger since
--   Ship 1). rpc_bloom_order_direct_beer retires with lineage (see its own
--   file) -- the recipe is now the only order path for every desk.
--
-- ENG-014 -- COUNT_FIRST SPLITS BY CLAIM SIGN. The first pass zeroed SOH
--   for EVERY band_blocked line regardless of sign, over-buying positive
--   claims that were never proven wrong (KOO BEANS 137585, LION MATCHES
--   5847 -- both claim real positive stock, canon only mandates zero-SOH
--   for the NEGATIVE-claim case, S14 SS9 DF-5 selling-negative). Fixed:
--   soh_used = (band_blocked AND soh_raw < 0) ? 0 : soh_raw. count_first
--   still flags every band_blocked line regardless of sign (the count
--   list rides the response either way) -- only the QUANTITY math changes.
--
-- ENG-015 -- DEMAND WINDOW RESOLVES PER TIER, the ENG-005 precedent ported
--   VERBATIM from rpc_bloom_order_dc (NOT rpc_bloom_order_direct_beer's
--   capped/guarded ENG-009 pattern -- an earlier draft of this fix used
--   that one and it suppressed milk's real family-draw magnitude down to
--   2x its own near-zero scan rate, caught in R22 verification before
--   commit and corrected): T100 = ros_14d (28d fallback when q14=0),
--   T1000 = ros_28d, BOR = ros_56d. ros_final = GREATEST(scan_raw,
--   draw_corrected) -- scan is UNCAPPED, UNGUARDED (matches DC exactly);
--   draw only enters the GREATEST when the line clears the SAME
--   eligibility gate l2_stock_band already uses (KVI-floor bands trust it
--   by construction, everything else needs >=8 selling days/182d off the
--   pantry's own p_sell_estimate) -- this eligibility GATE, not a
--   magnitude cap, is the ENG-015 "story test" that keeps a consumable-
--   class line like LION MATCHES 5847 off an untrustworthy draw signal
--   while leaving milk's genuine family-draw magnitude untouched. This
--   value (`ros_final`) REPLACES l2_stock_band's flat 56d-only
--   `rhythm_adjusted_demand` as the demand rate driving both the order-
--   time band recompute (ENG-012) and the need/pack calc. The promo gear
--   multiplier was always correct in isolation -- once its base demand is
--   the real tier-resolved rate, the geared quantity regains the DC form's
--   own magnitude.
--
-- ENG-016 -- BUDGET-WEEK ATTRIBUTION. order_budget_ledger.year_month IS
--   the week-commencing Saturday (WC-11-Jul = 2026-07-11, itself a
--   Saturday) -- the DC payment cycle's own boundary (canon v7 item 7).
--   The recipe now computes the Saturday on-or-before p_delivery_date and
--   looks up that EXACT week's ledger row (falls back to the most recent
--   PAST week, never a future one, when the exact week isn't seeded yet --
--   flagged in the story) for both the essentials cash-basis gate and the
--   Fit-to-Budget ceiling. An order consumes the budget of its DELIVERY
--   week, never the week it was placed -- was reading "most recent seeded
--   week" regardless of delivery date.
--
-- Presets (order_essentials/catch_up) already filter the POOL itself to
-- the focus set (KVI/BT/tier) -- this was already correct in the first
-- BLOOM-007 pass and needed no change: three presets already return three
-- different line sets. What changed is the DESK SCREEN's own handling of
-- a preset call (replace the order, never merge) -- see page.jsx.
-- =============================================================================
--
-- =========================== ENG-017 / CANON v7 ITEMS 9-11 (2026-07-11 night)
-- ENG-017 -- THE PROMO BUY-IN WINDOW governs promo ORDERING eligibility
--   (canon v7 item 10), replacing the old loose "active between today and
--   next delivery" overlap test. D3 resolved FIRST, live, before this was
--   built (never assumed): reconciled RG2 on 17471 @10116
--   (sigma_promotions start_date=2026-07-08) against its ledger -- GRV
--   receipts land 2026-06-27 and 2026-07-02, both BEFORE start_date, and
--   the 07-11 BENCHMARK extract independently shows 17471 with
--   Current Promo=RG2 while inside [07-08,07-22] -- StockFlow's own
--   "current" read sits INSIDE the sigma_promotions window, confirming
--   start_date/end_date ARE the shelf/sell-active dates, not a DC
--   order-window passthrough. The buy-in-window FORMULA applies: a
--   promo's geared/promo-sheet eligibility for a given delivery date runs
--   from (active_start - promo_buyin_lead_days) through the LAST
--   supplier_calendar delivery on or before active_end -- outside that
--   window the line orders NORMAL even if the promo is still shelf-active.
--   promo_buyin_lead_days lives on supplier_calendar (DEMO_CALIBRATION,
--   default 7, see create_supplier_calendar_promo_buyin.sql).
--
-- Promo naming (UX-003, ENG-017 sibling): every promo surfaces its DC
--   suffix code (RG1/RG2/PF1...) parsed from sigma_promotions.description
--   ("DC Promotion Number <CODE> - ... (<CODE>)"), read off the trailing
--   parenthetical first (most reliable anchor), falling back to the
--   "Number <CODE>" token. A promo row that resolves neither is a NAMING
--   GAP -- surfaced (promo_naming_gap=true), never guessed; the caller
--   falls back to promo_nr for display.
--
-- Canon v7 item 9 -- BAND INVARIANTS asserted POPULATION-LEVEL on every
--   generate (no ordered target may exceed its order-time max, no
--   triggered line may target below its min). Flag, never block: the
--   dynamic result materializes into a session-temp table so a single
--   cheap aggregate can RAISE WARNING with the violation count before the
--   rows return -- this is a diagnostic signal for the landing sanity
--   strip's DEFECT SIGNAL, not a gate on the order itself.
-- =============================================================================
--
-- ITEM 2 -- ROUTE SCOPE (BLOOM-007, unchanged this pass). p_route REQUIRED
--   (DC_AMBIENT/DC_TOPS/DIRECT_BEER), validated against the store's own
--   bloom_dc_config.format_group. DC routes filter the pool on
--   bloom_dc_config.dc_cycle_dept_nrs; DIRECT_BEER filters on
--   bloom_route_config.merch_group_nrs, lnk pattern ported from
--   rpc_bloom_order_direct_beer.
--
-- ITEM 3 -- DROP COVER (BLOOM-007, unchanged this pass). v_lead reads
--   GREATEST(p_next_delivery - p_delivery_date, 0) when supplied, else
--   the anchor-gap fallback. lead_days_source names which per row (R29).
--
-- ITEM 6 -- NORMAL VS GEARED (BLOOM-007, unchanged this pass, now correct
--   per ENG-015). Ported from rpc_bloom_order_dc's promo_match/gear_calc.
--
-- KVI FLOOR: enforced by construction (minimum mode targets min_band) AND
--   by the budget-fit allocator (KVI_CRITICAL/IMPORTANT never trimmed).
--
-- FIT TO BUDGET: p_fit_to_budget boolean, off by default. KVI_CRITICAL/
--   IMPORTANT lines never trimmed (protected spend, summed first); the
--   remaining weekly budget (route-correct per ENG-013, week-correct per
--   ENG-016) is spent down GMROI rank. budget_fit_reason per row:
--   protected_kvi / fits / trimmed_partial / trimmed_to_zero.
--
-- PRESETS: order_essentials = 21-day cover (10-day when the delivery
--   week's ledger row is cash_constrained, canon v7 item 3) + pool filter
--   (KVI_CRITICAL/IMPORTANT OR l2_bt_heroes OR tier IN TOP_100/TOP_1000).
--   catch_up = flat 21-day target, same pool filter, band-capped at
--   p_catchup_band_cap_multiple x max_band, Fit-to-Budget FORCED ON.
-- =============================================================================

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
  p_catchup_band_cap_multiple numeric DEFAULT 3.0,
  p_route text DEFAULT NULL::text
)
RETURNS TABLE(
  store_code text, product_code bigint, ean text, description text, dept_name text,
  route text, kvi_band text, archetype text, tier text, mode text, mode_reason text,
  demand_source text, ros_window_used text, rhythm_adjusted_demand numeric,
  min_band numeric, max_band numeric, target_level numeric,
  soh numeric, lead_days_used integer, lead_days_source text, projected_soh numeric,
  count_first boolean, band_blocked_reason text,
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
  v_pool_filter_active boolean;
  v_preset_applied text;
  v_fit_to_budget boolean;
  v_weekly_budget numeric;
  v_next_delivery date;
  v_format_group text;
  v_dept_nrs smallint[];
  v_cash_constrained boolean;
  v_essentials_days numeric;
  v_ledger_route text;
  v_week_start date;
  v_week_source text;
  v_dows smallint[];
  v_buyin_lead_days int;
  v_band_violations int;
  v_sql text;
BEGIN
  SET LOCAL statement_timeout = '30s';

  -- BUG-LOG ENG-019: format()'s %s renders a NULL argument as an empty
  -- string, not an error at format()-time -- a caller passing any of
  -- these three explicitly as NULL (rather than omitting them, which
  -- takes the declared DEFAULT) silently produced "BETWEEN  AND 24"
  -- (missing left operand) in the moded CTE, a syntax error only at
  -- EXECUTE time. Latent (never triggered by this repo's own callers,
  -- which always pass the three explicitly), guarded here regardless.
  p_month_end_build_start_day := COALESCE(p_month_end_build_start_day, 15);
  p_month_end_build_end_day := COALESCE(p_month_end_build_end_day, 24);
  p_early_month_build_start_day := COALESCE(p_early_month_build_start_day, 25);

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

  -- ENG-013: ledger route key. DC_AMBIENT/DC_TOPS share the DC weekly
  -- budget; DIRECT_BEER reads its own separate route budget (live in
  -- order_budget_ledger since Ship 1) -- never DC's money for SAB.
  v_ledger_route := CASE WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER' ELSE 'DC' END;

  -- ENG-017: buy-in window inputs. v_dows feeds the "last calendar
  -- delivery <= active_end" closing bound; a missing calendar row
  -- degrades gracefully to every-day (no calendar constraint, config
  -- default lead) rather than raising -- supplier_calendar is fully
  -- seeded for all 7 live store/route pairs, this is a defensive
  -- fallback only, never expected live.
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

  -- ENG-016: the budget week is the Saturday on-or-before the DELIVERY
  -- date (canon v7 item 7, DC payment cycle boundary) -- an order
  -- consumes the budget of its delivery week, never the week it was
  -- placed. ISODOW: Mon=1..Sun=7, Saturday=6.
  v_week_start := p_delivery_date - ((EXTRACT(ISODOW FROM p_delivery_date)::int + 1) % 7);

  SELECT obl.year_month INTO v_week_start
  FROM order_budget_ledger obl
  WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
    AND obl.year_month = v_week_start
  LIMIT 1;

  IF v_week_start IS NOT NULL THEN
    v_week_source := 'delivery_week_exact';
  ELSE
    -- fallback: the exact delivery week isn't seeded yet -- use the most
    -- recent PAST week rather than silently picking a future one.
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
  v_pool_filter_active := v_preset_essentials OR v_preset_catchup;
  v_preset_applied := COALESCE(p_preset, 'standard');

  IF v_preset_essentials THEN
    SELECT COALESCE(obl.cash_constrained, false) INTO v_cash_constrained
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
      AND obl.year_month = v_week_start;
    v_essentials_days := CASE WHEN COALESCE(v_cash_constrained, false) THEN 10 ELSE 21 END;
  END IF;

  v_override := CASE
    WHEN v_preset_essentials THEN v_essentials_days
    WHEN v_preset_catchup THEN 21
    ELSE p_days_cover_override
  END;
  v_fit_to_budget := COALESCE(p_fit_to_budget, false) OR v_preset_catchup;

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
        )
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%2$L::date),
    bt AS (SELECT DISTINCT product_code FROM l2_bt_heroes WHERE store_code=%1$L),
    -- ENG-015: raw per-window scan units, the ENG-005 precedent's own base.
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
    pool AS MATERIALIZED (
      SELECT b.store_code, b.product_code,
        b.kvi_band, b.gmroi_quartile, b.gmroi_capped, b.band_blocked, b.band_blocked_reason,
        r.archetype,
        lnk.ps, lnk.pack_cost,
        sp.description, sp.dept_name, sp.tier, sp.department_nr, sp.merch_group_nr,
        COALESCE(so.soh,0) AS soh_raw,
        (bt.product_code IS NOT NULL) AS is_bt_hero,
        COALESCE(sa.q14,0) AS q14, COALESCE(sa.q28,0) AS q28, COALESCE(sa.q56,0) AS q56,
        rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected,
        rop.ros_draw_14d_corrected, rop.ros_draw_28d_corrected, rop.ros_draw_56d_corrected,
        rop.p_sell_estimate AS p_sell_scan, rop.p_sell_estimate_draw AS p_sell_draw,
        COALESCE(rop.unit_incommensurable, true) AS unit_incommensurable
      FROM l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN l2_rhythm_profile r ON r.store_code=b.store_code AND r.product_code=b.product_code
      LEFT JOIN l2_stock_position sp ON sp.store_code=b.store_code AND sp.product_code=b.product_code
      LEFT JOIN soh so ON so.product_code=b.product_code
      LEFT JOIN bt ON bt.product_code=b.product_code
      LEFT JOIN sales sa ON sa.product_code=b.product_code
      LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code=b.store_code AND rop.product_code=b.product_code
      WHERE b.store_code=%1$L
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(%16$L::smallint[]))
          OR (%15$L::text = 'DIRECT_BEER' AND sp.merch_group_nr IN (SELECT unnest(merch_group_nrs) FROM route_beer_cfg))
        )
        AND (NOT %3$L::boolean
             OR b.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')
             OR bt.product_code IS NOT NULL
             OR sp.tier IN ('TOP_100','TOP_1000'))
    ),
    -- ENG-015: per-tier window selection (T100 14d/28d-fallback, T1000
    -- 28d, BOR 56d), ros_final = GREATEST(scan_raw, draw_corrected) -- the
    -- ENG-005 precedent ported VERBATIM from rpc_bloom_order_dc (not the
    -- capped/guarded rpc_bloom_order_direct_beer pattern, an earlier draft
    -- of this fix wrongly used that one and it suppressed milk's real
    -- family-draw magnitude down to 2x its own near-zero scan rate --
    -- caught in R22 verification, corrected). scan is UNCAPPED, UNGUARDED
    -- (matches DC exactly). draw is the ENG-015 "story test": it only
    -- participates in the GREATEST when the line clears the SAME
    -- eligibility gate l2_stock_band already uses (KVI-floor bands
    -- trust it by construction, everything else needs >=8 selling
    -- days/182d off the pantry's own p_sell_estimate) -- "scan governs
    -- where the story fails" is this gate, not a magnitude cap.
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
    -- ENG-012: order-time band recompute. v_lead (calendar drop cover, or
    -- the anchor-gap fallback) is used as BOTH the lead and the review
    -- period -- same additive formula l2_stock_band's own refresh
    -- function uses (min = demand*lead + safety*demand; max = min +
    -- demand*review, gmroi-capped lines get review*0.5) -- re-derived
    -- with the real per-order lead, never the nightly 3.5/7 constant.
    banded AS (
      SELECT m.*,
        (m.ros_final * %9$s) + (m.safety_days * m.ros_final) AS min_band_ot,
        (CASE WHEN m.gmroi_capped THEN %9$s * 0.5 ELSE %9$s END) AS review_days_ot
      FROM moded m
    ),
    targeted AS (
      SELECT b.*,
        (b.min_band_ot + (b.ros_final * b.review_days_ot)) AS max_band_ot,
        CASE
          WHEN %8$L IS NOT NULL AND %11$L::boolean THEN LEAST(b.ros_final * %8$L::numeric, (b.min_band_ot + (b.ros_final * b.review_days_ot)) * %12$s)
          WHEN %8$L IS NOT NULL THEN b.ros_final * %8$L::numeric
          WHEN b.mode='build' THEN (b.min_band_ot + (b.ros_final * b.review_days_ot))
          ELSE b.min_band_ot
        END AS target_level,
        CASE
          WHEN %8$L IS NOT NULL AND %11$L::boolean THEN 'catch-up: 21-day target, band-capped'
          WHEN %8$L IS NOT NULL THEN format('flat %%s-day cover override', %8$L::text)
          WHEN b.mode='build' THEN 'build: anticipatory, targets max_band ahead of the archetype peak'
          ELSE 'minimum: targets min_band (order-time, calendar lead+review)'
        END AS mode_reason
      FROM banded b
    ),
    needc AS (
      SELECT t.*,
        -- ENG-014: COUNT_FIRST splits by claim sign. A NEGATIVE claim is
        -- an impossible value -- zero it (canon's existing selling-
        -- negative rule). A POSITIVE claim is not disproven by
        -- band_blocked alone -- order on it, never a forced buy; the
        -- count still rides to settle it next drop.
        t.band_blocked AS count_first,
        (CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END) AS soh_used,
        GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s AS proj,
        GREATEST(t.target_level - (GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s), 0) AS needu
      FROM targeted t
    ),
    packs AS (
      SELECT n.*,
        CASE WHEN n.ros_final<=0 THEN 0
             WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)
             ELSE 0 END::int AS normal_packs_calc
      FROM needc n
    ),
    -- ENG-017: buy-in window eligibility, anchored on THIS order's
    -- delivery date (%23), not today. Eligible when the delivery falls
    -- on/after (active_start - buyin_lead_days) AND on/before the last
    -- calendar delivery on/before active_end -- outside that, the promo
    -- is not a candidate for THIS order at all (falls through to normal).
    promo_match AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.promo_nr, pa.start_date, pa.end_date, pa.status,
        pa.list_cost AS promo_unit_cost, sp2.description AS promo_description
      FROM packs pk
      JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
      LEFT JOIN public.sigma_promotions sp2 ON sp2.store_code=%1$L AND sp2.promo_nr=pa.promo_nr
      WHERE %23$L::date >= (pa.start_date - %22$L::int)
        AND %23$L::date <= (
          SELECT MAX(gs) FROM generate_series(pa.end_date - 6, pa.end_date, interval '1 day') gs
          WHERE EXTRACT(ISODOW FROM gs)::smallint = ANY(%21$L::smallint[])
        )
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
        GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s AS proj_geared,
        GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s), 0) AS needu_geared
      FROM with_gear wg
    ),
    geared AS (
      SELECT g.*,
        CASE WHEN g.ros_final<=0 THEN 0
             WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1)
             ELSE 0 END::int AS geared_packs_calc
      FROM geared_calc g
    ),
    with_promo AS (
      SELECT g.*, pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end, pm.status AS promo_status,
        pm.promo_unit_cost, pm.promo_description,
        -- ENG-017 naming: trailing parenthetical is the reliable anchor
        -- ("... (RG2)"), "Number <CODE>" is the fallback reading; neither
        -- resolving is a surfaced naming gap, never guessed (R21/R22).
        COALESCE(
          substring(pm.promo_description from '\(([A-Za-z0-9]+)\)\s*$'),
          substring(pm.promo_description from 'DC Promotion Number\s+(\S+)')
        ) AS promo_suffix_calc
      FROM geared g LEFT JOIN promo_match pm ON pm.product_code=g.product_code
    ),
    -- WALK-FINDINGS W2 (Pieter, live walk 2026-07-12, freeze lifted): the
    -- order_essentials preset NEVER gears -- suggested_packs = normal_packs
    -- always on this preset, even for promo-active lines. Promo lines keep
    -- their promo-sheet routing (promo_active stays true, driven by
    -- promo_nr IS NOT NULL, untouched below) but at the NORMAL quantity,
    -- qty-only per the capture-sheet template -- essentials is meant to be
    -- the strict-KVI/basic-demands selection, never a buy-in vehicle.
    resolved AS (
      SELECT wp.*,
        CASE
          WHEN %24$L::boolean THEN wp.normal_packs_calc
          WHEN wp.promo_nr IS NOT NULL THEN wp.geared_packs_calc
          ELSE wp.normal_packs_calc
        END AS resolved_packs_calc
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
      %1$L::text AS store_code, pk.product_code AS product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')) AS ean,
      pk.description AS description, pk.dept_name AS dept_name, %15$L::text AS route,
      pk.kvi_band AS kvi_band, pk.archetype AS archetype, pk.tier AS tier, pk.mode AS mode, pk.mode_reason AS mode_reason,
      (CASE WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END) AS demand_source, pk.ros_window_used AS ros_window_used,
      ROUND(pk.ros_final,4) AS rhythm_adjusted_demand,
      ROUND(pk.min_band_ot,2) AS min_band, ROUND(pk.max_band_ot,2) AS max_band, ROUND(pk.target_level,2) AS target_level,
      pk.soh_raw AS soh, %9$s::int AS lead_days_used, %17$L::text AS lead_days_source, ROUND(pk.proj,2) AS projected_soh,
      pk.count_first AS count_first, pk.band_blocked_reason AS band_blocked_reason,
      ROUND(pk.needu,2) AS need_units, pk.ps AS pack_size, ROUND(pk.pack_cost,2) AS pack_cost,
      pk.normal_packs_calc AS normal_packs, (pk.promo_nr IS NOT NULL) AS promo_active, pk.promo_nr AS promo_nr, pk.promo_start AS promo_start, pk.promo_end AS promo_end,
      ROUND(pk.gear,4) AS promo_uplift, (CASE WHEN pk.gear_from_own_promo THEN 'own_promo' ELSE 'default' END) AS promo_uplift_source,
      pk.promo_suffix_calc AS promo_suffix, (pk.promo_nr IS NOT NULL AND pk.promo_suffix_calc IS NULL) AS promo_naming_gap,
      pk.geared_packs_calc AS geared_packs,
      pk.resolved_packs_calc AS packs_before_fit, pk.final_packs AS suggested_packs, ROUND((pk.final_packs*pk.pack_cost)::numeric,2) AS value,
      pk.gmroi_quartile AS gmroi_quartile, pk.gmroi_capped AS gmroi_capped, pk.gmroi_rank AS gmroi_rank,
      pk.fit_applied AS budget_fit_applied, pk.fit_reason AS budget_fit_reason,
      %19$L::date AS budget_week_start, %20$L::text AS budget_week_source,
      pk.is_bt_hero AS is_bt_hero, %10$L::text AS preset_applied, %3$L::boolean AS frozen_focus_pending,
      format('%%s tier KVI=%%s, archetype=%%s -> %%s (%%s), window=%%s demand=%%s, band [%%s|%%s], SOH %%s, lead %%s(%%s) -> proj %%s, need %%s = %%s packs%%s%%s%%s',
        COALESCE(pk.tier,'-'), COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode, pk.mode_reason,
        pk.ros_window_used, ROUND(pk.ros_final,2),
        ROUND(pk.min_band_ot,1), ROUND(pk.max_band_ot,1), pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.resolved_packs_calc,
        CASE WHEN pk.count_first THEN format(' | COUNT_FIRST: %%s', CASE WHEN pk.soh_raw < 0 THEN 'negative claim, SOH treated as 0' ELSE 'positive claim, ordered on it, count still rides' END) ELSE '' END,
        CASE WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,
        CASE WHEN pk.fit_applied THEN format(' | budget fit: %%s (%%s -> %%s packs)', pk.fit_reason, pk.resolved_packs_calc, pk.final_packs) ELSE '' END) AS story
    FROM finalp pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
  $q$, p_store_code, v_soh_dt, v_pool_filter_active, v_dom,
       p_month_end_build_start_day, p_month_end_build_end_day, p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied,
       v_preset_catchup, p_catchup_band_cap_multiple, v_fit_to_budget, v_weekly_budget,
       p_route, v_dept_nrs, v_lead_source, v_next_delivery, v_week_start, v_week_source,
       v_dows, v_buyin_lead_days, p_delivery_date, v_preset_essentials);

  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
  EXECUTE format('CREATE TEMP TABLE _bloom_recipe_out AS %s', v_sql);

  -- Canon v7 item 9: band invariants, population-level, flag never block.
  -- The invariant only applies to the BAND-DRIVEN target (min_band_ot for
  -- 'minimum' mode, max_band_ot-anchored for 'build' mode) -- v_override
  -- IS NULL exactly when no flat day-cover override is in play. Both
  -- presets deliberately override the band with a flat day-cover target
  -- (order_essentials' 21/10-day minimum, canon v7 item 3; catch_up's
  -- 21-day floor band-capped at p_catchup_band_cap_multiple x max_band,
  -- BLOOM-004 5b) -- that is the preset's OWN named, PM-ruled ceiling,
  -- not a defect, so the check is scoped to standard runs only. Verified
  -- live 2026-07-11: an unscoped check false-positived on 615/619 rows on
  -- a catch_up run and 615/619 on essentials before this fix -- both were
  -- override rows behaving exactly as designed, not real violations.
  IF v_override IS NULL THEN
    EXECUTE 'SELECT count(*) FROM _bloom_recipe_out WHERE target_level > max_band + 0.01
               OR (need_units > 0 AND target_level < min_band - 0.01)'
      INTO v_band_violations;
    IF v_band_violations > 0 THEN
      RAISE WARNING 'canon v7 item 9: band invariant violated on % row(s) (store=%, route=%, delivery=%, preset=%)',
        v_band_violations, p_store_code, p_route, p_delivery_date, v_preset_applied;
    END IF;
  END IF;

  RETURN QUERY EXECUTE 'SELECT * FROM _bloom_recipe_out ORDER BY rhythm_adjusted_demand DESC, product_code';
  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
