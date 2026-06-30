-- =============================================================================
-- create_v_focus_trend.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 7 (was held as obj 4; cleared 2026-06-30).
-- Replaces daily_snapshots-driven v_focus_trend (no prior sql/ file existed;
-- view was created inline in earlier migrations).
-- =============================================================================
-- WHY:
--   v_focus_trend was FROM daily_snapshots GROUP BY store_code, snapshot_date,
--   ean, dept_name, sub_dept_name, description. Frozen at 2026-06-28.
--
-- WHAT CHANGES (v2, 2026-06-30 per RULE-BOOK R20 addendum):
--   Driver: sigma_sales (period_kind='T', txn_kind=1).
--   ean: LEFT JOIN v_ean_bridge + COALESCE(b.ean, synthetic store+product)
--     so PLU/produce/uncatalogued lines are not dropped (INNER JOIN dropped
--     up to 48% of sales on some stores -- the R20 coverage rule).
--   dept_name: sigma_departments via sigma_articles.department_nr.
--   sub_dept_name: sigma_subdepts via sigma_articles.merch_group_nr.
--   description: sigma_articles.description.
--   sales: SUM(sales_incl_vat).  qty: SUM(qty).
--   daily_snapshots dependency dropped entirely.
--
-- SYNTHETIC EAN fallback: LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')
--   matches the old daily_snapshots PLU-expansion convention (13 chars).
--
-- R22 acceptance: view total = direct sigma_sales SUM x5 to the rand.
-- COLUMN ORDER: preserved exactly from the replaced view.
-- GRANT: anon + authenticated SELECT.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP VIEW IF EXISTS public.v_focus_trend;

CREATE VIEW public.v_focus_trend AS
SELECT
  ss.store_code,
  ss.sale_date                                                                      AS snapshot_date,
  COALESCE(b.ean,
    LPAD(ss.store_code, 5, '0') || LPAD(ss.product_code::text, 8, '0'))            AS ean,
  sd.name                                                                           AS dept_name,
  sub.name                                                                          AS sub_dept_name,
  a.description,
  round(sum(ss.sales_incl_vat), 2)                                                  AS sales,
  round(sum(ss.qty), 2)                                                             AS qty
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
  sd.name,
  sub.name,
  a.description;

GRANT SELECT ON public.v_focus_trend TO anon, authenticated;
