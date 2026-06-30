-- =============================================================================
-- create_v_top_products_by_date.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 8 (was held as obj 6; cleared 2026-06-30).
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 / fix_top20_subdept.sql.
-- =============================================================================
-- WHY:
--   View was FROM daily_snapshots WHERE today_sales > 0, with RANK() over
--   (store_code, snapshot_date). Frozen at 2026-06-28.
--
-- WHAT CHANGES (v2, 2026-06-30 per RULE-BOOK R20 addendum):
--   Driver: sigma_sales (period_kind='T', txn_kind=1) aggregated per
--     (store, sale_date, ean).
--   ean: LEFT JOIN v_ean_bridge + COALESCE(b.ean, synthetic store+product)
--     so PLU/produce/uncatalogued lines are not dropped (INNER JOIN dropped
--     up to 48% of sales on some stores -- the R20 coverage rule).
--   description: sigma_articles.description.
--   dept_name: sigma_departments via sigma_articles.department_nr.
--   sub_dept_name: sigma_subdepts via sigma_articles.merch_group_nr.
--   today_sales: SUM(sales_incl_vat).  today_qty: SUM(qty).
--   WHERE today_sales > 0 filter preserved (HAVING clause on the aggregation).
--   daily_snapshots dependency dropped entirely.
--
-- SYNTHETIC EAN fallback: LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')
--   matches the old daily_snapshots PLU-expansion convention (13 chars).
--
-- R22 acceptance: view total = direct sigma_sales SUM x5 to the rand.
-- COLUMN ORDER: preserved exactly (store_code, snapshot_date, ean, description,
--   dept_name, sub_dept_name, today_sales, today_qty, rank_by_sales, rank_by_qty).
-- GRANT: anon + authenticated SELECT.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP VIEW IF EXISTS public.v_top_products_by_date;

CREATE VIEW public.v_top_products_by_date AS
WITH sales AS (
  SELECT
    ss.store_code,
    ss.sale_date,
    COALESCE(b.ean,
      LPAD(ss.store_code, 5, '0') || LPAD(ss.product_code::text, 8, '0'))          AS ean,
    a.description,
    sd.name                                                                         AS dept_name,
    sub.name                                                                        AS sub_dept_name,
    round(sum(ss.sales_incl_vat), 2)                                                AS today_sales,
    round(sum(ss.qty), 2)                                                           AS today_qty
  FROM public.sigma_sales ss
  LEFT JOIN public.v_ean_bridge b
    ON  b.store_code   = ss.store_code
    AND b.product_code = ss.product_code
  JOIN public.sigma_articles a
    ON  a.store_code   = ss.store_code
    AND a.product_code = ss.product_code
  LEFT JOIN public.sigma_departments sd
    ON  sd.store_code    = a.store_code
    AND sd.department_nr = a.department_nr
  LEFT JOIN public.sigma_subdepts sub
    ON  sub.store_code     = a.store_code
    AND sub.merch_group_nr = a.merch_group_nr
  WHERE ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY
    ss.store_code,
    ss.sale_date,
    COALESCE(b.ean, LPAD(ss.store_code, 5, '0') || LPAD(ss.product_code::text, 8, '0')),
    a.description,
    sd.name,
    sub.name
  HAVING sum(ss.sales_incl_vat) > 0
)
SELECT
  store_code,
  sale_date                                                                         AS snapshot_date,
  ean,
  description,
  dept_name,
  sub_dept_name,
  today_sales,
  today_qty,
  rank() OVER (PARTITION BY store_code, sale_date ORDER BY today_sales DESC)       AS rank_by_sales,
  rank() OVER (PARTITION BY store_code, sale_date ORDER BY today_qty   DESC)       AS rank_by_qty
FROM sales;

GRANT SELECT ON public.v_top_products_by_date TO anon, authenticated;
