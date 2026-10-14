-- =============================================================================
-- BLOOM-035 item 2 -- THE FIT IS ON FOR EVERY DESK, TO THAT DESK'S OWN NEED (R1, Pieter 13-10-2026 15:04: "yes for every desk individually").
--   Brief acceptance: each desk's stored order totals no more than its own need for the delivery week, with the protected set whole, both values
--   read back on the live desk. The desk opens on the fitted order (src/app/bloom/page.jsx, the one state default).
--
--   WHAT WAS WRONG (measured 14-10-2026, stored fitted orders against the ledger): the ledger grain is not the desk. Every DIRECT desk read the ONE pooled
--   row 'DIRECT' as its own need (ENG-176 add.1, ruled 10-09, "the ledger grain is the route"). At 10116 the six brand desks and the 66 derived desks all fitted
--   to the same R110,821 week.
--
--   SIMULATED BEFORE APPLY (pure read, sql/_sim_item2_route_grain.sql, 28 desks: every hand-typed DIRECT desk, the six largest derived desks at 10116 and 80175;
--   committed spend left out, so a desk with spend already landed this week has less in practice): 16 orders do not move, 8 move by -1 to -9%, DIRECT_S80 at
--   80175 +8%, DIRECT_SIMBA at 10116 +14% (the pooled row was negative that day, so it had no budget at all), and two move a lot: DIRECT_S1863 -61%
--   (R13,452 to R5,290) and DIRECT_S3176 -38% (R123,545 to R76,394, the protected lines alone are R75,216 against an own need of R11,362).
--
--   WHAT THIS CHANGES: one rule everywhere a route is mapped to its ledger row. DC_AMBIENT and DC_TOPS read 'DC' (one DC desk per store), every other
--   route reads ITSELF (DC_FRESH, DIRECT_BEER, DIRECT_CATCHALL and now every DIRECT_<brand> and DIRECT_S<supplier>).
--     recipe                   v_ledger_route of a DIRECT desk is the route itself.
--     refresh_l2_sales_budget  the derived DIRECT_S desks are projected again (the skip of bloom035_1b_sales_budget_skip_derived_direct is removed).
--     ledger needs             need, landed and in transit per route. The pooled row 'DIRECT' is no longer written: its weeks to 2026-10-10 stay as
--                              history (R28 retired_on 2026-10-14, successor the per-route rows).
--     budget context, delivery budget, scenario overview, month projection   the same mapping.
--
--   WHAT THIS DOES NOT CHANGE, ON PURPOSE. The fit floor stays what ORDERING-CANON-BUDGETS section D says: HERO and KVI to their floor plus the
--   minimum-presence pack, "funded first, never trimmed"; where the floor alone exceeds the need it is a SURFACED over-budget line ("floors protected, +R"),
--   which the desk already shows (page.jsx, overRail). A simulation of 14-10 (sql/_sim_item2_fit_floors.sql) shows what the acceptance would cost if every
--   non-protected floor yielded: 10116 DC ambient R539,802 to R449,481 (the need R449,705), 335 lines fewer. That is a ruling on min-presence, not a fix.
--   Each patched function is pinned on its live md5; every replacement asserts its anchor count.
-- REVERSE: swap the from/to of each replacement (counts hold both ways), restore the DIRECT_S skip predicate in refresh_l2_sales_budget.
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

SET lock_timeout = '5s';

DO $mig$
DECLARE
  pin record;
  def text;
  v_live text;
