-- SCRATCH, NOT A MIGRATION. Never applied as source of record. Runs on the live database only between 20:00 and 22:00 SAST (PM 14-10-2026, no tests or scratch builds 07:00 to 20:00).
-- ITEM 3b SIMULATION (BLOOM-035, ENG-012): the recipe with the depletion taken over the days from the stock reading to the truck, against the live recipe, same arguments,
-- fit OFF (the pure need, no budget in it). A pg_temp copy of the live recipe is patched with the same asserted replaces as sql/bloom035_item3b_days_to_truck.sql.
-- Desks: the 28 DIRECT desks of the item 2 simulation (cc_scratch_b035_sim3) and every DC desk's latest standard cache. Writes cc_scratch_b035_sim3b (one row per desk)
-- and cc_scratch_b035_sim3b_lines (every line whose packs moved on a DC desk, plus the days the story names). service_role only.
DROP TABLE IF EXISTS public.cc_scratch_b035_sim3b;
DROP TABLE IF EXISTS public.cc_scratch_b035_sim3b_lines;
CREATE TABLE public.cc_scratch_b035_sim3b (store_code text, route_key text, delivery_date date, next_delivery date, soh_date date, days_to_truck int, drop_gap int,
  old_value numeric, old_lines int, new_value numeric, new_lines int, lines_up int, lines_down int, lines_same int);
CREATE TABLE public.cc_scratch_b035_sim3b_lines (store_code text, route_key text, product_code bigint, description text, kvi_band text, old_packs int, new_packs int,
  old_proj numeric, new_proj numeric, lead_days_used int, days_to_truck int, rate numeric, soh numeric, story_new text);
REVOKE ALL ON public.cc_scratch_b035_sim3b, public.cc_scratch_b035_sim3b_lines FROM PUBLIC, anon, authenticated;
DO $sim$
DECLARE
  def text; a text; n int; r record; v_soh date; v_d int; v_gap int;
  v_ov numeric; v_ol int; v_nv numeric; v_nl int; v_up int; v_dn int; v_same int;
BEGIN
  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  FOR a, n IN SELECT * FROM (VALUES
      ('v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int;', 1),
      (E'    v_lead_source := ''fallback_anchor_gap'';\n  END IF;\n', 1),
      ('t.ros_final * %9$s', 2), ('(wg.ros_final*wg.gear) * %9$s', 2),
      ('v_relevant_min_cover_days, v_tf_units, v_tf_pack_days);', 1),
      ('SOH %%s, lead %%s(%%s) -> proj %%s,', 1),
      ('pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1)', 1)) v(a, n)
  LOOP
    IF (length(def) - length(replace(def, a, ''))) / length(a) <> n THEN RAISE EXCEPTION 'anchor [%] not found % times', left(a, 60), n; END IF;
  END LOOP;
  def := replace(def, 'v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int;', 'v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int; v_days_to_truck int;');
  def := replace(def, E'    v_lead_source := ''fallback_anchor_gap'';\n  END IF;\n',
                      E'    v_lead_source := ''fallback_anchor_gap'';\n  END IF;\n\n  v_days_to_truck := COALESCE(GREATEST(p_delivery_date - v_soh_dt, 0), v_lead);\n');
  def := replace(def, 't.ros_final * %9$s', 't.ros_final * %32$s');
  def := replace(def, '(wg.ros_final*wg.gear) * %9$s', '(wg.ros_final*wg.gear) * %32$s');
  def := replace(def, 'v_relevant_min_cover_days, v_tf_units, v_tf_pack_days);', 'v_relevant_min_cover_days, v_tf_units, v_tf_pack_days, v_days_to_truck);');
  def := replace(def, 'SOH %%s, lead %%s(%%s) -> proj %%s,', 'SOH %%s, drop %%s(%%s), truck in %%s days, cover %%s days -> proj %%s,');
  def := replace(def, 'pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1)', 'pk.soh_raw, %9$s, %17$L::text, %32$s, (%32$s + %9$s), ROUND(pk.proj,1)');
  def := replace(def, 'CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe(', 'CREATE OR REPLACE FUNCTION pg_temp.rpc_bloom_order_recipe_t(');
  EXECUTE def;

  FOR r IN
    SELECT s.store_code, s.route_key, s.delivery_date, s.next_delivery FROM public.cc_scratch_b035_sim3 s
    UNION ALL
    SELECT x.store_code, x.route_key, x.delivery_date, x.next_delivery FROM (
      SELECT DISTINCT ON (c.store_code, c.route_key) c.store_code, c.route_key, c.delivery_date, c.next_delivery
        FROM public.bloom_order_cache c WHERE c.preset = 'standard' AND NOT c.fit_to_budget AND c.route_key LIKE 'DC\_%'
       ORDER BY c.store_code, c.route_key, c.generated_at DESC) x
    ORDER BY 1, 2
  LOOP
    SELECT MAX(sd.snapshot_date) INTO v_soh FROM public.l2_soh_daily sd WHERE sd.store_code = r.store_code;
    v_d := GREATEST(r.delivery_date - v_soh, 0);
    v_gap := GREATEST(r.next_delivery - r.delivery_date, 0);
    DROP TABLE IF EXISTS _o; DROP TABLE IF EXISTS _n;
    CREATE TEMP TABLE _o AS SELECT * FROM public.rpc_bloom_order_recipe(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, false, NULL, NULL, NULL, NULL, r.route_key);
    CREATE TEMP TABLE _n AS SELECT * FROM pg_temp.rpc_bloom_order_recipe_t(r.store_code, r.delivery_date, r.next_delivery, NULL, NULL, NULL, false, NULL, NULL, NULL, NULL, r.route_key);
    SELECT COALESCE(sum(value) FILTER (WHERE suggested_packs > 0), 0), count(*) FILTER (WHERE suggested_packs > 0) INTO v_ov, v_ol FROM _o;
    SELECT COALESCE(sum(value) FILTER (WHERE suggested_packs > 0), 0), count(*) FILTER (WHERE suggested_packs > 0) INTO v_nv, v_nl FROM _n;
    SELECT count(*) FILTER (WHERE COALESCE(n.suggested_packs,0) > COALESCE(o.suggested_packs,0)),
           count(*) FILTER (WHERE COALESCE(n.suggested_packs,0) < COALESCE(o.suggested_packs,0)),
           count(*) FILTER (WHERE COALESCE(n.suggested_packs,0) = COALESCE(o.suggested_packs,0))
      INTO v_up, v_dn, v_same FROM _o o FULL JOIN _n n USING (product_code);
    INSERT INTO public.cc_scratch_b035_sim3b VALUES (r.store_code, r.route_key, r.delivery_date, r.next_delivery, v_soh, v_d, v_gap, v_ov, v_ol, v_nv, v_nl, v_up, v_dn, v_same);
    IF r.route_key LIKE 'DC\_%' THEN
      INSERT INTO public.cc_scratch_b035_sim3b_lines
        SELECT r.store_code, r.route_key, n.product_code, n.description, n.kvi_band, o.suggested_packs, n.suggested_packs, o.projected_soh, n.projected_soh,
               n.lead_days_used, v_d, n.rhythm_adjusted_demand, n.soh, n.story
          FROM _n n JOIN _o o USING (product_code)
         WHERE o.suggested_packs IS DISTINCT FROM n.suggested_packs
            OR n.product_code IN (SELECT product_code FROM _n WHERE suggested_packs > 0 ORDER BY value DESC LIMIT 8);
    END IF;
  END LOOP;
END
$sim$;
