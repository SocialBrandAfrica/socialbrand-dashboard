-- =============================================================================
-- eng103c_top20_totals_filtered_date_first.sql   (migration eng103c_top20_totals_filtered_date_first)
-- ENG-103 (dashboard lane, 14-10-2026 ~14:1x): a department-filtered Top 20 beyond 14 dates read "canceling statement due to
-- statement timeout" at the page (All stores, 15 dates, BAKERY, rpc_top20_totals page 1 of 1), and the same call did not finish in
-- two minutes in the database. Cause: the FILTERED branch joined sales to the filters first. With literals the planner starts from
-- the 2,338 BAKERY article rows, walks l2_ean_resolved and then reads EVERY sale of each of those products
-- (idx_sigma_sales_store_prod_date, est. 52 rows each, in fact the whole history) and only then keeps the 15 dates. The unfiltered
-- branch, which aggregates the dates first, answers in 1.6 s for 25 dates at five stores.
-- (My own earlier "filtered branch 107 ms" reading used 'GROCERIES', which is not a department name: 0 rows. Not evidence.)
-- FIX: the filtered branch aggregates sales per (store, product) over the dates FIRST (the same MATERIALIZED base as the
-- unfiltered branch), then joins the bridge, articles, departments and sub-departments and applies the filters to that small
-- result. Same measures, same filters, same ean key: department and sub-department are properties of the (store, product) article
-- row, so filtering after the aggregation selects the same lines. The unfiltered branch is untouched.
-- Rollback: re-run sql/eng103b_top20_totals_dedupe_and_labels.sql (the previous body).
-- =============================================================================
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.rpc_top20_totals(p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL, p_subdept text DEFAULT NULL, p_eans text[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '15s'
AS $fn$
DECLARE
  v_dates date[] := ARRAY(SELECT DISTINCT x FROM unnest(p_dates::date[]) AS u(x) WHERE x IS NOT NULL);
  v_rows  jsonb;
BEGIN
  IF p_dept IS NOT NULL OR p_subdept IS NOT NULL OR p_eans IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_array(t.ean, t.sv, t.q)), '[]'::jsonb) INTO v_rows FROM (
      WITH base AS MATERIALIZED (
        SELECT ss.store_code, ss.product_code,
               SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0)) AS sv,
               SUM(ss.qty)                                        AS q
          FROM unnest(v_dates) AS dd(dt)
          JOIN sigma_sales ss ON ss.sale_date = dd.dt
         WHERE ss.store_code = ANY(p_store_codes)
           AND ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sales_incl_vat > 0
         GROUP BY ss.store_code, ss.product_code
      )
      SELECT b.ean,
             round(SUM(base.sv)::numeric, 4) AS sv,
             SUM(base.q)::numeric            AS q
        FROM base
        JOIN v_ean_bridge b              ON b.store_code = base.store_code AND b.product_code = base.product_code
        LEFT JOIN sigma_articles a       ON a.store_code = base.store_code AND a.product_code = base.product_code
        LEFT JOIN sigma_departments sd   ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
        LEFT JOIN sigma_subdepts sub     ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
       WHERE (p_dept    IS NULL OR sd.name  = p_dept)
         AND (p_subdept IS NULL OR sub.name = p_subdept)
         AND (p_eans    IS NULL OR b.ean    = ANY(p_eans))
       GROUP BY b.ean
    ) t;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_array(t.ean, t.sv, t.q)), '[]'::jsonb) INTO v_rows FROM (
      WITH base AS MATERIALIZED (
        SELECT ss.store_code, ss.product_code,
               SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0)) AS sv,
               SUM(ss.qty)                                        AS q
          FROM unnest(v_dates) AS dd(dt)
          JOIN sigma_sales ss ON ss.sale_date = dd.dt
         WHERE ss.store_code = ANY(p_store_codes)
           AND ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sales_incl_vat > 0
         GROUP BY ss.store_code, ss.product_code
      )
      SELECT b.ean, round(SUM(base.sv)::numeric, 4) AS sv, SUM(base.q)::numeric AS q
        FROM base
        JOIN v_ean_bridge b ON b.store_code = base.store_code AND b.product_code = base.product_code
       GROUP BY b.ean
    ) t;
  END IF;
  RETURN jsonb_build_object('stores', to_jsonb(p_store_codes), 'served', jsonb_array_length(v_rows), 'rows', v_rows);
END
$fn$;
