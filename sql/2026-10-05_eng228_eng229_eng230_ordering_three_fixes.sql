-- =====================================================================================================
-- ENG-228 / ENG-229 / ENG-230: the three ordering fixes (PM notes four, five and six, BUG-LOG 24-09 and 05-10-2026)
-- CC, 2026-10-05. ONE migration, three fixes, each tested on its own on scratch copies before this was applied.
--
--   ENG-228  refresh_l2_on_order: a line expires only after the ledger has seen the FIRST DELIVERY DAY on or after
--            its promise (supplier_calendar), not when the watermark reaches the promised date. The label and the
--            exclusion now read one expression. (PM note four, 24-09: Tuesday's promotion orders were dropped as stale
--            on a Wednesday that is not a delivery day, and Saturday's order was not reduced by them.)
--   ENG-229  rpc_bloom_order_recipe, CTE packs (and its geared twin): a minimum-mode line rounds UP to the whole pack
--            that reaches its own min band. The 35-day ceiling and the minimum-presence exemption still cap it
--            downstream. (PM note five, 24-09: 72 lines closed below their own min band, 65 of them by rounding down.)
--   ENG-230  rpc_bloom_order_recipe, the TEMPORARY 3-unit floor (Pieter, 05-10-2026, twice corrected by him the same day):
--            a line whose position after the suggestion is 3 units or fewer gets at least one pack when one pack sells
--            within 28 days (pack_size / rate of sale <= 28). A pack that takes longer goes to keep-or-delist and is
--            never auto-bought. HERO, CORE and SLOW are all inside it. l2_bt_tail DERANGE is out. It only ever ADDS a
--            pack. forge_config temp_floor_units = 3 and temp_floor_pack_days = 28, DEMO_CALIBRATION, effective
--            2026-10-05, retire them when the band is ruled (R28 lineage). The 0.02 and 0.2 rate-of-sale thresholds of
--            the sixth note were withdrawn by Pieter and never stored.
--   NOT CHANGED: the safety days, the band formula, the promo uplift and the buy-in tools (Pieter has not ruled).
--
-- HOW IT PATCHES. The live bodies are 45,339 and 10,042 characters and have been rewritten many times, so this does not
-- restate them. It reads the live definition, asserts its md5 is the one tested, replaces each fragment (every
-- replacement asserted to match EXACTLY ONCE) and executes the result. Anything moved underneath it aborts the
-- transaction and nothing changes.
--   expected pre-state:  rpc_bloom_order_recipe   b9ad7495f1429a4a06325bdc8951cb83  (45,339 chars)
--                        refresh_l2_on_order      d6655346f5d8c6cf889161fbbc031b7c  (10,042 chars)
-- No signature, return type, grant or owner changes. No table is altered.
--
-- ROLLBACK: the pre-state of both functions is stashed in public.cc_fn_prestate (below). To restore:
--   DO $r$ BEGIN
--     EXECUTE (SELECT def FROM public.cc_fn_prestate WHERE fn = 'rpc_bloom_order_recipe' ORDER BY stashed_at LIMIT 1);
--     EXECUTE (SELECT def FROM public.cc_fn_prestate WHERE fn = 'refresh_l2_on_order'    ORDER BY stashed_at LIMIT 1);
--     UPDATE public.forge_config SET retired_on = CURRENT_DATE WHERE config_key IN ('temp_floor_units','temp_floor_pack_days');
--   END $r$;
-- then rebuild the caches. Retiring the two forge_config rows alone switches the floor off without touching a function.
-- =====================================================================================================

-- 0. the pre-state, kept for rollback
CREATE TABLE IF NOT EXISTS public.cc_fn_prestate (
  fn text NOT NULL, md5 text NOT NULL, def text NOT NULL, stashed_at timestamptz NOT NULL DEFAULT now(), note text,
  PRIMARY KEY (fn, md5));
ALTER TABLE public.cc_fn_prestate ENABLE ROW LEVEL SECURITY;   -- no policy: nothing but the owner reads it

-- 1. Pieter's two temporary numbers (R28: his, not derived)
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, retired_on, notes) VALUES
 ('temp_floor_units', '*', 3, 'DEMO_CALIBRATION', DATE '2026-10-05', NULL,
  'ENG-230 TEMPORARY floor, Pieter 05-10-2026 (PM note six): a line whose position after the suggestion is at or under this many units gets at least one pack, when one pack sells within temp_floor_pack_days. His number, not derived. Retire when the band is ruled.'),
 ('temp_floor_pack_days', '*', 28, 'DEMO_CALIBRATION', DATE '2026-10-05', NULL,
  'ENG-230 TEMPORARY floor, Pieter 05-10-2026 (second correction to PM note six): "1 pack sold for 4 weeks is ordered if the lines with 3 units on the floor, longer than 4 weeks to sell one pack is flagged for deletion". 28 days, canon relevant_min_cover_days is 60 for SLOW. Replaces the withdrawn temp_floor_min_ros (0.02, then 0.2), which was never stored. Retire when the band is ruled.')
