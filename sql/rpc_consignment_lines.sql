-- rpc_consignment_lines
-- SB-CC-AUDIT-002 (L2 restructure, 2026-06-08): thin SELECT from l2_consignment_daily.
--
-- Classification (sigma_sales x sigma_articles join, merch_group 610 filter,
-- BREAKFAST + MABELA exclusions, June anchor, item_type) is pre-computed in
-- l2_consignment_daily at nightly refresh time (L2 engine).
-- This RPC is L3 display: no join at fetch, no classification at fetch.
--
-- Signature unchanged for backward compatibility with ConsignmentPanel.jsx and
-- the sigma-lines API route. p_group and p_client are kept but not used --
-- l2_consignment_daily is already pre-filtered for group 610 + 'socialbrand'.
--
-- Pre-June months return 0 rows by design (recycled product codes, R20 class).

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
    description,
    sale_date,
    SUM(sales)::numeric AS sales,
    SUM(qty)::numeric   AS qty
  FROM l2_consignment_daily
  WHERE store_code = p_store
    AND sale_date BETWEEN
        (p_month || '-01')::date
        AND (date_trunc('month', (p_month || '-01')::date)
             + INTERVAL '1 month - 1 day')::date
  GROUP BY description, sale_date
  ORDER BY description, sale_date;
$$;

-- ---------------------------------------------------------------------------
-- Regression check -- must match verified June daily totals to the rand:
--   Jun 1=8110 / Jun 2=4119 / Jun 3=5093 / Jun 4=2179
--   Jun 5=4598 / Jun 6=3957 / Jun 7=2731
-- ---------------------------------------------------------------------------

SELECT
  SUM(sales)               AS total_sales,
  COUNT(DISTINCT description) AS distinct_lines,
  COUNT(DISTINCT sale_date)   AS days_loaded,
  MIN(sale_date)              AS first_date,
  MAX(sale_date)              AS last_date
FROM rpc_consignment_lines('2026-06');
