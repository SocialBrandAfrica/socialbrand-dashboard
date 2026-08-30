-- create_rpc_bloom_route_benchmark.sql
--
-- ENG-106 leg (b). THE ONE HOME for the ORDERING-CANON §D6.1 route benchmark.
-- Migration: eng106_route_benchmark_leg_b_watermark_anchor (2026-08-27).
--
-- GENERATED FROM LIVE via pg_get_functiondef on 2026-08-30, never hand-written,
-- so this file can be hash-gated against the database (ENG-115 class rule: a
-- sql/ file that was not generated from live can never be hash-gated, only
-- replaced).
--
-- Basis B (§D6.1 v1.11, after the C->B revert on CC's base-rate refutation):
-- the cycle DEPARTMENT set off sigma_sales, 28d cost / 4, with NO class, world
-- or link filter. R21, behaviour not label -- a class filter drops the
-- zero-deplete record_stock_qty=0 CHILDREN, 8-49% of route rand, worst 48.5% at
-- 21355, while removing almost no World-2 because the dept scope already
-- excludes production. Residual World-2 in scope is <=1.24% packaging, carried
-- as a NAMED bounded over-count, never regexed out.
--
-- Clause 2 (§D6.1 v1.13): the window anchors to the LEDGER WATERMARK AS AT THE
-- BUILD, stored on the artefact and disclosed with the number. Never
-- CURRENT_DATE (it drifts while the artefact it judges is fixed). Never the
-- delivery date (a future-dated window counts unobserved days in a fixed
-- divisor and deflates the mean BY CONSTRUCTION -- measured -17.2% at 10116,
-- -17.4% at 80175). p_anchor_date accepts a STORED anchor so a frozen artefact
-- reproduces its own benchmark exactly.
--
-- NEVER a sum of l2_population_verdict's pool columns. Measured 2026-08-30,
-- summing those understates the route by 33.9% (10116), 34.8% (80175) and
-- 53.3-58.7% across the TOPS trio -- R260,148.85 at 10116 alone.
--
-- SECURITY DEFINER IS LOAD-BEARING, NOT BOILERPLATE: sigma_sales carries RLS
-- with no anon read policy, so an invoker build hands the browser key a
-- confident ZERO -- the ENG-068 / ENG-074 shape. Proven behaviourally.

CREATE OR REPLACE FUNCTION public.rpc_bloom_route_benchmark(p_store_code text, p_route text, p_anchor_date date DEFAULT NULL::date)
 RETURNS TABLE(store_code text, route_key text, anchor_date date, anchor_basis text, window_days integer, weekly_cost_demand numeric, window_cost_demand numeric, products_in_scope integer, dept_nrs smallint[], basis text, disclosure text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_depts smallint[];
  v_anchor date;
  v_wm date;
BEGIN
  -- The population is the store's CYCLE DEPARTMENT SET. Ruled for DC routes only.
  SELECT c.dc_cycle_dept_nrs INTO v_depts
  FROM bloom_dc_config c WHERE c.store_code = p_store_code;

  IF p_route NOT LIKE 'DC%' OR v_depts IS NULL THEN
    -- Named, never invented. SSD6.1 rules the cycle dept set; it does not rule a
    -- population for the direct/dropship desks, and a merch-group substitute here
    -- would be a basis nobody churned.
    RETURN QUERY SELECT p_store_code, p_route, NULL::date, 'not_applicable'::text,
                        28, NULL::numeric, NULL::numeric, NULL::int, NULL::smallint[],
                        'NOT_RULED_FOR_THIS_ROUTE'::text,
                        'ORDERING-CANON SSD6.1 rules the benchmark basis on the cycle DEPARTMENT set, which exists for DC routes only. No basis is ruled for direct or dropship desks, so none is invented here.'::text;
    RETURN;
  END IF;

  SELECT max(s.sale_date) INTO v_wm
  FROM sigma_sales s
  WHERE s.store_code = p_store_code AND s.sale_date >= CURRENT_DATE - 90;

  IF v_wm IS NULL THEN
    RAISE EXCEPTION 'rpc_bloom_route_benchmark(%): no ledger watermark; refusing to anchor a demonstrated-demand window on a calendar', p_store_code;
  END IF;

  -- A caller may pass a STORED anchor to reproduce a frozen artefact's benchmark
  -- exactly (clause 2's frozen-at-build half). Default is the live watermark.
  v_anchor := COALESCE(p_anchor_date, v_wm);

  RETURN QUERY
  WITH scoped AS (
    SELECT s.product_code, s.cost_value
    FROM sigma_sales s
    JOIN sigma_articles a
      ON a.store_code = s.store_code
     AND a.product_code = s.product_code
     AND a.department_nr = ANY(v_depts)
    WHERE s.store_code   = p_store_code
      AND s.period_kind  = 'T'
      AND s.txn_kind     = 1
      AND s.sale_date >  v_anchor - 28
      AND s.sale_date <= v_anchor
  )
  SELECT p_store_code,
         p_route,
         v_anchor,
         CASE WHEN p_anchor_date IS NULL THEN 'ledger_watermark_live'
              WHEN p_anchor_date = v_wm  THEN 'ledger_watermark_stored_current'
              ELSE 'ledger_watermark_stored_stale' END,
         28,
         ROUND((SUM(sc.cost_value) / 4)::numeric, 2),
         ROUND(SUM(sc.cost_value)::numeric, 2),
         COUNT(DISTINCT sc.product_code)::int,
         v_depts,
         'B: cycle dept set off sigma_sales, 28d cost / 4, NO class/world/link filter (R21)',
         'Anchor is the ledger watermark, not CURRENT_DATE and not the delivery date (SSD6.1 clause 2 v1.13). Includes <=1.24% packaging as a NAMED bounded over-count; production and deposits measure 0.00% because the cycle dept scope already excludes them. Reproduce with a same-day source sum AT THE SAME ANCHOR.'
  FROM scoped sc;
END
$function$;

COMMENT ON FUNCTION public.rpc_bloom_route_benchmark(text,text,date) IS
'ENG-106 leg (b). THE ONE HOME for the SSD6.1 route benchmark, basis B, anchored on the ledger watermark and disclosing it. Never a sum of l2_population_verdict pool columns. rpc_bloom_scenario_overview and rpc_bloom_stock_state both READ this (ENG-112 repoint, 2026-08-30).';

-- Grants stated explicitly (R30 addendum). Read RPC: anon stays executable by
-- design; PUBLIC is revoked so the default-privilege trap cannot re-open it.
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_route_benchmark(text,text,date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_route_benchmark(text,text,date) TO anon;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_route_benchmark(text,text,date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_route_benchmark(text,text,date) TO service_role;