ON CONFLICT (config_key, store_format) DO NOTHING;

-- 2. the patch helpers (scratch, dropped at the end)
CREATE OR REPLACE FUNCTION public.cc_eng228_rep(p_text text, p_old text, p_new text, p_label text)
RETURNS text LANGUAGE plpgsql AS $cc$
DECLARE n int;
BEGIN
  n := (length(p_text) - length(replace(p_text, p_old, ''))) / greatest(length(p_old), 1);
  IF n <> 1 THEN
    RAISE EXCEPTION 'cc_eng228_rep(%): expected exactly 1 occurrence, found %', p_label, n;
  END IF;
  RETURN replace(p_text, p_old, p_new);
END $cc$;

CREATE OR REPLACE FUNCTION public.cc_eng228_patch_on_order(p_def text, p_apply boolean, p_sfx text DEFAULT NULL, p_table text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $cc$
DECLARE t text := p_def;
BEGIN
  IF p_apply THEN
    t := cc_eng228_rep(t, $o$  judged AS (
    SELECT p.*,$o$, $n$  open_cal AS (   -- ENG-228 (PM note four, 24-09-2026): the first delivery day on or after the promise, read from supplier_calendar
    SELECT p.*,
      (CASE
         WHEN p.expected_grv_date IS NULL OR p.expected_grv_date = DATE '1990-01-01' OR p.expected_grv_date < p.order_date THEN NULL
         ELSE COALESCE(
                (SELECT min(g::date)
                   FROM supplier_calendar sc
                   CROSS JOIN LATERAL generate_series(p.expected_grv_date::timestamp, (p.expected_grv_date + 6)::timestamp, interval '1 day') g
                  WHERE sc.store_code = p.store_code
                    AND sc.route_key = (CASE WHEN p.route_key = 'DC'
                                             THEN (CASE WHEN p.delivery_population = 'DC_AMBIENT'
                                                         THEN (SELECT CASE WHEN dc.format_group = 'TOPS' THEN 'DC_TOPS' ELSE 'DC_AMBIENT' END
                                                                 FROM bloom_dc_config dc WHERE dc.store_code = p.store_code AND dc.status = 'RULED' LIMIT 1)
                                                    END)
                                             ELSE p.route_key END)
                    AND COALESCE(sc.cycle_weeks, 1) = 1
                    AND EXTRACT(ISODOW FROM g)::smallint = ANY(sc.delivery_dows)),
                p.expected_grv_date)
       END) AS first_delivery_day
    FROM open_pool p
  ),
  judged AS (
    SELECT p.*,$n$, 'a1 open_cal');
    t := cc_eng228_rep(t, $o$    FROM open_pool p
  ),
  lines AS ($o$, $n$    FROM open_cal p
  ),
  lines AS ($n$, 'a2 judged source');
    t := cc_eng228_rep(t, $o$WHEN p.expected_grv_date <= v_watermark THEN 'promise_passed_ledger_observed'$o$,
                          $n$WHEN p.first_delivery_day <= v_watermark THEN 'promise_passed_ledger_observed'$n$, 'a3 exclusion');
    t := cc_eng228_rep(t, $o$WHEN p.expected_grv_date <  v_watermark   THEN 'promise_passed_ledger_observed'$o$,
                          $n$WHEN p.first_delivery_day <= v_watermark   THEN 'promise_passed_ledger_observed'$n$, 'a4 label passed');
    t := cc_eng228_rep(t, $o$WHEN p.expected_grv_date =  v_watermark   THEN 'promise_due_on_watermark_not_received'$o$,
                          $n$WHEN p.expected_grv_date <= v_watermark   THEN 'promise_awaiting_first_delivery_day'$n$, 'a5 label awaiting');
    t := cc_eng228_rep(t, $o$'engine_version', 'l2_on_order v17 E2.1 + ENG-188 landing estimate expires'$o$,
                          $n$'engine_version', 'l2_on_order v18 ENG-228 first delivery day (v17 E2.1 + ENG-188 kept)'$n$, 'a6 version return');
    t := cc_eng228_rep(t, $o$'l2_on_order v17 E2.1 + ENG-188 landing estimate expires'$o$,
                          $n$'l2_on_order v18 ENG-228 first delivery day (v17 E2.1 + ENG-188 kept)'$n$, 'a7 version insert');
  END IF;
  IF p_sfx IS NOT NULL THEN
    t := cc_eng228_rep(t, $o$CREATE OR REPLACE FUNCTION public.refresh_l2_on_order(p_store text)$o$,
                          'CREATE OR REPLACE FUNCTION public.cc_t_oo_' || p_sfx || '(p_store text)', 't1 name');
    t := replace(t, 'l2_on_order', p_table);
  END IF;
  RETURN t;
END $cc$;

CREATE OR REPLACE FUNCTION public.cc_eng228_patch_recipe(p_def text, p_b boolean, p_c boolean, p_sfx text DEFAULT NULL, p_oo_table text DEFAULT NULL, p_const_cfg boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql AS $cc$
DECLARE t text := p_def;
BEGIN
  IF p_b THEN
    t := cc_eng228_rep(t, $o$WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)$o$,
$n$WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1,
                   -- ENG-229 (PM note five, 24-09-2026): a minimum-mode line must reach its own min band, so round UP to the whole pack that reaches it.
                   -- The 35-day ceiling and the minimum-presence exemption still cap it downstream, in packs_ceiled.
                   (CASE WHEN n.mode = 'minimum' AND n.proj < n.min_band_ot THEN CEIL((n.min_band_ot - n.proj) / n.ps)::int ELSE 0 END))$n$, 'b1 packs');
    t := cc_eng228_rep(t, $o$WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1)$o$,
$n$WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1,
                   (CASE WHEN g.mode = 'minimum' AND g.proj_geared < g.min_band_ot THEN CEIL((g.min_band_ot - g.proj_geared) / g.ps)::int ELSE 0 END))$n$, 'b2 geared');
  END IF;

  IF p_c THEN
    t := cc_eng228_rep(t, $o$  v_payday_dom int;
BEGIN$o$, $n$  v_payday_dom int;
  v_tf_units numeric;
  v_tf_pack_days numeric;
BEGIN$n$, 'c1 declare');
    IF p_const_cfg THEN
      t := cc_eng228_rep(t, $o$  v_relevant_min_cover_days := COALESCE(v_relevant_min_cover_days, 60);$o$,
$n$  v_relevant_min_cover_days := COALESCE(v_relevant_min_cover_days, 60);
  v_tf_units := 3; v_tf_pack_days := 28;   -- TEST COPY: constants$n$, 'c2 cfg const');
    ELSE
      t := cc_eng228_rep(t, $o$  v_relevant_min_cover_days := COALESCE(v_relevant_min_cover_days, 60);$o$,
$n$  v_relevant_min_cover_days := COALESCE(v_relevant_min_cover_days, 60);

  -- ENG-230 (PM note six and its second correction, 05-10-2026): Pieter's TEMPORARY floor. Both numbers are Pieter's, not derived (R28, DEMO_CALIBRATION).
  -- Retire either forge_config row and the floor cannot fire.
  SELECT fc.value_num INTO v_tf_units FROM forge_config fc
  WHERE fc.config_key = 'temp_floor_units' AND fc.store_format = '*' AND fc.retired_on IS NULL LIMIT 1;
  SELECT fc.value_num INTO v_tf_pack_days FROM forge_config fc
  WHERE fc.config_key = 'temp_floor_pack_days' AND fc.store_format = '*' AND fc.retired_on IS NULL LIMIT 1;
  IF v_tf_units IS NULL OR v_tf_pack_days IS NULL THEN
    v_tf_units := -1000000000; v_tf_pack_days := 0;
  END IF;$n$, 'c2 cfg live');
    END IF;
    t := cc_eng228_rep(t, $o$p_max_order_stock_days, v_relevant_min_cover_days);$o$,
                          $n$p_max_order_stock_days, v_relevant_min_cover_days, v_tf_units, v_tf_pack_days);$n$, 'c3 args');
    t := cc_eng228_rep(t, $o$    packs_ceiled AS (
      SELECT m.*,$o$, $n$    packs_ceiled0 AS (
      SELECT m.*,$n$, 'c4 rename');
    t := cc_eng228_rep(t, $o$m.first_pack_over_ceiling) AS min_presence_forced,$o$,
                          $n$m.first_pack_over_ceiling) AS min_presence_forced0,$n$, 'c5a');
    t := cc_eng228_rep(t, $o$(m.slow_candidate AND NOT m.pack_relevant) AS keep_or_delist,$o$,
                          $n$(m.slow_candidate AND NOT m.pack_relevant) AS keep_or_delist0,$n$, 'c5b');
    t := cc_eng228_rep(t, $o$         END)::int AS normal_packs_calc
      FROM packs_mp m
    ),
    gear_source AS ($o$, $n$         END)::int AS normal_packs_calc0
      FROM packs_mp m
    ),
    packs_ceiled AS (
      -- ENG-230: the temporary 3-unit floor. Position after the suggestion is the projected position plus the packs suggested.
      -- A line with no pack and a position at or under the floor gets one pack when one pack sells within the pack-day limit,
      -- otherwise it goes to keep-or-delist and is never bought. HERO, CORE and SLOW all sit inside it. DERANGE in the
      -- Bonnie Tyler tail is out. It only ever adds a pack, it never removes one canon already gave.
      SELECT c.*,
        (CASE WHEN c.tf_pack_hit THEN 1 ELSE c.normal_packs_calc0 END)::int AS normal_packs_calc,
        (c.keep_or_delist0 OR c.tf_delist) AS keep_or_delist,
        (c.min_presence_forced0 OR (c.tf_pack_hit AND c.first_pack_over_ceiling)) AS min_presence_forced
      FROM (
        SELECT d.*,
          COALESCE(d.tf_cand AND d.ps / NULLIF(d.ros_final,0) <= %31$s, false) AS tf_pack_hit,
          COALESCE(d.tf_cand AND d.ps / NULLIF(d.ros_final,0) >  %31$s, false) AS tf_delist
        FROM (
          SELECT c0.*,
            (%8$L IS NULL AND c0.ros_final > 0 AND c0.range_state IN ('HERO','CORE','SLOW')
               AND c0.normal_packs_calc0 = 0 AND NOT c0.keep_or_delist0
               AND c0.proj <= %30$s
               AND NOT EXISTS (SELECT 1 FROM l2_bt_tail bt
                                WHERE bt.store_code = %1$L AND bt.product_code = c0.product_code AND bt.action_bucket = 'DERANGE')
            ) AS tf_cand
          FROM packs_ceiled0 c0
        ) d
      ) c
    ),
    gear_source AS ($n$, 'c5c new cte');
    t := cc_eng228_rep(t, $o$SELECT g.*,
        (CASE
           WHEN g.geared_packs_raw < 1 THEN g.geared_packs_raw$o$, $n$SELECT g.*,
        GREATEST(CASE WHEN g.tf_pack_hit THEN 1 ELSE 0 END, (CASE
           WHEN g.geared_packs_raw < 1 THEN g.geared_packs_raw$n$, 'c6a geared floor open');
    t := cc_eng228_rep(t, $o$         END)::int AS geared_packs_calc$o$, $n$         END))::int AS geared_packs_calc$n$, 'c6b geared floor close');
    t := cc_eng228_rep(t, $o$WHEN b.resolved_packs_calc >= 1 AND (b.mp_life OR (b.slow_candidate AND b.pack_relevant)) THEN 1$o$,
                          $n$WHEN b.resolved_packs_calc >= 1 AND (b.mp_life OR (b.slow_candidate AND b.pack_relevant) OR b.tf_pack_hit) THEN 1$n$, 'c7 fit floor');
    t := cc_eng228_rep(t, $o$packs%%s%%s%%s%%s%%s%%s',$o$, $n$packs%%s%%s%%s%%s%%s%%s%%s',$n$, 'c8a story fmt');
    t := cc_eng228_rep(t, $o$ROUND(pk.ps/NULLIF(pk.ros_final,0),0), %29$s) ELSE '' END) AS story$o$,