BEGIN
  FOR pin IN SELECT * FROM (VALUES
    ('rpc_bloom_order_recipe',            'c6dfd1494ef0609a5154645483c7f2e8'),
    ('refresh_l2_sales_budget',           '4dd74700ff11e072e27743a8a301a770'),
    ('refresh_order_budget_ledger_needs', 'cc1b86bcdbbda26d330de11e0bdba4ac'),
    ('rpc_bloom_budget_context',          '74d861fc12ece3662827bf031b10a8a4'),
    ('rpc_bloom_delivery_budget',         'ea1ad8401f81a2b853e8d5b86df5535d'),
    ('rpc_bloom_scenario_overview',       '248aa4159fcf44e61b86fc522dcc2d62'),
    ('rpc_bloom_month_projection',        'c61094b4d3b5067be4111504d767182f')
  ) v(fn, md5pin) LOOP
    SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = pin.fn;
    IF v_live IS DISTINCT FROM pin.md5pin THEN
      RAISE EXCEPTION 'pin failed for %: live md5 % is not the pinned %', pin.fn, v_live, pin.md5pin;
    END IF;
  END LOOP;

  -- 1. the recipe: (a) the ledger route of a DIRECT desk is the route itself, (b) the fit budget is the need of the budget weeks the delivery COVERS
  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$a$,
                         $b$WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN p_route$b$, 1, 'recipe ledger route');
  -- (b) one week's remaining need was the budget of every delivery. A desk that delivers every second or third week orders for the whole cycle, so its
  --     budget is the remaining need of the ceil(gap in days / 7) weeks from the delivery week. For a gap of 7 days or less that is ONE week: byte-identical for
  --     every DC desk and every weekly desk (R22), more only where the cycle is longer (Mondelez, National Brands and the derived desks on a long cycle).
  def := pg_temp.rp(def, $a$SELECT COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0) INTO v_weekly_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key=v_ledger_route AND obl.grain='weekly'
    AND obl.year_month = v_week_start;$a$,
                         $b$SELECT COALESCE(SUM(COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0)), 0) INTO v_weekly_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key=v_ledger_route AND obl.grain='weekly'
    AND obl.year_month >= v_week_start
    AND obl.year_month < v_week_start + 7 * GREATEST(1, CEIL((v_next_delivery - p_delivery_date) / 7.0))::int;$b$, 1, 'recipe fit budget covers the cycle');
  EXECUTE def;

  -- 2. the budget projection: the derived desks have a ledger row of their own now
  def := pg_get_functiondef('public.refresh_l2_sales_budget(text)'::regprocedure);
  def := pg_temp.rx(def, $a$\n\s+AND rc\.route_key !~ '\^DIRECT_S\[0-9\]\+\$'[^\n]*$a$, '', 1, 'sales_budget derived skip');
  EXECUTE def;

  -- 3. the ledger needs: need, landed and in transit per route
  def := pg_get_functiondef('public.refresh_order_budget_ledger_needs(text)'::regprocedure);
  def := pg_temp.rp(def, $a$ELSE 'DIRECT' END AS ledger_route,$a$, $b$ELSE sb.route_key END AS ledger_route,$b$, 1, 'needs ledger route');
  def := pg_temp.rp(def, $a$WHERE store_code=p_store AND route_key='DIRECT_CATCHALL'),$a$,
                         $b$WHERE store_code=p_store AND route_key='DIRECT_CATCHALL'),
  direct_map AS MATERIALIZED (
    SELECT DISTINCT ON (x.supplier_nr) x.route_key, x.supplier_nr
      FROM (SELECT rc.route_key, unnest(rc.direct_supplier_nrs) AS supplier_nr FROM bloom_route_config rc
             WHERE rc.store_code=p_store AND rc.route_key LIKE 'DIRECT\_%' ESCAPE '\'
               AND rc.route_key NOT IN ('DIRECT_BEER', 'DIRECT_CATCHALL')) x
     ORDER BY x.supplier_nr, x.route_key),$b$, 1, 'needs direct_map cte');
  def := pg_temp.rp(def, $a$WHEN m.supplier_nr IN (SELECT supplier_nr FROM direct) THEN 'DIRECT'$a$,
                         $b$WHEN m.supplier_nr IN (SELECT supplier_nr FROM direct_map)
              THEN (SELECT dm.route_key FROM direct_map dm WHERE dm.supplier_nr = m.supplier_nr)$b$, 1, 'needs landed');
  def := pg_temp.rp(def, $a$WHEN o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$a$,
                         $b$WHEN o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\' THEN o.route_keys[1]$b$, 1, 'needs transit');
  EXECUTE def;

  -- 4. the budget context
  def := pg_get_functiondef('public.rpc_bloom_budget_context(text, text, date)'::regprocedure);
  def := pg_temp.rx(def, $a$(WHEN p_desk LIKE 'DIRECT\\_%' ESCAPE '\\'\s+THEN) 'DIRECT'$a$, $b$\1 p_desk$b$, 1, 'budget_context ledger route');
  EXECUTE def;

  -- 5. the delivery budget
  def := pg_get_functiondef('public.rpc_bloom_delivery_budget(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$ELSE 'DIRECT' END;$a$, $b$ELSE p_route END;$b$, 1, 'delivery_budget route');
  def := pg_temp.rp(def, $a$OR (v_route='DIRECT_CATCHALL' AND rc.route_key='DIRECT_CATCHALL') ) )) );$a$,
                         $b$OR (v_route='DIRECT_CATCHALL' AND rc.route_key='DIRECT_CATCHALL')
                    OR (v_route LIKE 'DIRECT\_%' ESCAPE '\' AND rc.route_key = v_route) ) )) );$b$, 1, 'delivery_budget landed');
  def := pg_temp.rp(def, $a$OR (v_route='DIRECT_CATCHALL' AND o.route_keys[1]='DIRECT_CATCHALL') );$a$,
                         $b$OR (v_route='DIRECT_CATCHALL' AND o.route_keys[1]='DIRECT_CATCHALL')
       OR (v_route LIKE 'DIRECT\_%' ESCAPE '\' AND o.route_keys[1] = v_route) );$b$, 1, 'delivery_budget transit');
  EXECUTE def;

  -- 6. the scenario overview
  def := pg_get_functiondef('public.rpc_bloom_scenario_overview(text, date, date, text, numeric, text[], boolean)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$a$,
                         $b$WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN p_route$b$, 1, 'scenario ledger route');
  EXECUTE def;

  -- 7. the month projection (a reader missed in phase 0 of item 1b: its CASE knew neither DC_FRESH nor the route grain)
  def := pg_get_functiondef('public.rpc_bloom_month_projection(text, text)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$a$,
                         $b$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
    WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN p_route$b$, 1, 'month_projection ledger route');
  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
