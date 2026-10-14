-- SCRATCH, NOT A MIGRATION. Never applied as source of record. Runs on the live database only between 20:00 and 22:00 SAST (PM 14-10-2026, no tests or scratch builds 07:00 to 20:00).
-- ITEM 2 READ-BACK (BLOOM-035, brief acceptance: "each desk's stored order totals no more than its own need for the delivery week, with the protected set whole.
-- Both values are read back on the live desk."). Pure read of the LIVE recipe, ledger and l2_sales_budget after the item 2 migration and the budget rebuild.
-- The same 28 desks (and delivery dates) as sql/_sim_item2_route_grain.sql. Run as a one-off cron job. Writes cc_scratch_b035_rb (service_role only).
-- own_need = the desk's own projection summed over the budget weeks the delivery covers. ledger_remaining = budget less committed over the same weeks.
DROP TABLE IF EXISTS public.cc_scratch_b035_rb;
CREATE TABLE public.cc_scratch_b035_rb (store_code text, route_key text, delivery_date date, next_delivery date, weeks_covered int,
  fitted_value numeric, fitted_lines int, protected_value numeric, unfitted_value numeric, own_need numeric, ledger_budget numeric, ledger_committed numeric,
  ledger_remaining numeric, sim_value numeric);
REVOKE ALL ON public.cc_scratch_b035_rb FROM PUBLIC, anon, authenticated;
DO $rb$
DECLARE
  r record; v_w int; v_ws date; v_fit numeric; v_fl int; v_prot numeric; v_unf numeric; v_own numeric; v_bud numeric; v_com numeric;
BEGIN
  FOR r IN SELECT * FROM public.cc_scratch_b035_sim3 ORDER BY store_code, route_key LOOP
    v_w := GREATEST(1, CEIL((r.next_delivery - r.delivery_date) / 7.0))::int;
    v_ws := r.delivery_date - ((EXTRACT(ISODOW FROM r.delivery_date)::int + 1) % 7);
    SELECT COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0), 0), count(*) FILTER (WHERE x.suggested_packs > 0),
           COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0 AND x.budget_fit_reason = 'protected_kvi_hero'), 0)
      INTO v_fit, v_fl, v_prot
      FROM public.rpc_bloom_order_recipe(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, true, NULL, NULL, NULL, NULL, r.route_key) x;
    SELECT COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0), 0) INTO v_unf
      FROM public.rpc_bloom_order_recipe(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, false, NULL, NULL, NULL, NULL, r.route_key) x;
    SELECT COALESCE(SUM(sb.projected_sales_cost), 0) INTO v_own FROM public.l2_sales_budget sb
     WHERE sb.store_code = r.store_code AND sb.route_key = r.route_key
       AND sb.budget_week_start >= v_ws AND sb.budget_week_start < v_ws + 7 * v_w;
    SELECT COALESCE(SUM(obl.budget_amount), 0), COALESCE(SUM(obl.committed_amount), 0) INTO v_bud, v_com FROM public.order_budget_ledger obl
     WHERE obl.store_code = r.store_code AND obl.route_key = r.route_key AND obl.grain = 'weekly'
       AND obl.year_month >= v_ws AND obl.year_month < v_ws + 7 * v_w;
    INSERT INTO public.cc_scratch_b035_rb VALUES (r.store_code, r.route_key, r.delivery_date, r.next_delivery, v_w, v_fit, v_fl, v_prot, v_unf, v_own, v_bud, v_com, v_bud - v_com, r.new_value);
  END LOOP;
END
$rb$;
