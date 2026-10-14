-- =============================================================================
-- BLOOM-035 item 1b -- THE DC FRESH DESK (ENG-204; PM rulings B1-B3 of 13-10-2026, Pieter RULING 2026-09-10).
-- PHASE 0: every object that knows the DC route learns the route key 'DC_FRESH'. DORMANT BY CONSTRUCTION.
-- APPLIED 2026-10-14 12:0x UTC (migration bloom035_1b_dc_fresh_phase0); all 15 functions carry DC_FRESH afterwards (counted).
--
--   The fresh desk is a DC desk (it has no bloom_route_config row, so rpc_bloom_desks reads it as is_dc) whose
--   department set is bloom_dc_config.dc_fresh_dept_nrs, a column that is NULL until phase 1 derives it from the DC's
--   own receipts (R21, ruling B3). Until that column holds a value and a supplier_calendar row exists, no route is
--   'DC_FRESH' and every replacement below evaluates exactly as the text it replaced for DC_AMBIENT, DC_TOPS and every
--   DIRECT_* route. R22 proof: the stored orders of the existing desks are fingerprinted before and after (ENG-236 add.2
--   method) and must be identical per product.
--
--   WHAT EACH PATCH DOES (15 live functions, one asserted replace on each live definition):
--     rpc_bloom_order_recipe         route branch, department set, ledger route 'DC_FRESH', the two dynamic-SQL DC tests
--     refresh_l2_population_verdict  the desk's department set by route (v2.3 -> v2.4)
--     refresh_l2_received_placement  a DC-delivered product in a fresh department places on DC_FRESH, not on the ambient DC
--     rpc_bloom_route_benchmark      the benchmark basis is the desk's own department set
--     rpc_bloom_stock_state, rpc_bloom_link_verify, rpc_bloom_hidden_demand   the desk's department set by route
--     rpc_project_route_sales_budget, rpc_backtest_l2_sales_budget   the projection pool for DC_FRESH
--     refresh_l2_sales_budget        writes the DC_FRESH projection (its own ledger row, ENG-176 route grain)
--     refresh_order_budget_ledger_needs   ledger route 'DC_FRESH', its landed and in-transit pool, the DC strip no longer counts fresh
--     rpc_bloom_budget_context, rpc_bloom_delivery_budget, rpc_bloom_scenario_overview   ledger route 'DC_FRESH'
--     rpc_derive_placement_day       for DC_FRESH the placement weekdays are read from DC orders that carry a fresh-department line
--   NOT PATCHED, checked: refresh_bloom_order_cache and refresh_bloom_order_cache_all (route is a parameter, desks come from
--   supplier_calendar), rpc_bloom_next_deliveries and rpc_bloom_promo_for_delivery (is_dc by absence of a route_config row),
--   rpc_derive_order_cutoff (family 'DC', pairs from all DC orders), refresh_l2_on_order (fresh order lines already carry
--   delivery_population DC_OTHER; the latest-1 rule for them stands and is named in ENG-204 add.1),
--   refresh_order_budget_ledger() (no caller anywhere, legacy), rpc_bloom_order_dc (legacy), rpc_bloom_direct_dc_overlap.
--
--   Each target function is first pinned: if its live md5(prosrc) is not the one this file was written against, the
--   whole migration aborts and nothing is applied. Every replacement asserts its anchor count.
--   Also here: supplier_calendar_route_key_check admits 'DC_FRESH' (the switch would have failed on it).
-- REVERSE: swap the from/to of each replacement (the count assertions hold both ways), drop v_bloom_dc_fresh_pool and
--   bloom_desk_dept_nrs, drop column dc_fresh_dept_nrs, restore the old check. Pre-apply pins (prosrc md5:length):
--     rpc_bloom_order_recipe 132ebfe5:46094  refresh_l2_population_verdict 89dda58d:19902  refresh_l2_received_placement 46932f6c:7460
--     rpc_bloom_route_benchmark f1a115cf:2797  rpc_bloom_stock_state 512877e1:5500  rpc_bloom_link_verify c82739d7:5815
--     rpc_bloom_hidden_demand 073ff5ca:5545  rpc_project_route_sales_budget f87837d6:4788  rpc_backtest_l2_sales_budget 4c7b3804:2312
--     refresh_l2_sales_budget fb927639:2081  refresh_order_budget_ledger_needs 166bb49e:10583  rpc_bloom_budget_context d6603769:2222
--     rpc_bloom_delivery_budget a29bdc62:5328  rpc_bloom_scenario_overview fd429167:9739  rpc_derive_placement_day df5dcc39:4008
-- =============================================================================

