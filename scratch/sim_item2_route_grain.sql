-- SCRATCH, NOT A MIGRATION. Never applied as source of record. Runs on the live database only between 20:00 and 22:00 SAST (PM 14-10-2026, no tests or scratch builds 07:00 to 20:00).
-- ITEM 2 SIMULATION (pure read of the live ordering objects, writes only scratch tables): the fit to each desk's OWN need, the need being the desk's own
-- projection (l2_sales_budget route row) summed over the budget weeks the delivery covers (ceil of the gap to the next delivery in weeks), against the stored
-- fitted order the live recipe produced. Committed spend is ignored in the simulation (it is nil for the new route rows on day one).
-- One-off cron job. Writes cc_scratch_b035_sim3 (results) and cc_scratch_b035_sb (a copy of l2_sales_budget plus the projections of the sampled derived desks).
DROP TABLE IF EXISTS public.cc_scratch_b035_sim3;
DROP TABLE IF EXISTS public.cc_scratch_b035_sb;
CREATE TABLE public.cc_scratch_b035_sb AS SELECT * FROM public.l2_sales_budget;
CREATE TABLE public.cc_scratch_b035_sim3 (store_code text, route_key text, delivery_date date, next_delivery date, weeks_covered int, old_value numeric, old_lines int,
  new_value numeric, new_lines int, own_need numeric, pooled_need_old numeric, protected_value numeric, note text);
REVOKE ALL ON public.cc_scratch_b035_sb, public.cc_scratch_b035_sim3 FROM PUBLIC, anon, authenticated;
DO $sim$
DECLARE
  def text; a text; n int; r record; v_new numeric; v_nl int; v_prot numeric; v_own numeric; v_w int;
BEGIN
  -- the sample: every hand-typed DIRECT desk, and the six derived desks with the largest stored fitted order at each of the two SPARs
  CREATE TEMP TABLE _sample AS
  WITH latest AS (
    SELECT DISTINCT ON (c.store_code, c.route_key) c.cache_id, c.store_code, c.route_key, c.delivery_date, c.next_delivery
      FROM bloom_order_cache c WHERE c.preset = 'standard' AND c.fit_to_budget AND c.route_key LIKE 'DIRECT\_%'
     ORDER BY c.store_code, c.route_key, c.generated_at DESC),
  v AS (SELECT l.cache_id, sum(l.value) FILTER (WHERE l.line_kind = 'ordered' AND l.suggested_packs > 0) val, count(*) FILTER (WHERE l.line_kind = 'ordered' AND l.suggested_packs > 0) ln
          FROM bloom_order_cache_line l GROUP BY 1),
  j AS (SELECT a.*, v.val, v.ln, row_number() OVER (PARTITION BY a.store_code, (a.route_key ~ '^DIRECT_S[0-9]+$') ORDER BY v.val DESC NULLS LAST) rk FROM latest a JOIN v USING (cache_id))
  SELECT * FROM j WHERE route_key !~ '^DIRECT_S[0-9]+$' OR (store_code IN ('10116','80175') AND rk <= 6);

  -- project the sampled derived desks into the scratch copy (the live table skips them)
  FOR r IN SELECT store_code, route_key FROM _sample WHERE route_key ~ '^DIRECT_S[0-9]+$' LOOP
    INSERT INTO public.cc_scratch_b035_sb (client_id, store_code, route_key, budget_week_start, month_start, ly_base_cost, trend_factor,
        rhythm_seasonality_projected_cost, projected_sales_cost, products_in_pool, products_with_ly_history, anchor_date)
      SELECT 'socialbrand', r.store_code, r.route_key, x.budget_week_start, x.month_start, x.ly_base_cost, x.trend_factor,
             x.rhythm_seasonality_projected_cost, x.projected_sales_cost, x.products_in_pool, x.products_with_ly_history, CURRENT_DATE
        FROM public.rpc_project_route_sales_budget(r.store_code, r.route_key, CURRENT_DATE, 26) x;
  END LOOP;

  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  a := $a$SELECT COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0) INTO v_weekly_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key=v_ledger_route AND obl.grain='weekly'
    AND obl.year_month = v_week_start;$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'budget anchor found % times', n; END IF;
  def := replace(def, a, $b$SELECT COALESCE(SUM(sb.projected_sales_cost), 0) INTO v_weekly_budget
  FROM public.cc_scratch_b035_sb sb
  WHERE sb.store_code = p_store_code AND sb.route_key = p_route
    AND sb.budget_week_start >= v_week_start
    AND sb.budget_week_start < v_week_start + 7 * GREATEST(1, CEIL((v_next_delivery - p_delivery_date) / 7.0))::int;$b$);
  def := replace(def, 'CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe(', 'CREATE OR REPLACE FUNCTION pg_temp.rpc_bloom_order_recipe_c(');
  EXECUTE def;

  FOR r IN SELECT * FROM _sample ORDER BY store_code, route_key LOOP
    v_w := GREATEST(1, CEIL((r.next_delivery - r.delivery_date) / 7.0))::int;
    SELECT COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0), 0), count(*) FILTER (WHERE x.suggested_packs > 0),
           COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0 AND x.budget_fit_reason = 'protected_kvi_hero'), 0)
      INTO v_new, v_nl, v_prot
      FROM pg_temp.rpc_bloom_order_recipe_c(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, true, NULL, NULL, NULL, NULL, r.route_key) x;
    SELECT COALESCE(SUM(sb.projected_sales_cost), 0) INTO v_own FROM public.cc_scratch_b035_sb sb
     WHERE sb.store_code = r.store_code AND sb.route_key = r.route_key
       AND sb.budget_week_start >= r.delivery_date - ((EXTRACT(ISODOW FROM r.delivery_date)::int + 1) % 7)
       AND sb.budget_week_start < r.delivery_date - ((EXTRACT(ISODOW FROM r.delivery_date)::int + 1) % 7) + 7 * v_w;
    INSERT INTO public.cc_scratch_b035_sim3 VALUES (r.store_code, r.route_key, r.delivery_date, r.next_delivery, v_w, r.val, r.ln, v_new, v_nl, v_own,
      (SELECT COALESCE(obl.budget_amount, 0) - COALESCE(obl.committed_amount, 0) FROM order_budget_ledger obl
        WHERE obl.store_code = r.store_code AND obl.grain = 'weekly' AND obl.route_key = CASE WHEN r.route_key = 'DIRECT_BEER' THEN 'DIRECT_BEER' ELSE 'DIRECT' END
          AND obl.year_month = r.delivery_date - ((EXTRACT(ISODOW FROM r.delivery_date)::int + 1) % 7)), v_prot, NULL);
  END LOOP;
END
$sim$;