$n$ROUND(pk.ps/NULLIF(pk.ros_final,0),0), (CASE WHEN pk.tf_delist THEN %31$s ELSE %29$s END)) ELSE '' END,
        CASE WHEN pk.tf_pack_hit THEN format(' | TEMP_FLOOR (Pieter, 05-10-2026): position after the suggestion %%s units, floor %%s, one pack = %%s days cover, within %%s, one pack ordered', ROUND(pk.proj,1), %30$s, ROUND(pk.ps/NULLIF(pk.ros_final,0),0), %31$s) ELSE '' END) AS story$n$, 'c8b story');
  END IF;

  IF p_sfx IS NOT NULL THEN
    t := cc_eng228_rep(t, $o$CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe($o$,
                          'CREATE OR REPLACE FUNCTION public.cc_t_recipe_' || p_sfx || '(', 't1 name');
    IF p_oo_table IS NOT NULL THEN
      t := cc_eng228_rep(t, $o$LEFT JOIN l2_on_order oo$o$, 'LEFT JOIN ' || p_oo_table || ' oo', 't2 oo join');
      t := cc_eng228_rep(t, $o$FROM l2_on_order t$o$, 'FROM ' || p_oo_table || ' t', 't3 oo surfacing');
    END IF;
  END IF;
  RETURN t;
END $cc$;

-- 3. apply, gated on the tested pre-state, with the pre-state stashed first
DO $apply$
DECLARE
  r_sig regprocedure := 'public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric)'::regprocedure;
  o_sig regprocedure := 'public.refresh_l2_on_order(text)'::regprocedure;
  r_def text := pg_get_functiondef(r_sig);
  o_def text := pg_get_functiondef(o_sig);
BEGIN
  IF md5(r_def) <> 'b9ad7495f1429a4a06325bdc8951cb83' THEN
    RAISE EXCEPTION 'rpc_bloom_order_recipe is not the tested pre-state (md5 %), refusing', md5(r_def);
  END IF;
  IF md5(o_def) <> 'd6655346f5d8c6cf889161fbbc031b7c' THEN
    RAISE EXCEPTION 'refresh_l2_on_order is not the tested pre-state (md5 %), refusing', md5(o_def);
  END IF;
  INSERT INTO public.cc_fn_prestate (fn, md5, def, note) VALUES
    ('rpc_bloom_order_recipe', md5(r_def), r_def, 'pre ENG-229 and ENG-230, 05-10-2026'),
    ('refresh_l2_on_order',    md5(o_def), o_def, 'pre ENG-228, 05-10-2026')
  ON CONFLICT (fn, md5) DO NOTHING;
  EXECUTE public.cc_eng228_patch_on_order(o_def, true);
  EXECUTE public.cc_eng228_patch_recipe(r_def, true, true);
END $apply$;

-- 4. the helpers were scratch
DROP FUNCTION IF EXISTS public.cc_eng228_patch_recipe(text, boolean, boolean, text, text, boolean);
DROP FUNCTION IF EXISTS public.cc_eng228_patch_on_order(text, boolean, text, text);
DROP FUNCTION IF EXISTS public.cc_eng228_rep(text, text, text, text);
