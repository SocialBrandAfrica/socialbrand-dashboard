-- =============================================================================
-- eng103_rpc_top20_totals.sql   (migration eng103_rpc_top20_totals)
-- ENG-103 (dashboard lane, PM ruling 14-10-2026 09:0x and 10:04): the Top 20 date cap. Page the results, never refuse;
-- measure first; over 8 s, build the per-item totals reader.
--
-- MEASURED 14-10-2026 10:2x, five stores, rpc_top20 Movers, the database busy with the Bloom cache job:
--   1 date 1.1 s; 13 dates 1.7 s; 31 dates 6.5 s; 62 dates 25.9 s. Superlinear: the live body filters with
--   `ss.sale_date = ANY(v_dates)` (a per-row array scan). With a join-to-the-dates plan the same base read took 7.0 s
--   at 62 dates, linear at about 0.11 s a date at five stores (0.022 s per store-date), so 619 dates would be about 65 s
--   either way. The authenticator's ceiling is 8 s. So a long selection cannot be answered in one call.
--
-- WHY A TOTALS READER AND NOT A DATE PAGE OF rpc_top20: Movers is the UNION of the top 20 by value and the top 20 by
-- quantity over the WHOLE date set (live body, md5 ced3dfe2). The 40 rows of one page cannot be merged exactly: an item
-- outside every page's top 40 can belong to the period's top 20. These two functions let the page sum EXACT per-item
-- totals over date pages and pick the union itself:
--   rpc_top20_totals(stores, dates, dept, subdept, eans) -> {served, rows:[[ean, sales_ex_vat, qty], ...]}  (ONE jsonb
--     row, so no row cap can cut it; served is computed from the payload, the R22 tripwire). Same filters and the same
--     measures as rpc_top20 Movers (period T, txn kind 1, sales_incl_vat > 0, ex-VAT as sales_incl_vat - vat_value, EAN
--     through v_ean_bridge), joined to a dates relation so the cost is linear. Sales are carried to 4 decimals and
--     rounded by the page after summing, so paging does not move a cent.
--   rpc_ean_labels(stores, eans) -> description, dept, sub-dept, size, unit for the (at most 40) picked EANs, the same
--     expressions as the `deco` leg of rpc_top20.
-- PAGE SIZE (derived, not typed): 125 store-dates a page (25 dates at five stores, 125 at one). MEASURED after applying
-- (14-10-2026, Bloom cache job still running): 25 dates x 5 stores 1.64 s; 125 dates x 1 store 3.25 s (the slowest shape,
-- 2.5x inside the 8 s ceiling); all 25 pages of the 620-day, five-store range 39.2 s in sequence, 1.57 s a page.
-- R22 (SQL, 13 dates, five stores): the union picked from rpc_top20_totals equals rpc_top20 exactly, in one page and when
-- summed over four pages of 4 dates: 33 rows = 33 rows, 0 EANs differ, 0 values differ.
-- The page reads rpc_top20 unchanged up to 14 dates (13 dates measured 1.7 s) and pages beyond.
-- Additive (R30): rpc_top20 is untouched. ACL as the other dashboard RPCs: anon, authenticated, service_role.
-- Rollback: DROP FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]);
--           DROP FUNCTION public.rpc_ean_labels(text[], text[]);
-- =============================================================================
SET LOCAL lock_timeout = '5s';
DO $
BEGIN
  IF to_regprocedure('public.rpc_top20_totals(text[],text[],text,text,text[])') IS NOT NULL
     OR to_regprocedure('public.rpc_ean_labels(text[],text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'rpc_top20_totals or rpc_ean_labels already exists; refusing to overwrite';
  END IF;
END $$;

CREATE FUNCTION public.rpc_top20_totals(p_store_codes text[], p_dates text[], p_dept text DEFAULT NULL, p_subdept text DEFAULT NULL, p_eans text[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '15s'
AS $fn$
DECLARE
  v_dates date[] := p_dates::date[];
  v_rows  jsonb;
BEGIN
  IF p_dept IS NOT NULL OR p_subdept IS NOT NULL OR p_eans IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_array(t.ean, t.sv, t.q)), '[]'::jsonb) INTO v_rows FROM (
      SELECT b.ean,
             round(SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0))::numeric, 4) AS sv,
             SUM(ss.qty)::numeric                                                  AS q
        FROM unnest(v_dates) AS dd(dt)
        JOIN sigma_sales ss              ON ss.sale_date = dd.dt
        JOIN v_ean_bridge b              ON b.store_code = ss.store_code AND b.product_code = ss.product_code
        LEFT JOIN sigma_articles a       ON a.store_code = ss.store_code AND a.product_code = ss.product_code
        LEFT JOIN sigma_departments sd   ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
        LEFT JOIN sigma_subdepts sub     ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
       WHERE ss.store_code = ANY(p_store_codes)
         AND ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sales_incl_vat > 0
         AND (p_dept    IS NULL OR sd.name  = p_dept)
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

CREATE FUNCTION public.rpc_ean_labels(p_store_codes text[], p_eans text[])
RETURNS TABLE(ean text, description text, dept_name text, sub_dept_name text, size text, unit text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '15s'
AS $fn$
  SELECT b.ean::text,
         MAX(COALESCE(a.description, a.short_description)) AS description,
         MAX(COALESCE(sd.name,  'UNMAPPED'))               AS dept_name,
         MAX(COALESCE(sub.name, 'UNMAPPED'))               AS sub_dept_name,
         MAX(pc.size_label)                                AS size,
         MAX(COALESCE(a.unit, pc.detail_unit))             AS unit
    FROM v_ean_bridge b
    LEFT JOIN sigma_articles a        ON a.store_code = b.store_code AND a.product_code = b.product_code
    LEFT JOIN sigma_departments sd    ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
    LEFT JOIN sigma_subdepts sub      ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
    LEFT JOIN product_catalog pc      ON pc.store_code = b.store_code AND pc.ean = b.ean
   WHERE b.ean = ANY(p_eans) AND b.store_code = ANY(p_store_codes)
   GROUP BY b.ean
$fn$;

COMMENT ON FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) IS
  'GRADE: CALCULATED. ENG-103 (dashboard lane, 14-10-2026): per-EAN ex-VAT sales and quantity for the selected stores and dates, with the same filters and measures as rpc_top20 Movers, as ONE jsonb row {served, rows:[[ean, sales, qty]]}. The page sums these over date pages and picks the union of the top 20 by value and by quantity, which rpc_top20 cannot do over date pages.';
COMMENT ON FUNCTION public.rpc_ean_labels(text[], text[]) IS
  'GRADE: CALCULATED. ENG-103 (dashboard lane, 14-10-2026): description, department, sub-department, size and unit for a short list of EANs (the picked Top 20), the same expressions as the deco leg of rpc_top20.';

REVOKE EXECUTE ON FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) TO anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpc_ean_labels(text[], text[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_ean_labels(text[], text[]) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
