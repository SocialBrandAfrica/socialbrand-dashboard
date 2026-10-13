-- =============================================================================
-- rpc_bloom_stored_overview -- THE SCENARIO CARDS ON EVERY DESK, FROM STORED FACTS
-- SB-CC-BLOOM-035 item 9 = SB-CC-BLOOM-034 Part 1 + the weekly verdict (Pieter, RULED-ALREADY 6).
--
-- GRADE: RECOMMENDED. Reads bloom_order_cache and bloom_order_cache_line, the orders the
-- night job already stored. It runs NO recipe and moves NO quantity (R32 section 3: an
-- applet reads, never computes). Replaces the per-scenario calls to
-- rpc_bloom_scenario_overview, which ran the recipe 4 to 5 times per page load.
--
-- One call returns, for the desk and delivery asked:
--   cards[]   Full need (standard, fit off) and Fitted (standard, fit on), each from the
--             stored order itself: value = sum(suggested_packs * pack_cost), lines on the
--             order, promo share, lines kept whole, lines cut, the build time.
--   benchmark the route's weekly demand and its anchor date, as stored on the cache row
--             (DC desks only; brand and SAB desks have no ruled basis and say so).
--   week      the verdict, as ruled: the week's orders together against the week's
--             demand. Receipts landed this budget week before this delivery, plus stock in
--             transit, plus the stored fitted orders for this delivery and any later drop
--             of the week. Flag, never block. Not judged unless every drop of the week is
--             known. cash_constrained (ENG-111) is read, and is the one exemption.
--
-- yardstick_tolerance_pct is 20 and is stamped SEED, UNDERIVED (ORDERING-CANON-REGISTERS
-- G2: the key does not exist in forge_config; it runs as a parameter default, as it does
-- in rpc_bloom_scenario_overview). It is not re-tuned here.
--
-- Grants: a read RPC, anon and authenticated, like rpc_bloom_order_cached (R30 addendum
-- extension: read RPCs are exempt from the mutating-function revoke pattern).
-- Rollback: DROP FUNCTION public.rpc_bloom_stored_overview(text, text, date, date, text, numeric);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_stored_overview(
  p_store_code    text,
  p_route         text,
  p_delivery_date date    DEFAULT NULL,
  p_next_delivery date    DEFAULT NULL,
  p_preset        text    DEFAULT 'standard',
  p_tolerance_pct numeric DEFAULT 20
) RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_del      date := p_delivery_date;
  v_nxt      date := p_next_delivery;
  v_preset   text := COALESCE(p_preset, 'standard');
  v_fit      boolean;
  v_hdr      record;
  v_agg      record;
  v_cards    jsonb := '[]'::jsonb;
  v_card     jsonb;
  v_fit_val  numeric;
  v_fit_cache  bigint;
  v_fit_bench  numeric;
  v_fit_anchor date;
  v_any_cache  bigint;
  v_any_bench  numeric;
  v_any_anchor date;
  v_bench    numeric;
  v_anchor   date;
  v_bench_j  jsonb;
  v_week     jsonb;
  v_b        record;
  v_drop     date;
  v_stored   numeric;
  v_known    numeric := 0;
  v_missing  date[] := ARRAY[]::date[];
  v_later    date[] := ARRAY[]::date[];
  v_total    numeric;
  v_dev      numeric;
  v_cash     boolean;
  v_ledger   text;
  v_engine   text;
