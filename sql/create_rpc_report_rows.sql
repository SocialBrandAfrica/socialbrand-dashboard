-- =============================================================================
-- create_rpc_report_rows.sql
-- CC-BRIEF-DASH-FINAL-001 item 1 -- the Reports & Downloads drawer dataset.
-- Successor to rpc_all_rows as the drawer loader (R28: predecessor retired
-- with lineage in its file header, kept live in the DB).
-- Applied live 2026-07-05 (migration dashfinal_rpc_report_rows_single_shot).
-- =============================================================================
-- WHY (measured 2026-07-05):
--   rpc_all_rows computed sigma_articles x UNNEST(dates) (~1.1M joined rows for
--   5 stores x 4 dates), sorted the lot, and re-ran ALL of it per 1,000-row
--   page: 27,760 ms per page vs the authenticator's 8s statement_timeout --
--   every drawer report died and rendered "No rows match current filters"
--   (a coverage lie, R22). The frontend also capped paging at 10,000 rows, so
--   even a fast paged loader could never reconcile to sigma_sales.
--
-- WHAT THIS DOES INSTEAD:
--   ONE call returns the complete drawer dataset as a jsonb array (a single
--   response row -- PostgREST's db-max-rows cannot truncate it, so no paging
--   and no cap). One row per (store, product) with ACTIVITY in the selection:
--     sold on a selected date, OR sold MTD at the max selected date, OR
--     SOH <> 0 at the store's latest snapshot <= the selection end.
--   Rows arrive already date-merged, matching what the frontend's mergeByEan
--   produced from per-date rows:
--     today_*  = SUM over the selected dates only (additive measure).
--     period_* = MTD at the max selected date (the retired PRSSALE period_*
--                semantics -- what the client merge kept from the latest date).
--     soh      = the store's latest l2_soh_daily snapshot <= max date, so a
--                dark store (Dice, 30 Jun) reports its last known position
--                instead of vanishing.
--   Engine facts carried per row (display reads the engine, never recomputes):
--     daily_ros / days_cover / tier / class from l2_stock_position
--     (tier = l2_ranging_tier verdict, RULE-BOOK section 4).
--   Universe is driven FROM the sales + stock facts, not sigma_articles, so a
--   sold line missing an article row is never dropped (R22; same coverage
--   direction as the R20 addendum). ean = LEFT JOIN v_ean_bridge + COALESCE
--   synthetic fallback (R20 addendum).
--
-- PERFORMANCE (EXPLAIN ANALYZE 2026-07-05, 5 stores x 4 July dates, 19,855 rows):
--   2,355 ms total -- vs 27,760 ms PER PAGE before. Notes baked into the SQL:
--     * sales: ONE index scan covers both today_* and period_* via FILTER
--       aggregates (window = LEAST(month_start, min selected) .. max selected).
--     * soh_ref: LATERAL ORDER BY snapshot_date DESC LIMIT 1 per store -- a
--       plain MAX() aggregated 8.3M index rows.
--     * stock: LATERAL forces the per-(store, ref_date) index path -- a plain
--       join made the planner seq-scan all 8.3M l2_soh_daily rows.
--   Own statement_timeout '15s' (PM pattern from rpc_push_status/picker pair)
--   so the authenticator's 8s cap does not apply.
--
-- R22 PROOF (2026-07-05, Jul 1-4 x5): per-store SUM(today_sales/today_qty) and
--   SUM(period_sales) all reconcile to sigma_sales direct SUM (period_kind='T',
--   txn_kind=1) with diff 0.00 on every store. Dice returns 794 rows off its
--   30 Jun position while its extractor is dark (honest, not blank).
-- =============================================================================

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
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_report_rows(text[], text[]) TO anon, authenticated;

-- Reload the PostgREST schema cache (RULE-BOOK section 8; belt-and-braces --
-- verify live and use the Dashboard Reload schema button if the API still 404s).
SELECT pg_notify('pgrst', 'reload schema');
