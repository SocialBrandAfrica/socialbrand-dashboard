-- rpc_consignment_lines
-- SB-CC-PMINI-002: per-line per-day sales from sigma_sales (Layer 1)
-- Join: sigma_sales -> sigma_articles on store + client + product_code
-- Filter: merch_group_nr 610 (HMR Sushi counter), period_kind='T', txn_kind=1
-- Excludes: BREAKFAST and MABELA (misfiled into 610, not consignment)
-- Currency: data only as current as the nightly sigma_sales delta (SB-CC-ROLLOUT-001)

DROP FUNCTION IF EXISTS rpc_consignment_lines(text, text, integer, text);

CREATE FUNCTION rpc_consignment_lines(
  p_month  text,
  p_store  text    DEFAULT '10116',
  p_group  integer DEFAULT 610,
  p_client text    DEFAULT 'socialbrand'
)
RETURNS TABLE (
  description text,
  sale_date   date,
  sales       numeric,
  qty         numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    a.description,
    s.sale_date,
    SUM(s.sales_incl_vat)  AS sales,
    SUM(s.qty)              AS qty
  FROM sigma_sales s
  JOIN sigma_articles a
    ON  a.store_code    = s.store_code
    AND a.client_id     = s.client_id
    AND a.product_code  = s.product_code
  WHERE s.store_code     = p_store
    AND s.client_id      = p_client
    AND a.merch_group_nr = p_group
    AND s.sale_date BETWEEN
          (p_month || '-01')::date
          AND (date_trunc('month', (p_month || '-01')::date) + INTERVAL '1 month - 1 day')::date
    AND s.period_kind = 'T'
    AND s.txn_kind    = 1
    AND a.description NOT ILIKE 'BREAKFAST%'
    AND a.description NOT ILIKE 'MABELA%'
  GROUP BY a.description, s.sale_date
  ORDER BY a.description, s.sale_date;
$$;

-- Verification: run after creating -- must return rows, totals must reconcile
-- June MTD expected: cash R19,501 (excl BREAKFAST), sushi ~R16,128, Chinese ~R3,373
SELECT
  SUM(sales)                                          AS total_sales,
  COUNT(DISTINCT description)                         AS distinct_lines,
  COUNT(DISTINCT sale_date)                           AS days_loaded,
  MIN(sale_date)                                      AS first_date,
  MAX(sale_date)                                      AS last_date
FROM rpc_consignment_lines('2026-06');