BEGIN
  IF v_del IS NULL OR v_nxt IS NULL THEN
    SELECT COALESCE(v_del, nd.delivery_date), COALESCE(v_nxt, nd.following_date)
      INTO v_del, v_nxt
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route) nd LIMIT 1;
  END IF;

  SELECT md5(pg_get_functiondef(p.oid)) INTO v_engine
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe';

  FOREACH v_fit IN ARRAY ARRAY[false, true] LOOP
    SELECT c.cache_id, c.generated_at, c.line_count, c.engine_md5,
           c.benchmark_weekly_demand, c.benchmark_anchor_date
      INTO v_hdr
    FROM public.bloom_order_cache c
    WHERE c.store_code = p_store_code AND c.route_key = p_route
      AND c.delivery_date = v_del AND c.next_delivery = v_nxt
      AND c.preset = v_preset AND c.fit_to_budget = v_fit
    ORDER BY c.generated_at DESC LIMIT 1;

    IF NOT FOUND THEN
      v_card := jsonb_build_object(
        'card', CASE WHEN v_fit THEN 'fitted' ELSE 'full' END,
        'fit_to_budget', v_fit, 'found', false,
        'message', format('No stored %s order for %s %s, delivery %s to %s.',
                          CASE WHEN v_fit THEN 'fitted' ELSE 'full-need' END,
                          p_store_code, p_route, v_del, v_nxt));
    ELSE
      SELECT
        round(COALESCE(sum(l.suggested_packs * l.pack_cost), 0), 2)                                           AS value,
        count(*) FILTER (WHERE l.suggested_packs > 0)                                                         AS lines,
        round(COALESCE(sum(l.suggested_packs * l.pack_cost) FILTER (WHERE l.promo_active), 0), 2)             AS promo_value,
        count(*) FILTER (WHERE l.suggested_packs > 0 AND l.suggested_packs >= l.packs_before_fit)             AS kept_whole,
        count(*) FILTER (WHERE l.suggested_packs < l.packs_before_fit)                                        AS cut_lines,
        round(COALESCE(sum((l.packs_before_fit - l.suggested_packs) * l.pack_cost)
                       FILTER (WHERE l.suggested_packs < l.packs_before_fit), 0), 2)                          AS cut_value,
        count(*) FILTER (WHERE l.line_kind = 'hidden')                                                        AS hidden_lines
      INTO v_agg
      FROM public.bloom_order_cache_line l
      WHERE l.cache_id = v_hdr.cache_id AND l.line_kind IS DISTINCT FROM 'covered';

      v_card := jsonb_build_object(
        'card', CASE WHEN v_fit THEN 'fitted' ELSE 'full' END,
        'fit_to_budget', v_fit, 'found', true,
        'cache_id', v_hdr.cache_id, 'generated_at', v_hdr.generated_at,
        'engine_current', (v_hdr.engine_md5 = v_engine),
        'value', v_agg.value, 'lines', v_agg.lines,
        'promo_value', v_agg.promo_value,
        'promo_share_pct', CASE WHEN v_agg.value > 0 THEN round(100 * v_agg.promo_value / v_agg.value, 1) END,
        'kept_whole', v_agg.kept_whole, 'cut_lines', v_agg.cut_lines, 'cut_value', v_agg.cut_value,
        'hidden_lines', v_agg.hidden_lines);

      IF v_fit THEN
        v_fit_val := v_agg.value; v_fit_cache := v_hdr.cache_id;
        v_fit_bench := v_hdr.benchmark_weekly_demand; v_fit_anchor := v_hdr.benchmark_anchor_date;
      END IF;
      v_any_cache := v_hdr.cache_id;
      v_any_bench := v_hdr.benchmark_weekly_demand; v_any_anchor := v_hdr.benchmark_anchor_date;
    END IF;
    v_cards := v_cards || v_card;
  END LOOP;

  -- The benchmark as the cache row stored it. Fitted row first, then full need.
  IF v_fit_cache IS NOT NULL THEN
    v_bench := v_fit_bench; v_anchor := v_fit_anchor;
  ELSIF v_any_cache IS NOT NULL THEN
    v_bench := v_any_bench; v_anchor := v_any_anchor;
  END IF;

  v_bench_j := CASE WHEN v_any_cache IS NULL THEN
      jsonb_build_object('weekly_demand', NULL, 'anchor_date', NULL,
        'note', 'No stored order for these dates, so no stored benchmark.')
    WHEN v_bench IS NULL THEN
      jsonb_build_object('weekly_demand', NULL, 'anchor_date', NULL,
        'note', 'No basis is ruled for this desk. Nothing is invented.')
    ELSE jsonb_build_object('weekly_demand', v_bench, 'anchor_date', v_anchor,
        'note', 'One week of sales at cost for the desk''s departments: 28 days of cost over 4, to the anchor date.')
    END;

  -- The weekly verdict.
  IF v_any_cache IS NULL THEN
    v_week := jsonb_build_object('verdict', 'NOT_JUDGEABLE',
      'reason', 'There is no stored order for these dates, so the week cannot be judged.');
  ELSIF v_bench IS NULL THEN
    v_week := jsonb_build_object('verdict', 'NO_BASIS',
      'reason', 'No basis is ruled for this desk, so the week is not judged.');
  ELSIF v_fit_cache IS NULL THEN
    v_week := jsonb_build_object('verdict', 'NOT_JUDGEABLE',
      'reason', 'There is no stored fitted order for this delivery, so the week cannot be judged.');
  ELSE
    SELECT * INTO v_b FROM public.rpc_bloom_delivery_budget(p_store_code, p_route, v_del);
    v_ledger := v_b.ledger_route;

    SELECT l.cash_constrained INTO v_cash
    FROM public.order_budget_ledger l
    WHERE l.store_code = p_store_code AND l.route_key = v_ledger
      AND l.grain = 'weekly' AND l.year_month = v_b.budget_week_start;

    IF v_b.delivery_index = 0 THEN
      v_week := jsonb_build_object('verdict', 'NOT_JUDGEABLE',
        'budget_week_start', v_b.budget_week_start,
        'reason', format('%s is not a scheduled delivery day of the week of %s, so the week is not judged.',
                         v_del, v_b.budget_week_start));
    ELSE
      FOREACH v_drop IN ARRAY v_b.deliveries_in_week LOOP
        IF v_drop < v_del THEN CONTINUE; END IF;          -- already landed: inside landed_before_this_delivery
        IF v_drop = v_del THEN
          v_known := v_known + v_fit_val;
        ELSE
          v_later := v_later || v_drop;
          SELECT round(sum(l.suggested_packs * l.pack_cost), 2) INTO v_stored
          FROM public.bloom_order_cache_line l
          WHERE l.line_kind IS DISTINCT FROM 'covered'
            AND l.cache_id = (SELECT c.cache_id FROM public.bloom_order_cache c
                              WHERE c.store_code = p_store_code AND c.route_key = p_route
                                AND c.delivery_date = v_drop AND c.preset = v_preset
                                AND c.fit_to_budget = true
                              ORDER BY c.generated_at DESC LIMIT 1);
          IF v_stored IS NULL THEN v_missing := v_missing || v_drop;
          ELSE v_known := v_known + v_stored; END IF;
        END IF;
      END LOOP;

      v_total := v_b.landed_before_this_delivery + v_b.in_transit_into_this_week + v_known;

      IF array_length(v_missing, 1) > 0 THEN
        v_week := jsonb_build_object('verdict', 'NOT_JUDGEABLE',
          'budget_week_start', v_b.budget_week_start, 'drops_in_week', v_b.deliveries_in_week,
          'drop_index', v_b.delivery_index, 'drops_total', v_b.deliveries_total,
          'drops_without_stored_order', v_missing,
          'landed_before', v_b.landed_before_this_delivery, 'in_transit', v_b.in_transit_into_this_week,
          'this_fitted', v_fit_val,
          'reason', format('Drop %s of %s this week. The stored orders do not yet cover the whole week: no stored fitted order for %s. The week is judged once every drop of it is known.',
                           v_b.delivery_index, v_b.deliveries_total, array_to_string(v_missing, ', ')));
      ELSE
        v_dev := round(100 * (v_total - v_bench) / NULLIF(v_bench, 0), 1);
        v_week := jsonb_build_object(
          'verdict', CASE WHEN COALESCE(v_cash, false) THEN 'EXEMPT'
                          WHEN abs(v_dev) > p_tolerance_pct THEN 'FLAG' ELSE 'WITHIN' END,
          'budget_week_start', v_b.budget_week_start, 'drops_in_week', v_b.deliveries_in_week,
          'drop_index', v_b.delivery_index, 'drops_total', v_b.deliveries_total,
          'landed_before', v_b.landed_before_this_delivery, 'in_transit', v_b.in_transit_into_this_week,
          'this_fitted', v_fit_val, 'later_stored', v_known - v_fit_val,
          'week_value', round(v_total, 2), 'weekly_demand', v_bench,
          'deviation_pct', v_dev, 'tolerance_pct', p_tolerance_pct,
          'week_needs_budget', v_b.week_needs_budget,
          'cash_constrained', COALESCE(v_cash, false),
          'reason', format('The week''s orders together: R%s landed this week before this delivery, R%s in transit, R%s this fitted order%s = R%s, against the week''s demand of R%s (%s%%). Off by more than %s%% is flagged, never blocked.',
                           to_char(v_b.landed_before_this_delivery, 'FM999G999G990'),
                           to_char(v_b.in_transit_into_this_week, 'FM999G999G990'),
                           to_char(v_fit_val, 'FM999G999G990'),
                           CASE WHEN v_known - v_fit_val > 0
                                THEN format(' and R%s on the stored later drops', to_char(v_known - v_fit_val, 'FM999G999G990')) ELSE '' END,
                           to_char(v_total, 'FM999G999G990'), to_char(v_bench, 'FM999G999G990'),
                           to_char(v_dev, 'FM990D0'), p_tolerance_pct));
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'store_code', p_store_code, 'route', p_route, 'preset', v_preset,
    'delivery_date', v_del, 'next_delivery', v_nxt,
    'drop_cover_days', CASE WHEN v_nxt IS NOT NULL AND v_del IS NOT NULL THEN v_nxt - v_del END,
    'cards', v_cards, 'benchmark', v_bench_j, 'week', v_week);
END
$fn$;

COMMENT ON FUNCTION public.rpc_bloom_stored_overview(text, text, date, date, text, numeric) IS
'GRADE: RECOMMENDED. The scenario cards on every desk from the stored orders, SB-CC-BLOOM-035 item 9. Two cards (Full need = standard fit off, Fitted = standard fit on) summed from bloom_order_cache_line as sum(suggested_packs*pack_cost); the stored route benchmark; the weekly verdict (the week''s orders together against the week''s demand, tolerance 20 SEED UNDERIVED, flag never block, cash_constrained the one exemption). Runs no recipe, moves no quantity.';

REVOKE EXECUTE ON FUNCTION public.rpc_bloom_stored_overview(text, text, date, date, text, numeric) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_stored_overview(text, text, date, date, text, numeric) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
