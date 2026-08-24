-- =============================================================================
-- create_rpc_bloom_month_projection.sql
-- SB-CC-BLOOM-008 item 16(b) -- THE MONTH PICTURE. "Every remaining drop
-- in the calendar month chained the same way, month-to-date receipts
-- (landed leg) + committed + projected vs the month's sales target --
-- where purchases vs sales ENDS under orders that support the target."
--
-- Chains rpc_bloom_delivery_chain's own mechanism (same simulated-SOH
-- formula, same real recipe engine per drop, R21) forward through every
-- remaining delivery date in the CURRENT calendar month -- not just two
-- drops. Each drop's simulated SOH carries the PREVIOUS drop's own
-- suggested_packs forward (never a hand-typed guess), so drop 3 reflects
-- both drop 1 and drop 2 having landed.
--
-- month_to_date_landed = order_budget_ledger.landed_amount, grain='monthly',
-- this month, this route's own ledger key (mirrors rpc_bloom_order_recipe's
-- v_ledger_route CASE) -- the REAL already-happened leg (item 16c, shipped
-- first). committed_amount is still the documented Ship-1 gap (no order-
-- submission persistence yet) -- every remaining drop in this projection is
-- therefore shown as PROJECTED, never silently relabelled "committed".
--
-- "vs the month's sales target" -- NOT built. No sales-target figure exists
-- anywhere in this schema (order_budget_ledger carries a BUDGET, not a
-- sales target; no config table names one). Flagged in sales_target_note
-- rather than invented (R27 SS7 -- never guess a number PM/Pieter hasn't
-- given). budget_amount (this route's own weekly/monthly plan figure) rides
-- alongside as the nearest REAL number already in the schema, explicitly
-- labelled as budget, not sales.
--
-- Bounded at 8 drops (matches a realistic worst-case daily-ish DC cadence
-- across a 31-day month without an unbounded loop) -- if a route's own
-- cadence would need more, drops beyond 8 are silently NOT projected;
-- flagged in the summary row's own drops_capped flag rather than a silent
-- truncation (no-silent-caps discipline).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_month_projection(text,text);


-- =============================================================================
-- 2026-08-24 (ENG-088, CC). Drop 1 READS THE CACHE. Drops 2..N are LABELLED.
--
-- ⚠️ RULING C EXTENDED BY CC TO A SECOND OBJECT, and flagged as an extension
-- rather than claimed as ruled. PM ruled (SB-CC-BLOOM-026 §13 Ruling C) that the
-- delivery chain's order 2 returns a labelled "not precomputed" because it needs
-- a p_soh_override variant the cache does not hold, and mechanism (e5) will own
-- those. This function has the IDENTICAL dependency, only worse: it looped up to
-- EIGHT recipe runs, drops 2..8 each fed by an override built from the drop
-- before it. At ~36s per recipe run that is ~5 minutes against the anon role's
-- 30s ceiling, so the card could never finish. Its in-body
-- SET LOCAL statement_timeout '45s' was decorative anyway (ENG-096) -- the bound
-- is armed by the caller or the role, never in-body, and it is now removed.
--
-- KEPT, because it is real and cheap:
--   * the DROP DATES for the whole month, walked off supplier_calendar
--   * drop 1's lines and value, READ from the cache
--   * month-to-date landed and the route budget, off order_budget_ledger
--
-- LABELLED NOT PRECOMPUTED:
--   * drops 2..N lines/value -> NULL, with the reason on the row
--   * month_purchases_projected_total -> NULL, NOT a partial sum. Returning
--     "MTD landed + drop 1" under a column called a month TOTAL would understate
--     the month and read as measured. A partial presented as a total is the
--     false-confidence class this project treats as worse than a blank (R22 §3),
--     and it is the same reasoning that made the Capital Tied false-zero a
--     defect the same night (ENG-100).
--
-- Verified 2026-08-24 00:3x SAST, 80175 DC_AMBIENT: drop 1 = 206 lines /
-- R108,250.50 (ties to PM's independent figure), drop 2 2026-08-29 labelled,
-- month summary NULL total with its reason.
--
-- 🔴 FRONTEND CHECK OWED: NULL here means NOT COMPUTED and must render as an
-- em-dash, never R0 -- the exact coercion ENG-100 had to fix on Pulse hours
-- earlier. Pre-existing and unrelated: month_to_date_landed reads 0.00 because
-- landed_amount's writer is not in the nightly chain (ENG-091), and
-- route_budget_amount is NULL where no monthly ledger row exists.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_month_projection(p_store_code text, p_route text)
 RETURNS TABLE(row_kind text, drop_number integer, delivery_date date, lines integer, projected_value numeric, running_purchases numeric, month_to_date_landed numeric, month_purchases_projected_total numeric, route_budget_amount numeric, drops_capped boolean, sales_target_note text, computed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_month_start date := date_trunc('month', CURRENT_DATE)::date;
  v_month_end date := (date_trunc('month', CURRENT_DATE) + interval '1 month' - interval '1 day')::date;
  v_ledger_route text;
  v_d_curr date; v_d_next date; v_d_check date; v_d_after date;
  v_drop_num int := 0;
  v_mtd_landed numeric;
  v_budget numeric;
  v_capped boolean := false;
  v_cache_id bigint;
  v_d1_lines int; v_d1_value numeric;
BEGIN
  v_ledger_route := CASE
    WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'
    WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'
    ELSE 'DC'
  END;

  SELECT COALESCE(SUM(obl.landed_amount), 0) INTO v_mtd_landed
  FROM public.order_budget_ledger obl
  WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route
    AND obl.grain = 'monthly' AND obl.year_month = v_month_start;

  SELECT obl.budget_amount INTO v_budget
  FROM public.order_budget_ledger obl
  WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route
    AND obl.grain = 'monthly' AND obl.year_month = v_month_start;

  DROP TABLE IF EXISTS _month_chain;
  CREATE TEMP TABLE _month_chain (drop_number int, delivery_date date, lines int, value numeric);

  SELECT nd.delivery_date, nd.following_date INTO v_d_curr, v_d_next
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, CURRENT_DATE) nd;

  -- Drop 1 ONLY comes from the cache. It is the one drop with no override.
  SELECT c.cache_id INTO v_cache_id
    FROM public.bloom_order_cache c
   WHERE c.store_code = p_store_code AND c.route_key = p_route
     AND c.delivery_date = v_d_curr AND c.next_delivery = v_d_next
     AND c.preset = 'standard' AND c.fit_to_budget = false
   ORDER BY c.generated_at DESC LIMIT 1;

  IF v_cache_id IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE l.suggested_packs > 0), COALESCE(SUM(l.value),0)
      INTO v_d1_lines, v_d1_value
      FROM public.bloom_order_cache_line l WHERE l.cache_id = v_cache_id;
  END IF;

  -- Walk the month's drop DATES off the calendar. Cheap, and the dates are real
  -- even where the values are not computed.
  WHILE v_d_curr IS NOT NULL AND v_d_curr <= v_month_end LOOP
    v_drop_num := v_drop_num + 1;
    IF v_drop_num > 8 THEN
      v_capped := true;
      EXIT;
    END IF;

    INSERT INTO _month_chain VALUES (
      v_drop_num, v_d_curr,
      CASE WHEN v_drop_num = 1 THEN v_d1_lines ELSE NULL END,
      CASE WHEN v_drop_num = 1 THEN v_d1_value ELSE NULL END);

    EXIT WHEN v_d_next IS NULL OR v_d_next > v_month_end;

    SELECT nd.delivery_date, nd.following_date INTO v_d_check, v_d_after
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, v_d_curr) nd;

    v_d_curr := v_d_next;
    v_d_next := v_d_after;
  END LOOP;

  RETURN QUERY
  WITH numbered AS (
    SELECT mc.drop_number, mc.delivery_date, mc.lines, mc.value,
      SUM(mc.value) OVER (ORDER BY mc.drop_number) AS running
    FROM _month_chain mc
  )
  SELECT 'DROP'::text, n.drop_number, n.delivery_date, n.lines,
    ROUND(n.value,2), ROUND(n.running,2),
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::boolean,
    CASE WHEN n.drop_number = 1
         THEN CASE WHEN v_cache_id IS NULL
                   THEN 'Drop 1 not cached for these dates -- no value computed. Not zero: not computed.'
                   ELSE 'Drop 1 read from the precomputed order.' END
         ELSE 'Not precomputed. This drop needs a stock-override projection off the drop before it, which the cache does not hold; that lands with the pre-order stock pull (SB-CC-BLOOM-026 mechanism e5). The DATE is real, the value is not computed -- never read a blank here as zero.'
    END,
    v_now
  FROM numbered n
  UNION ALL
  SELECT 'MONTH_SUMMARY', NULL, NULL, NULL, NULL, NULL,
    ROUND(v_mtd_landed,2),
    NULL::numeric,
    v_budget, v_capped,
    'month_purchases_projected_total is NOT COMPUTED: only drop 1 is precomputed, and drops 2..N need per-drop stock-override projections that arrive with mechanism (e5). Returning "MTD landed + drop 1" under a month TOTAL would understate the month and read as measured, so it is NULL and said out loud rather than shown as a number (R22 §3). Separately, and unchanged: no sales-target figure exists in this schema -- order_budget_ledger carries a budget, not a sales target -- so route_budget_amount is shown instead, explicitly labelled.',
    v_now
  ORDER BY 1 ASC, 2;

  DROP TABLE IF EXISTS _month_chain;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_month_projection(text,text) TO anon, authenticated;
