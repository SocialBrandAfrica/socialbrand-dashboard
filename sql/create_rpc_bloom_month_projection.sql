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

CREATE FUNCTION public.rpc_bloom_month_projection(
  p_store_code text,
  p_route text
)
RETURNS TABLE(
  row_kind text,
  drop_number integer,
  delivery_date date,
  lines integer,
  projected_value numeric,
  running_purchases numeric,
  month_to_date_landed numeric,
  month_purchases_projected_total numeric,
  route_budget_amount numeric,
  drops_capped boolean,
  sales_target_note text,
  computed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_month_start date := date_trunc('month', CURRENT_DATE)::date;
  v_month_end date := (date_trunc('month', CURRENT_DATE) + interval '1 month' - interval '1 day')::date;
  v_ledger_route text;
  v_d_curr date; v_d_next date; v_d_check date; v_d_after date;
  v_soh_override jsonb := NULL;
  v_drop_num int := 0;
  v_lines int; v_value numeric;
  v_running numeric := 0;
  v_mtd_landed numeric;
  v_budget numeric;
  v_capped boolean := false;
BEGIN
  SET LOCAL statement_timeout = '45s';

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

  EXECUTE 'DROP TABLE IF EXISTS _month_chain';
  CREATE TEMP TABLE _month_chain (drop_number int, delivery_date date, lines int, value numeric);

  SELECT nd.delivery_date, nd.following_date INTO v_d_curr, v_d_next
  FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, CURRENT_DATE) nd;

  WHILE v_d_curr IS NOT NULL AND v_d_curr <= v_month_end LOOP
    v_drop_num := v_drop_num + 1;
    IF v_drop_num > 8 THEN
      v_capped := true;
      EXIT;
    END IF;

    EXECUTE 'DROP TABLE IF EXISTS _month_chain_run';
    CREATE TEMP TABLE _month_chain_run AS
    SELECT r.product_code, r.rhythm_adjusted_demand AS demand, r.projected_soh AS proj,
      r.pack_size, r.suggested_packs, r.value
    FROM public.rpc_bloom_order_recipe(p_store_code, v_d_curr, v_d_next, NULL, NULL, NULL, false, 15, 24, 25, 3.0, p_route, v_soh_override) r;

    SELECT count(*) FILTER (WHERE c.suggested_packs > 0), COALESCE(SUM(c.value), 0)
    INTO v_lines, v_value
    FROM _month_chain_run c;

    INSERT INTO _month_chain VALUES (v_drop_num, v_d_curr, v_lines, v_value);

    EXIT WHEN v_d_next IS NULL OR v_d_next > v_month_end;

    -- carry this drop's own landing forward into the NEXT drop's simulated
    -- SOH, same literal formula as rpc_bloom_delivery_chain's own 2-drop
    -- case (proj + this drop's units - demand over the gap to the next).
    SELECT jsonb_object_agg(
      c.product_code::text,
      c.proj + (c.suggested_packs * c.pack_size) - c.demand * (v_d_next - v_d_curr)
    )
    INTO v_soh_override
    FROM _month_chain_run c;

    SELECT nd.delivery_date, nd.following_date INTO v_d_check, v_d_after
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, v_d_curr) nd;

    v_d_curr := v_d_next;
    v_d_next := v_d_after;
  END LOOP;

  EXECUTE 'DROP TABLE IF EXISTS _month_chain_run';

  RETURN QUERY
  WITH numbered AS (
    SELECT mc.drop_number, mc.delivery_date, mc.lines, mc.value,
      SUM(mc.value) OVER (ORDER BY mc.drop_number) AS running
    FROM _month_chain mc
  )
  SELECT 'DROP'::text, n.drop_number, n.delivery_date, n.lines, ROUND(n.value,2), ROUND(n.running,2),
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::boolean, NULL::text, v_now
  FROM numbered n
  UNION ALL
  SELECT 'MONTH_SUMMARY', NULL, NULL, NULL, NULL, NULL,
    ROUND(v_mtd_landed,2), ROUND(v_mtd_landed + COALESCE((SELECT SUM(value) FROM _month_chain),0), 2),
    v_budget, v_capped,
    'No sales-target figure exists in this schema (order_budget_ledger carries a budget, not a sales target) -- route_budget_amount shown instead, explicitly labelled. PM/Pieter to supply a real target before this compares purchases vs sales.',
    v_now
  ORDER BY 1 ASC, 2;

  EXECUTE 'DROP TABLE IF EXISTS _month_chain';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_month_projection(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_month_projection(text,text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
