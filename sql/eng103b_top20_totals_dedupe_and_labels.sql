-- =============================================================================
-- eng103b_top20_totals_dedupe_and_labels.sql   (migration eng103b_top20_totals_dedupe_and_labels)
-- ENG-103 review fixes (dashboard lane, 14-10-2026): an adversarial review of 77799af (three lenses, each finding
-- re-tested by a skeptic that tried to refute it) confirmed two defects in the functions of eng103_rpc_top20_totals.sql.
--
-- 1. rpc_ean_labels took its labels from EVERY bridge row of the EAN, while the direct rpc_top20 filtered branch takes
--    them from the lines that sold in the dates and passed the department / sub-department / EAN filter. With a filter
--    on and more than 14 dates the paged Top 20 showed, e.g., 'DORMANT PRODUCTS' under bread rows that read 'BAKERY' at
--    13 dates (five stores, 13 dates, p_dept = BAKERY: dept_name differed on 14 of 24 rows; sub-dept 11; description 3;
--    sales, quantities and the picked set were equal). FIX: rpc_ean_labels gains p_dates, p_dept and p_subdept (all
--    default NULL); when p_dates is given it keeps only product codes that sold in those dates (T / 1 / sales > 0, the
--    totals reader's own filter) and the dept / sub-dept predicates are applied as in the agg branch. With no extras it is
--    the old function, so a caller that sends two arguments is unaffected. The page sends the dates only when a
--    filter is on (the unfiltered default branch of rpc_top20 takes its labels from every bridge row, and so do we).
-- 2. rpc_top20_totals joined to unnest(p_dates), so a date listed twice was counted twice (rpc_top20's `= ANY` is not).
--    The page de-duplicates its dates, but the function is callable by anon. FIX: de-duplicate once at the declaration.
--
-- Additive (R30): rpc_top20 untouched. The old two-argument rpc_ean_labels is dropped in the same transaction and replaced
-- by the five-argument one with defaults, so there is no ambiguous overload. ACL as the other dashboard RPCs.
-- Rollback: re-run sql/eng103_rpc_top20_totals.sql after dropping both functions (the old bodies).
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

DROP FUNCTION IF EXISTS public.rpc_ean_labels(text[], text[]);

CREATE FUNCTION public.rpc_ean_labels(p_store_codes text[], p_eans text[], p_dates text[] DEFAULT NULL, p_dept text DEFAULT NULL, p_subdept text DEFAULT NULL)
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
     AND (p_dept    IS NULL OR sd.name  = p_dept)
     AND (p_subdept IS NULL OR sub.name = p_subdept)
     AND (p_dates IS NULL OR EXISTS (
            SELECT 1 FROM sigma_sales ss
             WHERE ss.store_code = b.store_code AND ss.product_code = b.product_code
               AND ss.sale_date = ANY(p_dates::date[])
               AND ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sales_incl_vat > 0))
   GROUP BY b.ean
$fn$;

COMMENT ON FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) IS
  'GRADE: CALCULATED. ENG-103 (dashboard lane, 14-10-2026): per-EAN ex-VAT sales and quantity for the selected stores and dates (duplicate dates counted once), with the same filters and measures as rpc_top20 Movers, as ONE jsonb row {served, rows:[[ean, sales, qty]]}. The page sums these over date pages and picks the union of the top 20 by value and by quantity, which rpc_top20 cannot do over date pages.';
COMMENT ON FUNCTION public.rpc_ean_labels(text[], text[], text[], text, text) IS
  'GRADE: CALCULATED. ENG-103 (dashboard lane, 14-10-2026): description, department, sub-department, size and unit for a short list of EANs (the picked Top 20). With p_dates it keeps only product codes that sold in those dates and applies p_dept / p_subdept, as the filtered branch of rpc_top20 does; without them it is the unfiltered deco leg.';

REVOKE EXECUTE ON FUNCTION public.rpc_ean_labels(text[], text[], text[], text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_ean_labels(text[], text[], text[], text, text) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