CREATE FUNCTION pg_temp.rp(p_def text, p_from text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: anchor [%] found % time(s), expected %', p_what, left(p_from, 70), n, p_expect;
  END IF;
  RETURN replace(p_def, p_from, p_to);
END $f$;

CREATE FUNCTION pg_temp.rx(p_def text, p_pat text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM regexp_matches(p_def, p_pat, 'g');
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: pattern [%] found % time(s), expected %', p_what, left(p_pat, 70), n, p_expect;
  END IF;
  RETURN regexp_replace(p_def, p_pat, p_to, 'g');
END $f$;

-- ---------------------------------------------------------------- schema
-- a lock the pipeline holds must make this FAIL FAST, never queue behind it and block every reader of bloom_dc_config
SET lock_timeout = '5s';

ALTER TABLE public.bloom_dc_config ADD COLUMN IF NOT EXISTS dc_fresh_dept_nrs smallint[];
COMMENT ON COLUMN public.bloom_dc_config.dc_fresh_dept_nrs IS 'ENG-204 (BLOOM-035 item 1b). The DC fresh desk''s departments: the departments of the World 1 NORMAL products the DC delivered in desk_receipt_window_days that are not in dc_cycle_dept_nrs. DERIVED nightly by refresh_dc_fresh_desk (R21, PM ruling B3), never typed. NULL = no fresh desk at this store. Read through bloom_desk_dept_nrs(store, route).';

ALTER TABLE public.supplier_calendar DROP CONSTRAINT supplier_calendar_route_key_check;
ALTER TABLE public.supplier_calendar ADD CONSTRAINT supplier_calendar_route_key_check
  CHECK (route_key = ANY (ARRAY['DC_AMBIENT'::text, 'DC_TOPS'::text, 'DC_FRESH'::text, 'DIRECT_BEER'::text]) OR route_key LIKE 'DIRECT\_%' ESCAPE '\');

CREATE OR REPLACE VIEW public.v_bloom_dc_fresh_pool AS
 SELECT sp.store_code,
    sp.product_code,
    sp.department_nr,
    dc.format_group
   FROM l2_stock_position sp
     JOIN bloom_dc_config dc ON dc.store_code = sp.store_code AND dc.status = 'RULED'::text
  WHERE (sp.department_nr = ANY (dc.dc_fresh_dept_nrs)) AND sp.class = 'NORMAL'::text;
REVOKE ALL ON public.v_bloom_dc_fresh_pool FROM PUBLIC, anon;
GRANT SELECT ON public.v_bloom_dc_fresh_pool TO authenticated, service_role;
COMMENT ON VIEW public.v_bloom_dc_fresh_pool IS 'GRADE: RECOMMENDED. ENG-204. The DC fresh desk''s buy-and-sell pool: World-1 (class NORMAL) products in bloom_dc_config.dc_fresh_dept_nrs. ONE HOME, the sibling of v_bloom_dc_ambient_pool; budget, landed and in-transit all read it, never restate it.';

CREATE OR REPLACE FUNCTION public.bloom_desk_dept_nrs(p_store_code text, p_route text)
 RETURNS smallint[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $f$
  SELECT CASE WHEN p_route = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END
    FROM bloom_dc_config dc
   WHERE dc.store_code = p_store_code AND dc.status = 'RULED'
$f$;
REVOKE EXECUTE ON FUNCTION public.bloom_desk_dept_nrs(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bloom_desk_dept_nrs(text, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.bloom_desk_dept_nrs(text, text) IS 'GRADE: RECOMMENDED. ENG-204. The department set of a DC desk: dc_fresh_dept_nrs for DC_FRESH, dc_cycle_dept_nrs for the ambient DC route. ONE HOME for the by-route choice.';

-- ---------------------------------------------------------------- the asserted replaces
DO $mig$
DECLARE
  pin record;
  def text;
  v_live text;
BEGIN
  -- 0. the pins: abort on any function that moved since this file was written
  FOR pin IN SELECT * FROM (VALUES
    ('rpc_bloom_order_recipe',            '132ebfe5bab2338388fca124a345b432'),
    ('refresh_l2_population_verdict',     '89dda58d96ecdd199eeea9469c5baeda'),
    ('refresh_l2_received_placement',     '46932f6c223d04d934896bdbfb020c4a'),
    ('rpc_bloom_route_benchmark',         'f1a115cf749991296283a99ca8c71fea'),
    ('rpc_bloom_stock_state',             '512877e11e1371b3f5d00f9e0de512b0'),
    ('rpc_bloom_link_verify',             'c82739d70d8bf04b67bda7f66e94fc51'),
    ('rpc_bloom_hidden_demand',           '073ff5cadb347f5e2976a60465d2eede'),
    ('rpc_project_route_sales_budget',    'f87837d6a2ef43d3cbf21d7442758089'),
    ('rpc_backtest_l2_sales_budget',      '4c7b3804020c1b8b7b7abf331a2d4244'),
    ('refresh_l2_sales_budget',           'fb92763906706e4ca03d5da69ee79057'),
    ('refresh_order_budget_ledger_needs', '166bb49ea1ba17d781f43541acbc8910'),
    ('rpc_bloom_budget_context',          'd6603769e74a80da702deb6a061c84c9'),
    ('rpc_bloom_delivery_budget',         'a29bdc62caff92df5c292b35d250a003'),
    ('rpc_bloom_scenario_overview',       'fd429167f2b3a7fdf2996be7533050cd'),
    ('rpc_derive_placement_day',          'df5dcc39345f2551be7af3c0c98a1f8c')
  ) v(fn, md5pin) LOOP
    SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = pin.fn;
    IF v_live IS DISTINCT FROM pin.md5pin THEN
      RAISE EXCEPTION 'pin failed for %: live md5 % is not the pinned %', pin.fn, v_live, pin.md5pin;
    END IF;
  END LOOP;

  -- 1. rpc_bloom_order_recipe
  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  def := pg_temp.rp(def, $a$IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN$a$,
                         $b$IF p_route IN ('DC_AMBIENT','DC_TOPS','DC_FRESH') THEN$b$, 1, 'recipe route branch');
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs, dc.format_group INTO v_dept_nrs, v_format_group$a$,
                         $b$SELECT CASE WHEN p_route = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END, dc.format_group INTO v_dept_nrs, v_format_group$b$, 1, 'recipe dept set');
  def := pg_temp.rp(def, $a$WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'$a$,
                         $b$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
    WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'$b$, 1, 'recipe ledger route');
  def := pg_temp.rp(def, $a$%15$L::text IN ('DC_AMBIENT','DC_TOPS')$a$,
                         $b$%15$L::text IN ('DC_AMBIENT','DC_TOPS','DC_FRESH')$b$, 2, 'recipe dynamic DC tests');
  EXECUTE def;

  -- 2. refresh_l2_population_verdict (v2.3 -> v2.4)
  def := pg_get_functiondef('public.refresh_l2_population_verdict(text)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs INTO v_dept FROM bloom_dc_config dc$a$,
                         $b$SELECT CASE WHEN v_desk.route_key = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END INTO v_dept FROM bloom_dc_config dc$b$, 1, 'verdict dept set');
  def := pg_temp.rp(def, $a$population-verdict v2.3 (ENG-183 desk split, received-from, history, supplier column, A1 latest receipt decides)$a$,
                         $b$population-verdict v2.4 (ENG-183 desk split, received-from, history, supplier column, A1 latest receipt decides, ENG-204 DC fresh desk)$b$, 1, 'verdict label');
  EXECUTE def;

  -- 3. refresh_l2_received_placement
  def := pg_get_functiondef('public.refresh_l2_received_placement(text)'::regprocedure);
  def := pg_temp.rp(def, $a$WHERE pv.store_code = v_store AND pv.is_dc LIMIT 1$a$,
                         $b$WHERE pv.store_code = v_store AND pv.is_dc AND pv.route_key <> 'DC_FRESH' LIMIT 1$b$, 1, 'placement dcroute');
  def := pg_temp.rp(def, $a$dcdept AS (SELECT unnest(dc.dc_cycle_dept_nrs)::int AS d,$a$,
                         $b$freshdept AS (SELECT unnest(dc.dc_fresh_dept_nrs)::int AS d FROM bloom_dc_config dc WHERE dc.store_code = v_store AND dc.status = 'RULED'),
    dcdept AS (SELECT unnest(dc.dc_cycle_dept_nrs)::int AS d,$b$, 1, 'placement freshdept');
  def := pg_temp.rp(def, $a$CASE WHEN t.supplier_type = 'Z' THEN (SELECT route_key FROM dcroute)$a$,
                         $b$CASE WHEN t.supplier_type = 'Z' THEN (CASE WHEN sp.department_nr::int IN (SELECT d FROM freshdept) THEN 'DC_FRESH' ELSE (SELECT route_key FROM dcroute) END)$b$, 1, 'placement desk');
  def := pg_temp.rp(def, $a$It belongs on the DC fresh desk (ENG-204, ruled 10-09, not built).$a$,
                         $b$It is in no DC desk department set (the DC fresh desk takes the departments the DC delivered, ENG-204).$b$, 1, 'placement reason text');
  EXECUTE def;

  -- 4. rpc_bloom_route_benchmark
  def := pg_get_functiondef('public.rpc_bloom_route_benchmark(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT c.dc_cycle_dept_nrs INTO v_depts$a$,
                         $b$SELECT CASE WHEN p_route = 'DC_FRESH' THEN c.dc_fresh_dept_nrs ELSE c.dc_cycle_dept_nrs END INTO v_depts$b$, 1, 'benchmark dept set');
  EXECUTE def;

  -- 5. rpc_bloom_stock_state
  def := pg_get_functiondef('public.rpc_bloom_stock_state(text, text)'::regprocedure);
  def := pg_temp.rp(def, $a$p_route IN ('DC_AMBIENT','DC_TOPS')$a$,
                         $b$p_route IN ('DC_AMBIENT','DC_TOPS','DC_FRESH')$b$, 2, 'stock_state route tests');
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs$a$,
                         $b$SELECT CASE WHEN p_route = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END INTO v_dept_nrs$b$, 1, 'stock_state dept set');
  EXECUTE def;

  -- 6. rpc_bloom_link_verify
  def := pg_get_functiondef('public.rpc_bloom_link_verify(text, text)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs FROM public.bloom_dc_config dc$a$,
                         $b$SELECT CASE WHEN p_route = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END INTO v_dept_nrs FROM public.bloom_dc_config dc$b$, 1, 'link_verify dept set');
  EXECUTE def;

  -- 7. rpc_bloom_hidden_demand
  def := pg_get_functiondef('public.rpc_bloom_hidden_demand(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs$a$,
                         $b$SELECT CASE WHEN p_route = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END INTO v_dept_nrs$b$, 1, 'hidden_demand dept set');
  EXECUTE def;

  -- 8. rpc_project_route_sales_budget
  def := pg_get_functiondef('public.rpc_project_route_sales_budget(text, text, date, integer)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs$a$,
                         $b$SELECT CASE WHEN p_route_key = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END AS dc_cycle_dept_nrs$b$, 1, 'project dept set');
  def := pg_temp.rp(def, $a$p_route_key IN ('DC_AMBIENT', 'DC_TOPS')$a$,
                         $b$p_route_key IN ('DC_AMBIENT', 'DC_TOPS', 'DC_FRESH')$b$, 2, 'project route tests');
  EXECUTE def;

  -- 9. rpc_backtest_l2_sales_budget
  def := pg_get_functiondef('public.rpc_backtest_l2_sales_budget(text, text, date, integer)'::regprocedure);
  def := pg_temp.rp(def, $a$SELECT dc.dc_cycle_dept_nrs FROM bloom_dc_config dc$a$,
                         $b$SELECT CASE WHEN p_route_key = 'DC_FRESH' THEN dc.dc_fresh_dept_nrs ELSE dc.dc_cycle_dept_nrs END AS dc_cycle_dept_nrs FROM bloom_dc_config dc$b$, 1, 'backtest dept set');
  def := pg_temp.rp(def, $a$p_route_key IN ('DC_AMBIENT','DC_TOPS')$a$,
                         $b$p_route_key IN ('DC_AMBIENT','DC_TOPS','DC_FRESH')$b$, 2, 'backtest route tests');
  EXECUTE def;

  -- 10. refresh_l2_sales_budget: the DC fresh desk's own projection
  def := pg_get_functiondef('public.refresh_l2_sales_budget(text)'::regprocedure);
  def := pg_temp.rp(def, $a$RETURN jsonb_build_object('store_code', p_store_code, 'rows', v_rows, 'refreshed_at', now());$a$,
                         $b$-- BLOOM-035 1b (ENG-204): the DC fresh desk has its own projection, hence its own ledger row (ENG-176 route grain).
  -- Dormant until bloom_dc_config.dc_fresh_dept_nrs is populated.
  IF EXISTS (SELECT 1 FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED' AND dc.dc_fresh_dept_nrs IS NOT NULL) THEN
    INSERT INTO public.l2_sales_budget (
      client_id, store_code, route_key, budget_week_start, month_start,
      ly_base_cost, trend_factor, rhythm_seasonality_projected_cost, projected_sales_cost,
      products_in_pool, products_with_ly_history, anchor_date
    )
    SELECT 'socialbrand', p_store_code, 'DC_FRESH', r.budget_week_start, r.month_start,
      r.ly_base_cost, r.trend_factor, r.rhythm_seasonality_projected_cost, r.projected_sales_cost,
      r.products_in_pool, r.products_with_ly_history, CURRENT_DATE
    FROM rpc_project_route_sales_budget(p_store_code, 'DC_FRESH', CURRENT_DATE, 26) r;
    GET DIAGNOSTICS v_route_rows = ROW_COUNT;
    v_rows := v_rows + v_route_rows;
  END IF;

  RETURN jsonb_build_object('store_code', p_store_code, 'rows', v_rows, 'refreshed_at', now());$b$, 1, 'sales_budget fresh block');
  EXECUTE def;

  -- 11. refresh_order_budget_ledger_needs
  def := pg_get_functiondef('public.refresh_order_budget_ledger_needs(text)'::regprocedure);
  def := pg_temp.rp(def, $a$CASE WHEN sb.route_key LIKE 'DC\_%' ESCAPE '\' THEN 'DC'$a$,
                         $b$CASE WHEN sb.route_key = 'DC_FRESH' THEN 'DC_FRESH'
                WHEN sb.route_key LIKE 'DC\_%' ESCAPE '\' THEN 'DC'$b$, 1, 'needs ledger route');
  def := pg_temp.rp(def, $a$SELECT p.product_code FROM v_bloom_dc_ambient_pool p WHERE p.store_code = p_store),$a$,
                         $b$SELECT p.product_code FROM v_bloom_dc_ambient_pool p WHERE p.store_code = p_store),
  fpool AS (
    SELECT p.product_code FROM v_bloom_dc_fresh_pool p WHERE p.store_code = p_store),$b$, 1, 'needs fresh pool cte');
  def := pg_temp.rp(def, $a$AND m.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'$a$,
                         $b$AND m.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'
             WHEN sm.supplier_type = 'Z'
              AND m.product_code IN (SELECT product_code FROM fpool) THEN 'DC_FRESH'$b$, 1, 'needs landed fresh');
  def := pg_temp.rp(def, $a$AND o.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'$a$,
                         $b$AND o.product_code IN (SELECT product_code FROM dcpool) THEN 'DC'
             WHEN o.route_keys[1] = 'DC'
              AND o.product_code IN (SELECT product_code FROM fpool) THEN 'DC_FRESH'$b$, 1, 'needs transit fresh');
  def := pg_temp.rp(def, $a$OR NOT (sp.department_nr = ANY(dc.dc_cycle_dept_nrs))$a$,
                         $b$OR NOT (sp.department_nr = ANY(dc.dc_cycle_dept_nrs) OR sp.department_nr = ANY(COALESCE(dc.dc_fresh_dept_nrs, ARRAY[]::smallint[])))$b$, 2, 'needs strip excludes fresh');
  EXECUTE def;

  -- 12. rpc_bloom_budget_context
  def := pg_get_functiondef('public.rpc_bloom_budget_context(text, text, date)'::regprocedure);
  def := pg_temp.rx(def, $a$(WHEN p_desk = 'DIRECT_BEER'\s+THEN 'DIRECT_BEER')$a$,
                         $b$WHEN p_desk = 'DC_FRESH' THEN 'DC_FRESH'
             \1$b$, 1, 'budget_context ledger route');
  EXECUTE def;

  -- 13. rpc_bloom_delivery_budget
  def := pg_get_functiondef('public.rpc_bloom_delivery_budget(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$v_route := CASE WHEN p_route LIKE 'DC$a$,
                         $b$v_route := CASE WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
                  WHEN p_route LIKE 'DC$b$, 1, 'delivery_budget route');
  def := pg_temp.rp(def, $a$OR (v_route<>'DC' AND m.supplier_nr IN ($a$,
                         $b$OR (v_route='DC_FRESH' AND sm.supplier_type='Z'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_fresh_pool p
                          WHERE p.store_code=m.store_code AND p.product_code=m.product_code))
       OR (v_route NOT IN ('DC','DC_FRESH') AND m.supplier_nr IN ($b$, 1, 'delivery_budget landed');
  def := pg_temp.rp(def, $a$OR (v_route='DIRECT_BEER' AND o.route_keys[1]='DIRECT_BEER')$a$,
                         $b$OR (v_route='DC_FRESH' AND o.route_keys[1]='DC'
             AND EXISTS (SELECT 1 FROM v_bloom_dc_fresh_pool p
                          WHERE p.store_code=o.store_code AND p.product_code=o.product_code))
       OR (v_route='DIRECT_BEER' AND o.route_keys[1]='DIRECT_BEER')$b$, 1, 'delivery_budget transit');
  EXECUTE def;

  -- 14. rpc_bloom_scenario_overview
  def := pg_get_functiondef('public.rpc_bloom_scenario_overview(text, date, date, text, numeric, text[], boolean)'::regprocedure);
  def := pg_temp.rp(def, $a$p_route NOT IN ('DC_AMBIENT','DC_TOPS','DIRECT_BEER')$a$,
                         $b$p_route NOT IN ('DC_AMBIENT','DC_TOPS','DC_FRESH','DIRECT_BEER')$b$, 1, 'scenario route check');
  def := pg_temp.rp(def, $a$AND obl.route_key = (CASE$a$,
                         $b$AND obl.route_key = (CASE
        WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'$b$, 1, 'scenario ledger route');
  EXECUTE def;

  -- 15. rpc_derive_placement_day: for DC_FRESH the placement weekdays come from DC orders that carry a fresh-department line
  def := pg_get_functiondef('public.rpc_derive_placement_day(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$AND NOT EXISTS (SELECT 1 FROM bloom_route_config dr WHERE dr.store_code = o.store_code AND o.supplier_nr = ANY(dr.direct_supplier_nrs))$a$,
                         $b$AND NOT EXISTS (SELECT 1 FROM bloom_route_config dr WHERE dr.store_code = o.store_code AND o.supplier_nr = ANY(dr.direct_supplier_nrs))
       AND (p_route_key <> 'DC_FRESH'
            OR EXISTS (SELECT 1 FROM sigma_order_lines ol
                         JOIN sigma_articles oa ON oa.store_code = ol.store_code AND oa.product_code = ol.product_code
                        WHERE ol.store_code = o.store_code AND ol.order_nr = o.order_nr
                          AND oa.department_nr = ANY(public.bloom_desk_dept_nrs(o.store_code, p_route_key))))$b$, 1, 'placement_day fresh filter');
  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
