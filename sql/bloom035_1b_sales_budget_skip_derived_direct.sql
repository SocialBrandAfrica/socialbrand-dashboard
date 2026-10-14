-- =============================================================================
-- BLOOM-035 item 1 side effect, found 14-10-2026 while proving item 1b: the derived desks must stay out of the pooled DIRECT budget.
--
--   refresh_l2_sales_budget projects every RULED bloom_route_config route, and the 119 DIRECT_S<supplier> desks item 1 created are RULED routes.
--   refresh_order_budget_ledger_needs pools every non-beer direct route into the ONE ledger row 'DIRECT'. Measured at 10116, week of 10-10
--   (l2_sales_budget, projected_sales_cost): that row's need would go from R117,371 (6 routes) to R214,400 (72 routes), +83%, and the six desks
--   that read it (Coca-Cola, Clover, Simba, Danone, National Brands, Mondelez) fit their orders to the new figure. R22 broken for desks that must not move.
--   It would also add about 7 minutes per large store to the nightly pipeline (refresh_l2_sales_budget('10116') took 422 s with 74 routes, about 60 s with 8).
--
--   Until the ledger grain is the route (ENG-176 add.1, ruled 10-09, unbuilt) the derived desks stay out of the budget projection, as they were out of it
--   until the first full pipeline after 08:10 on 14-10. They read the pooled DIRECT row exactly as before.
--   Asserted replace on the live definition, pinned on the live md5 (12f38491c53bbe562158a10e83eb282f, the definition after bloom035_1b_dc_fresh_phase0).
--   PROVEN: refresh_l2_sales_budget then refresh_order_budget_ledger_needs run for 10116 and 80175 on 14-10 12:33 UTC: the weekly budget fingerprints of the
--   ledger routes DC, DIRECT and ALL are identical before and after at both stores, and 26 new DC_FRESH weekly rows appear at each.
-- REVERSE: delete the added predicate line. A decision for PM: the route-grain ledger (ENG-176) is what lets these desks have a budget of their own.
-- =============================================================================

DO $mig$
DECLARE
  def text; v_live text; n int; a text;
BEGIN
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'refresh_l2_sales_budget';
  IF v_live IS DISTINCT FROM '12f38491c53bbe562158a10e83eb282f' THEN RAISE EXCEPTION 'pin failed: live md5 % is not 12f38491', v_live; END IF;
  def := pg_get_functiondef('public.refresh_l2_sales_budget(text)'::regprocedure);
  a := $a$WHERE rc.store_code = p_store_code AND rc.status = 'RULED'$a$;
  n := (length(def) - length(replace(def, a, ''))) / length(a);
  IF n <> 1 THEN RAISE EXCEPTION 'route loop anchor found % times', n; END IF;
  def := replace(def, a, $b$WHERE rc.store_code = p_store_code AND rc.status = 'RULED'
      AND rc.route_key !~ '^DIRECT_S[0-9]+$'   -- derived desks (BLOOM-035 item 1) have no ledger row of their own yet (ENG-176): kept out of the pooled DIRECT need$b$);
  EXECUTE def;
END
$mig$;
