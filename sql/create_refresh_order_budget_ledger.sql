-- =============================================================================
-- refresh_order_budget_ledger() -- SB-CC-BLOOM-003 Ship 1, REWRITTEN
-- SB-CC-BLOOM-008 item 16(c) (2026-07-12, "named debt to build first").
--
-- TWO real bugs found and fixed together (same function, inseparable):
--
-- BUG 1 (the brief's own named debt) -- landed_amount/sales_actual were
--   NULL/0 for every route except DIRECT_BEER. The original join scoped
--   EVERY route by `bloom_route_config.merch_group_nrs` -- a column only
--   ever populated for DIRECT_BEER. DC routes are scoped by department_nr
--   (bloom_dc_config), not merch_group_nr; DIRECT_<brand> routes (BLOOM-009)
--   are scoped by supplier_nr (bloom_route_config.direct_supplier_nrs);
--   'ALL' is the whole store, no scope at all. Confirmed live before this
--   fix: every DC/ALL/DIRECT ledger row read landed_amount=0, sales_
--   actual=0 at every store, while DIRECT_BEER's own monthly rows carried
--   real figures (21355 Jul: landed R71,335.33, sales R67,966.85).
--
-- BUG 2 (found during this fix, not named in any brief) -- weekly-grain
--   rows were NEVER updated AT ALL, regardless of route. The original
--   UPDATE matched on `l.year_month = date_trunc('month', movement_date)`
--   -- a month-start date -- but a `grain='weekly'` row's own `year_month`
--   holds a week-commencing SATURDAY (BLOOM-004 item 7 convention), which
--   can never equal a month-start date. Confirmed live: even DIRECT_BEER's
--   own `grain='weekly'` row (2026-07-11) sat at landed_amount=0 while its
--   sibling `grain='monthly'` row for the same store/month carried the
--   real figure. Item 16's delivery-chain/month-picture math needs the
--   WEEKLY figures specifically (this week's landed leg against this
--   week's projected order) -- this bug was directly blocking, not a
--   tangent, so fixed in the same pass.
--
-- Fix: every route class now computes BOTH a month-bucketed and a
-- week-bucketed (Saturday-anchored, canon v7 item 7 formula, identical to
-- rpc_bloom_order_recipe's own v_week_start) sum, and the final UPDATE
-- matches on (store_code, route_key, grain, year_month) so each existing
-- ledger row -- whichever grain it actually is -- gets its own correctly-
-- bucketed figure.
--
-- Route scoping (mirrors rpc_bloom_order_recipe's own pool-membership
-- rules exactly, R21, never a parallel definition):
--   DC          -- sigma_articles.department_nr = ANY(bloom_dc_config.
--                  dc_cycle_dept_nrs), landed requires the movement's own
--                  supplier_type='Z' (matches the recipe's DC lnk branch).
--   DIRECT_BEER -- ENG-033 (2026-07-21): ACCOUNT-scoped, exactly like DIRECT
--                  below. Sales scoped by active sigma_supplier_link to the
--                  route's own direct_supplier_nrs (the receipt-proven SAB
--                  account), landed keyed on the movement's own supplier_nr.
--                  RETIRED with lineage (R28): the merch_group_nrs scope and
--                  the excluded_supplier_types landed test. It kept its own
--                  route_key (ENG-013) and is therefore still EXCLUDED from
--                  the DIRECT rollup below -- folding it in would double-count
--                  SAB spend against the DIRECT rail.
--   DIRECT      -- union of every DIRECT_<brand> desk's own curated
--                  direct_supplier_nrs at that store (BLOOM-009) -- sales
--                  scoped by active sigma_supplier_link to one of those
--                  suppliers, landed requires the movement's own
--                  supplier_nr = ANY(that set) (matches the recipe's
--                  DIRECT_<brand> lnk branch exactly).
--   ALL         -- the whole store, no product/supplier restriction --
--                  matches its own Ship-1 "store-wide" definition
--                  (create_order_budget_ledger_weekly_grain.sql).
--
-- budget_amount is the seeded plan, never overwritten here (unchanged).
-- committed_amount still NOT computed here (unchanged, documented Ship-1
-- gap -- no order-submission persistence yet).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_order_budget_ledger()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_updated int;
  v_result jsonb := '{}'::jsonb;
BEGIN
  -- SALES ACTUAL -------------------------------------------------------------
  WITH
  dc_products AS (
    SELECT dc.store_code, a.product_code
    FROM public.bloom_dc_config dc
    JOIN public.sigma_articles a ON a.store_code = dc.store_code AND a.department_nr = ANY(dc.dc_cycle_dept_nrs)
    WHERE dc.status = 'RULED'
  ),
  beer_products AS (
    -- ENG-033 (2026-07-21): account-scoped, not merch-group-scoped
    SELECT DISTINCT sl.store_code, sl.product_code
    FROM public.bloom_route_config rc
    JOIN public.sigma_supplier_link sl
      ON sl.store_code = rc.store_code AND sl.supplier_nr = ANY(rc.direct_supplier_nrs)
    WHERE rc.route_key = 'DIRECT_BEER'
      AND COALESCE(sl.status,'') <> 'S' AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
  ),
  direct_supplier_nrs_by_store AS (
    SELECT rc.store_code, unnest(rc.direct_supplier_nrs) AS supplier_nr
    FROM public.bloom_route_config rc
    WHERE rc.route_key LIKE 'DIRECT\_%' ESCAPE '\' AND rc.route_key <> 'DIRECT_BEER' AND rc.status = 'RULED'
  ),
  direct_products AS (
    SELECT DISTINCT sl.store_code, sl.product_code
    FROM public.sigma_supplier_link sl
    JOIN direct_supplier_nrs_by_store d ON d.store_code = sl.store_code AND d.supplier_nr = sl.supplier_nr
    WHERE COALESCE(sl.status,'') <> 'S' AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
  ),
  sales_bucketed AS (
    SELECT s.store_code, s.product_code, s.sales_incl_vat,
      date_trunc('month', s.sale_date)::date AS month_key,
      s.sale_date - ((EXTRACT(ISODOW FROM s.sale_date)::int + 1) % 7) AS week_key
    FROM public.sigma_sales s
    WHERE s.period_kind = 'T' AND s.txn_kind = 1
  ),
  sales_union AS (
    SELECT 'DC'::text AS route_key, 'monthly'::text AS grain, sb.store_code, sb.month_key AS year_month, SUM(sb.sales_incl_vat) AS v
      FROM sales_bucketed sb JOIN dc_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.month_key
    UNION ALL
    SELECT 'DC', 'weekly', sb.store_code, sb.week_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb JOIN dc_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.week_key
    UNION ALL
    SELECT 'DIRECT_BEER', 'monthly', sb.store_code, sb.month_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb JOIN beer_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.month_key
    UNION ALL
    SELECT 'DIRECT_BEER', 'weekly', sb.store_code, sb.week_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb JOIN beer_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.week_key
    UNION ALL
    SELECT 'DIRECT', 'monthly', sb.store_code, sb.month_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb JOIN direct_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.month_key
    UNION ALL
    SELECT 'DIRECT', 'weekly', sb.store_code, sb.week_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb JOIN direct_products p ON p.store_code=sb.store_code AND p.product_code=sb.product_code
      GROUP BY sb.store_code, sb.week_key
    UNION ALL
    SELECT 'ALL', 'monthly', sb.store_code, sb.month_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb GROUP BY sb.store_code, sb.month_key
    UNION ALL
    SELECT 'ALL', 'weekly', sb.store_code, sb.week_key, SUM(sb.sales_incl_vat)
      FROM sales_bucketed sb GROUP BY sb.store_code, sb.week_key
  )
  UPDATE public.order_budget_ledger l
  SET sales_actual = su.v, updated_at = now()
  FROM sales_union su
  WHERE l.store_code = su.store_code AND l.route_key = su.route_key
    AND l.grain = su.grain AND l.year_month = su.year_month;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_result := v_result || jsonb_build_object('sales_actual_rows_updated', v_updated);

  -- LANDED AMOUNT --------------------------------------------------------------
  WITH
  dc_config AS (
    SELECT dc.store_code, dc.dc_cycle_dept_nrs FROM public.bloom_dc_config dc WHERE dc.status = 'RULED'
  ),
  beer_config AS (
    -- ENG-033 (2026-07-21): the SAB account itself is the route
    SELECT rc.store_code, rc.direct_supplier_nrs
    FROM public.bloom_route_config rc WHERE rc.route_key = 'DIRECT_BEER'
  ),
  direct_supplier_nrs_by_store AS (
    SELECT rc.store_code, unnest(rc.direct_supplier_nrs) AS supplier_nr
    FROM public.bloom_route_config rc
    WHERE rc.route_key LIKE 'DIRECT\_%' ESCAPE '\' AND rc.route_key <> 'DIRECT_BEER' AND rc.status = 'RULED'
  ),
  direct_supplier_set AS (
    SELECT store_code, array_agg(DISTINCT supplier_nr) AS supplier_nrs FROM direct_supplier_nrs_by_store GROUP BY store_code
  ),
  moves_bucketed AS (
    SELECT m.store_code, m.product_code, m.supplier_nr, m.cost_value,
      date_trunc('month', m.movement_date)::date AS month_key,
      m.movement_date - ((EXTRACT(ISODOW FROM m.movement_date)::int + 1) % 7) AS week_key
    FROM public.sigma_movements m
    WHERE m.movement_type IN ('R','W') AND m.supplier_nr IS NOT NULL
  ),
  landed_union AS (
    SELECT 'DC'::text AS route_key, 'monthly'::text AS grain, mb.store_code, mb.month_key AS year_month, SUM(mb.cost_value) AS v
      FROM moves_bucketed mb
      JOIN dc_config dc ON dc.store_code = mb.store_code
      JOIN public.sigma_articles a ON a.store_code = mb.store_code AND a.product_code = mb.product_code AND a.department_nr = ANY(dc.dc_cycle_dept_nrs)
      JOIN public.sigma_supplier_master sm ON sm.store_code = mb.store_code AND sm.supplier_nr = mb.supplier_nr AND sm.supplier_type = 'Z'
      GROUP BY mb.store_code, mb.month_key
    UNION ALL
    SELECT 'DC', 'weekly', mb.store_code, mb.week_key, SUM(mb.cost_value)
      FROM moves_bucketed mb
      JOIN dc_config dc ON dc.store_code = mb.store_code
      JOIN public.sigma_articles a ON a.store_code = mb.store_code AND a.product_code = mb.product_code AND a.department_nr = ANY(dc.dc_cycle_dept_nrs)
      JOIN public.sigma_supplier_master sm ON sm.store_code = mb.store_code AND sm.supplier_nr = mb.supplier_nr AND sm.supplier_type = 'Z'
      GROUP BY mb.store_code, mb.week_key
    UNION ALL
    SELECT 'DIRECT_BEER', 'monthly', mb.store_code, mb.month_key, SUM(mb.cost_value)
      FROM moves_bucketed mb
      JOIN beer_config bc ON bc.store_code = mb.store_code AND mb.supplier_nr = ANY(bc.direct_supplier_nrs)
      GROUP BY mb.store_code, mb.month_key
    UNION ALL
    SELECT 'DIRECT_BEER', 'weekly', mb.store_code, mb.week_key, SUM(mb.cost_value)
      FROM moves_bucketed mb
      JOIN beer_config bc ON bc.store_code = mb.store_code AND mb.supplier_nr = ANY(bc.direct_supplier_nrs)
      GROUP BY mb.store_code, mb.week_key
    UNION ALL
    SELECT 'DIRECT', 'monthly', mb.store_code, mb.month_key, SUM(mb.cost_value)
      FROM moves_bucketed mb
      JOIN direct_supplier_set ds ON ds.store_code = mb.store_code AND mb.supplier_nr = ANY(ds.supplier_nrs)
      GROUP BY mb.store_code, mb.month_key
    UNION ALL
    SELECT 'DIRECT', 'weekly', mb.store_code, mb.week_key, SUM(mb.cost_value)
      FROM moves_bucketed mb
      JOIN direct_supplier_set ds ON ds.store_code = mb.store_code AND mb.supplier_nr = ANY(ds.supplier_nrs)
      GROUP BY mb.store_code, mb.week_key
    UNION ALL
    SELECT 'ALL', 'monthly', mb.store_code, mb.month_key, SUM(mb.cost_value)
      FROM moves_bucketed mb GROUP BY mb.store_code, mb.month_key
    UNION ALL
    SELECT 'ALL', 'weekly', mb.store_code, mb.week_key, SUM(mb.cost_value)
      FROM moves_bucketed mb GROUP BY mb.store_code, mb.week_key
  )
  UPDATE public.order_budget_ledger l
  SET landed_amount = COALESCE(lu.v, 0), updated_at = now()
  FROM landed_union lu
  WHERE l.store_code = lu.store_code AND l.route_key = lu.route_key
    AND l.grain = lu.grain AND l.year_month = lu.year_month;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  v_result := v_result || jsonb_build_object('landed_amount_rows_updated', v_updated);

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_order_budget_ledger() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_order_budget_ledger() TO authenticated;
