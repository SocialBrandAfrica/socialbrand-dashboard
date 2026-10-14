-- SCRATCH, NOT A MIGRATION. Never applied as source of record. Runs on the live database only between 20:00 and 22:00 SAST (PM 14-10-2026, no tests or scratch builds 07:00 to 20:00).
-- ITEM 2 SIMULATION (pure read, no live write): the recipe with the fit floor taken off the non-protected lines, against the live recipe, same arguments.
-- Run as a one-off cron job. Writes cc_scratch_b035_sim2 (service_role only).
DROP TABLE IF EXISTS public.cc_scratch_b035_sim2;
CREATE TABLE public.cc_scratch_b035_sim2 (store_code text, route_key text, delivery_date date, next_delivery date, old_value numeric, new_value numeric, old_lines int, new_lines int,
  protected_value numeric, week_remaining numeric, protected_over_need boolean, note text);
REVOKE ALL ON public.cc_scratch_b035_sim2 FROM PUBLIC, anon, authenticated;
DO $sim$
DECLARE
  def text; a text; n int; r record; v_old numeric; v_new numeric; v_ol int; v_nl int; v_prot numeric; v_wk numeric;
BEGIN
  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  a := $a$WHEN b.resolved_packs_calc >= 1 AND (b.mp_life OR (b.slow_candidate AND b.pack_relevant) OR b.tf_pack_hit) THEN 1$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'floor anchor found % times', n; END IF;
  def := replace(def, a, 'WHEN false THEN 1');
  def := replace(def, 'CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe(', 'CREATE OR REPLACE FUNCTION pg_temp.rpc_bloom_order_recipe_b(');
  EXECUTE def;
  FOR r IN
    SELECT DISTINCT ON (c.store_code, c.route_key) c.store_code, c.route_key, c.delivery_date, c.next_delivery
      FROM bloom_order_cache c
     WHERE c.preset = 'standard' AND c.fit_to_budget
       AND ((c.route_key IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER'))
            OR (c.store_code = '10116' AND c.route_key IN ('DIRECT_COCACOLA','DIRECT_CLOVER','DIRECT_MONDELEZ'))
            OR (c.store_code = '80175' AND c.route_key IN ('DIRECT_COCACOLA','DIRECT_CLOVER')))
     ORDER BY c.store_code, c.route_key, c.generated_at DESC
  LOOP
    SELECT COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0), 0), count(*) FILTER (WHERE x.suggested_packs > 0),
           COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0 AND x.budget_fit_reason = 'protected_kvi_hero'), 0)
      INTO v_old, v_ol, v_prot
      FROM public.rpc_bloom_order_recipe(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, true, NULL, NULL, NULL, NULL, r.route_key) x;
    SELECT COALESCE(sum(x.value) FILTER (WHERE x.suggested_packs > 0), 0), count(*) FILTER (WHERE x.suggested_packs > 0)
      INTO v_new, v_nl
      FROM pg_temp.rpc_bloom_order_recipe_b(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, true, NULL, NULL, NULL, NULL, r.route_key) x;
    SELECT COALESCE(obl.budget_amount, 0) - COALESCE(obl.committed_amount, 0) INTO v_wk
      FROM order_budget_ledger obl
     WHERE obl.store_code = r.store_code AND obl.grain = 'weekly'
       AND obl.route_key = CASE WHEN r.route_key LIKE 'DC\_%' THEN 'DC' WHEN r.route_key = 'DIRECT_BEER' THEN 'DIRECT_BEER' ELSE 'DIRECT' END
       AND obl.year_month = r.delivery_date - ((EXTRACT(ISODOW FROM r.delivery_date)::int + 1) % 7);
    INSERT INTO public.cc_scratch_b035_sim2 VALUES (r.store_code, r.route_key, r.delivery_date, r.next_delivery, v_old, v_new, v_ol, v_nl, v_prot, v_wk, v_prot > v_wk, NULL);
  END LOOP;
END
$sim$;
