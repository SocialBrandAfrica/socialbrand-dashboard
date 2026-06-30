-- =============================================================================
-- create_rpc_search_products.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 9.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 canonical (daily_snapshots-driven).
-- =============================================================================
-- WHY:
--   Old function was SELECT ... FROM daily_snapshots WHERE snapshot_date = p_date::date.
--   daily_snapshots frozen at 2026-06-28; any search for a date >= 2026-06-29
--   returns 0 rows.
--
-- WHAT CHANGES:
--   Driver: sigma_articles (article master, all ranged products at the store).
--   ean: LEFT JOIN v_ean_bridge + COALESCE(b.ean, synthetic) -- R20 addendum.
--   today_qty/sales/cost: sigma_sales for p_date only.
--   period_qty/cost/sales: sigma_sales MTD (month-start to p_date).
--   soh + unit_cost: l2_stock_position (current engine snapshot).
--   last_sales_date_iso: l2_rate_of_sale.last_sale_date.
--   dept_name: sigma_departments via sigma_articles.department_nr.
--   sub_dept_name: sigma_subdepts via sigma_articles.merch_group_nr.
--   description: sigma_articles.description.
--   internal_ref: sigma_articles.product_code::text (Sigma article number).
--   status: sigma_articles.record_status.
--   size: sigma_articles.pack_content.
--   unit: sigma_articles.unit.
--   sell_price: sigma_articles.sell_price_incl_vat.
--   store_name: stores.store_name.
--   is_placeholder: NULL (daily_snapshots concept retired).
--   daily_snapshots dependency dropped entirely.
--
-- SEARCH MATCHES: ean, description, product_code (internal_ref), supplier_name
--   via product_catalog (same coverage as before).
--
-- SYNTHETIC EAN fallback: LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')
--   matches the old daily_snapshots PLU-expansion convention (13 chars).
--
-- R22: products with no sales on p_date still appear (with today_* = 0).
--   NULLs for soh/unit_cost when l2_stock_position has no row (new products).
-- GRANT: anon + authenticated EXECUTE.
-- Function change protocol: DROP before CREATE (no overload -- single signature).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_search_products(text[], text, text, text[], text, integer);

CREATE FUNCTION public.rpc_search_products(
  p_store_codes  text[],
  p_date         text,
  p_query        text,
  p_dept_names   text[]  DEFAULT NULL::text[],
  p_subdept      text    DEFAULT NULL::text,
  p_limit        integer DEFAULT 100
)
RETURNS TABLE(
  ean                text,
  description        text,
  internal_ref       text,
  dept_name          text,
  sub_dept_name      text,
  sell_price         numeric,
  soh                numeric,
  today_qty          numeric,
  today_sales        numeric,
  today_cost         numeric,
  period_qty         numeric,
  period_cost        numeric,
  period_sales       numeric,
  last_sales_date_iso text,
  status             text,
  snapshot_date      text,
  store_code         text,
  store_name         text,
  size               text,
  unit               text,
  unit_cost          numeric,
  is_placeholder     boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
WITH
today_s AS (
  SELECT
    ss.store_code,
    ss.product_code,
    round(sum(ss.qty),            2) AS today_qty,
    round(sum(ss.sales_incl_vat), 2) AS today_sales,
    round(sum(ss.cost_value),     2) AS today_cost
  FROM public.sigma_sales ss
  WHERE ss.store_code  = ANY(p_store_codes)
    AND ss.sale_date   = p_date::date
    AND ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY ss.store_code, ss.product_code
),
period_s AS (
  SELECT
    ss.store_code,
    ss.product_code,
    round(sum(ss.qty),            2) AS period_qty,
    round(sum(ss.cost_value),     2) AS period_cost,
    round(sum(ss.sales_incl_vat), 2) AS period_sales
  FROM public.sigma_sales ss
  WHERE ss.store_code  = ANY(p_store_codes)
    AND ss.sale_date   BETWEEN date_trunc('month', p_date::date)::date AND p_date::date
    AND ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY ss.store_code, ss.product_code
)
SELECT
  COALESCE(b.ean,
    LPAD(a.store_code, 5, '0') || LPAD(a.product_code::text, 8, '0'))  AS ean,
  a.description,
  a.product_code::text                                                   AS internal_ref,
  COALESCE(sd.name, 'UNMAPPED')                                         AS dept_name,
  sub.name                                                               AS sub_dept_name,
  a.sell_price_incl_vat                                                  AS sell_price,
  sp.soh,
  COALESCE(ts.today_qty,   0)                                            AS today_qty,
  COALESCE(ts.today_sales, 0)                                            AS today_sales,
  COALESCE(ts.today_cost,  0)                                            AS today_cost,
  COALESCE(ps.period_qty,  0)                                            AS period_qty,
  COALESCE(ps.period_cost, 0)                                            AS period_cost,
  COALESCE(ps.period_sales,0)                                            AS period_sales,
  ros.last_sale_date::text                                               AS last_sales_date_iso,
  a.record_status                                                        AS status,
  p_date                                                                 AS snapshot_date,
  a.store_code,
  st.store_name,
  a.pack_content                                                         AS size,
  a.unit,
  sp.unit_cost,
  NULL::boolean                                                          AS is_placeholder
FROM public.sigma_articles a
LEFT JOIN public.v_ean_bridge b
  ON  b.store_code   = a.store_code
  AND b.product_code = a.product_code
LEFT JOIN public.sigma_departments sd
  ON  sd.store_code    = a.store_code
  AND sd.department_nr = a.department_nr
LEFT JOIN public.sigma_subdepts sub
  ON  sub.store_code     = a.store_code
  AND sub.merch_group_nr = a.merch_group_nr
LEFT JOIN public.l2_stock_position sp
  ON  sp.store_code   = a.store_code
  AND sp.product_code = a.product_code
LEFT JOIN public.l2_rate_of_sale ros
  ON  ros.store_code   = a.store_code
  AND ros.product_code = a.product_code
LEFT JOIN public.stores st
  ON  st.store_code = a.store_code
LEFT JOIN today_s ts
  ON  ts.store_code   = a.store_code
  AND ts.product_code = a.product_code
LEFT JOIN period_s ps
  ON  ps.store_code   = a.store_code
  AND ps.product_code = a.product_code
WHERE a.store_code = ANY(p_store_codes)
  AND (
      COALESCE(b.ean,
        LPAD(a.store_code, 5, '0') || LPAD(a.product_code::text, 8, '0')
      )                       ILIKE '%' || p_query || '%'
   OR a.description           ILIKE '%' || p_query || '%'
   OR a.product_code::text    ILIKE '%' || p_query || '%'
   OR EXISTS (
        SELECT 1
        FROM   public.product_catalog pc
        WHERE  pc.store_code = a.store_code
          AND  NULLIF(regexp_replace(pc.sigma_product_code, '\D', '', 'g'), '')::bigint
               = a.product_code
          AND  pc.supplier_name ILIKE '%' || p_query || '%'
        LIMIT  1
      )
  )
  AND (p_dept_names IS NULL OR COALESCE(sd.name, 'UNMAPPED') = ANY(p_dept_names))
  AND (p_subdept    IS NULL OR sub.name = p_subdept)
ORDER BY a.description ASC
LIMIT p_limit;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_search_products(text[], text, text, text[], text, integer)
  TO anon, authenticated;
