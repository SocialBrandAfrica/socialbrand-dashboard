-- ROLLBACK FILE for migration eng086_rpc_report_rows_family_cover (ENG-086 / ENG-073, dashboard lane, 14-10-2026).
-- The LIVE body of public.rpc_report_rows(text[], text[]) before the family-cover keys were added,
-- md5 72d93b9607790e9da702465cd5f7116b, 5,136 characters, hash-gated before this file was written.
-- To roll back: run this file (CREATE OR REPLACE keeps the ACL; no GRANT is restated).

CREATE OR REPLACE FUNCTION public.rpc_report_rows(p_store_codes text[], p_dates text[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
WITH v AS (
  SELECT p_store_codes AS stores,
         p_dates::date[] AS dates,
         (SELECT MAX(d) FROM UNNEST(p_dates::date[]) d) AS max_d,
         (SELECT MIN(d) FROM UNNEST(p_dates::date[]) d) AS min_d
),
-- One index scan covers both measures: today_* = selected dates only;
-- period_* = MTD at the max selected date (matches the retired PRSSALE
-- period_* semantics the frontend merge expects).
sales AS MATERIALIZED (
  SELECT ss.store_code, ss.product_code,
         round(sum(ss.qty)            FILTER (WHERE ss.sale_date = ANY(v.dates)), 2) AS today_qty,
         round(sum(ss.cost_value)     FILTER (WHERE ss.sale_date = ANY(v.dates)), 2) AS today_cost,
         round(sum(ss.sales_incl_vat) FILTER (WHERE ss.sale_date = ANY(v.dates)), 2) AS today_sales,
         round(sum(ss.qty)            FILTER (WHERE ss.sale_date >= date_trunc('month', v.max_d)::date), 2) AS period_qty,
         round(sum(ss.cost_value)     FILTER (WHERE ss.sale_date >= date_trunc('month', v.max_d)::date), 2) AS period_cost,
         round(sum(ss.sales_incl_vat) FILTER (WHERE ss.sale_date >= date_trunc('month', v.max_d)::date), 2) AS period_sales
  FROM public.sigma_sales ss, v
  WHERE ss.store_code = ANY(v.stores)
    AND ss.sale_date BETWEEN LEAST(date_trunc('month', v.max_d)::date, v.min_d) AND v.max_d
    AND ss.period_kind = 'T' AND ss.txn_kind = 1
  GROUP BY ss.store_code, ss.product_code
),
-- Latest SOH snapshot per store AT OR BEFORE the selection end -- a store whose
-- extractor is dark (Dice, 30 Jun) still reports its last known position
-- instead of vanishing. LATERAL keeps this to one index probe per store.
soh_ref AS MATERIALIZED (
  SELECT s.store_code, r.ref_date
  FROM UNNEST((SELECT stores FROM v)) AS s(store_code)
  JOIN LATERAL (
    SELECT ls.snapshot_date AS ref_date
    FROM public.l2_soh_daily ls, v
    WHERE ls.store_code = s.store_code AND ls.snapshot_date <= v.max_d
    ORDER BY ls.snapshot_date DESC LIMIT 1
  ) r ON true
),
-- LATERAL forces the per-(store, ref_date) index path; a plain join here made
-- the planner seq-scan all 8.3M l2_soh_daily rows (measured 2026-07-05).
stock AS MATERIALIZED (
  SELECT sr.store_code, x.product_code, x.soh
  FROM soh_ref sr
  CROSS JOIN LATERAL (
    SELECT ls.product_code, ls.soh
    FROM public.l2_soh_daily ls
    WHERE ls.store_code = sr.store_code AND ls.snapshot_date = sr.ref_date AND ls.soh <> 0
  ) x
),
-- Universe = any line that sold in the selection / sold MTD / holds stock.
-- Driven from the facts, not sigma_articles, so no sold line is ever dropped
-- by a missing article row (R22; same coverage direction as the R20 addendum).
universe AS MATERIALIZED (
  SELECT store_code, product_code FROM sales
  UNION
  SELECT store_code, product_code FROM stock
)
SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) FROM (
  SELECT
    COALESCE(b.ean, LPAD(u.store_code,5,'0') || LPAD(u.product_code::text,8,'0')) AS ean,
    COALESCE(a.description, 'UNMAPPED ' || u.product_code::text) AS description,
    a.pack_content::text AS size,
    a.unit,
    a.sell_price_incl_vat AS sell_price,
    NULL::numeric AS vat_pct,
    COALESCE(sl.today_qty,0)    AS today_qty,
    COALESCE(sl.today_cost,0)   AS today_cost,
    COALESCE(sl.today_sales,0)  AS today_sales,
    COALESCE(sl.period_qty,0)   AS period_qty,
    COALESCE(sl.period_cost,0)  AS period_cost,
    COALESCE(sl.period_sales,0) AS period_sales,
    st.soh,
    LPAD(a.department_nr::text,6,'0')  AS dept_code,
    COALESCE(sd.name,'UNMAPPED')       AS dept_name,
    LPAD(a.merch_group_nr::text,9,'0') AS sub_dept_code,
    COALESCE(sub.name,'UNMAPPED')      AS sub_dept_name,
    u.product_code::text AS internal_ref,
    a.record_status      AS status,
    ros.last_sale_date::text AS last_sales_date_iso,
    NULL::boolean        AS is_placeholder,
    (SELECT max_d FROM v)::text AS snapshot_date,
    u.store_code,
    s2.store_name,
    sp.unit_cost,
    sp.daily_ros,
    sp.days_cover,
    sp.tier,
    sp.class
  FROM universe u
  LEFT JOIN public.sigma_articles a  ON a.store_code = u.store_code AND a.product_code = u.product_code
  LEFT JOIN public.v_ean_bridge b    ON b.store_code = u.store_code AND b.product_code = u.product_code
  LEFT JOIN public.sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
  LEFT JOIN public.sigma_subdepts sub   ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
  LEFT JOIN sales sl ON sl.store_code = u.store_code AND sl.product_code = u.product_code
  LEFT JOIN stock st ON st.store_code = u.store_code AND st.product_code = u.product_code
  LEFT JOIN public.l2_stock_position sp ON sp.store_code = u.store_code AND sp.product_code = u.product_code
  LEFT JOIN public.l2_rate_of_sale ros  ON ros.store_code = u.store_code AND ros.product_code = u.product_code
  LEFT JOIN public.stores s2 ON s2.store_code = u.store_code
  ORDER BY a.description, u.store_code
) x;
$function$
;
