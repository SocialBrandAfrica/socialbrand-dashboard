-- =============================================================================
-- create_v_diwaais.sql
-- v_diwaais -- Sigma-format (DIWAAIS) stock export / inspection view.
-- =============================================================================
-- CC-BRIEF-DASH-FINAL-001 item 7 (2026-07-05): REBUILT sigma-native.
--   Prior def read frozen daily_snapshots (no data past 28 Jun) + Phase-1-legacy
--   products/suppliers. REBUILD, NOT DROP as a feature (Pieter's explicit call).
--   Applied live (migration dashfinal_v_diwaais_sigma_native_rebuild). The DROP
--   in that migration only cleared the old numeric(10,4) column types so the
--   view could be recreated (verified 0 dependents first). Output columns
--   UNCHANGED so any future consumer sees the same shape.
--
-- *** MUST NOT FEED ORDERING. ***
--   Sigma-format export / inspection view only. The ordering engine is Bloom
--   (rpc_bloom_order_dc, canon section 14) -- a plain view cannot carry the
--   life-gate / guarded-ROS / promo logic ordering requires. Zero live consumers
--   as of 2026-07-05.
--
-- SHAPE: current-state snapshot. Always-latest position per (store, product)
--   from l2_stock_position; period_* = MTD sales to each store's latest sale_date
--   from sigma_sales (period_kind='T', txn_kind=1); ean via v_ean_bridge +
--   synthetic COALESCE (R20 addendum); supplier from product_catalog;
--   is_placeholder retired (NULL).
--
-- SCOPE / KNOWN RESIDUAL (R21 section 5 -- earned + surfaced, not hidden):
--   Driven FROM l2_stock_position, so the view is the set of lines that hold a
--   current stock position (an orderable-stock export by construction). A code
--   with MTD sales but NO article + NO position is a dummy / non-catalogue sale
--   key and is correctly outside this export. Live 2026-07-05: exactly one such
--   line on 10116 -- product_code 88889999 (open-price sale key, 1 unit, R89.99)
--   -- so v_diwaais period_sales ties to the sigma_sales MTD direct SUM to the
--   rand on 21355/80175/80176/80579 and is R89.99 under on 10116 by that one
--   non-orderable dummy code. Documented, not force-fitted (a sales-total object
--   must LEFT JOIN the universe per R20; this is a stock-position export, a
--   different job).
-- =============================================================================

DROP VIEW IF EXISTS public.v_diwaais;

CREATE VIEW public.v_diwaais AS
WITH mtd AS (
  SELECT ss.store_code, ss.product_code,
         sum(ss.qty)            AS period_qty,
         sum(ss.cost_value)     AS period_cost,
         sum(ss.sales_incl_vat) AS period_sales
  FROM public.sigma_sales ss
  JOIN (
    SELECT store_code, date_trunc('month', MAX(sale_date))::date AS month_start,
           MAX(sale_date) AS max_date
    FROM public.sigma_sales
    WHERE period_kind='T' AND txn_kind=1
    GROUP BY store_code
  ) m ON m.store_code = ss.store_code
     AND ss.sale_date BETWEEN m.month_start AND m.max_date
  WHERE ss.period_kind='T' AND ss.txn_kind=1
  GROUP BY ss.store_code, ss.product_code
),
maxd AS (
  SELECT store_code, MAX(sale_date) AS snapshot_date
  FROM public.sigma_sales WHERE period_kind='T' AND txn_kind=1
  GROUP BY store_code
)
SELECT
  sp.store_code,
  COALESCE(b.ean, LPAD(sp.store_code,5,'0') || LPAD(sp.product_code::text,8,'0')) AS ean,
  sp.description,
  a.pack_content::text                                   AS size,
  sp.subdept_name                                        AS sub_department,
  pc.supplier_code,
  sp.soh,
  sp.sell_price_incl_vat                                 AS sell_price,
  COALESCE(pc.list_cost, sp.unit_cost)                   AS list_cost,
  COALESCE(mtd.period_sales, 0)                          AS period_sales,
  ros.last_sale_date                                     AS last_sales_date,
  md.snapshot_date,
  COALESCE(mtd.period_qty, 0)                            AS period_qty,
  COALESCE(mtd.period_cost, 0)                           AS period_cost,
  sp.dept_name,
  sp.subdept_name                                        AS sub_dept_name,
  a.record_status                                        AS status,
  NULL::boolean                                          AS is_placeholder,
  pc.supplier_name
FROM public.l2_stock_position sp
LEFT JOIN public.v_ean_bridge b   ON b.store_code = sp.store_code AND b.product_code = sp.product_code
LEFT JOIN public.sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
LEFT JOIN public.l2_rate_of_sale ros ON ros.store_code = sp.store_code AND ros.product_code = sp.product_code
LEFT JOIN mtd  ON mtd.store_code = sp.store_code AND mtd.product_code = sp.product_code
LEFT JOIN maxd md ON md.store_code = sp.store_code
LEFT JOIN public.product_catalog pc ON pc.store_code = sp.store_code AND pc.ean = b.ean;

GRANT SELECT ON public.v_diwaais TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
