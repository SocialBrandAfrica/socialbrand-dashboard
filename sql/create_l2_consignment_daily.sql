-- l2_consignment_daily
-- SB-CC-AUDIT-002 (L2 restructure, 2026-06-08)
-- Layer 2 derived table: pre-classified HMR SUSHI consignment lines.
-- Engine classifies once at refresh; rpc_consignment_lines reads only (no join at fetch).
--
-- ANCHOR: sale_date >= '2026-06-01'
--   Pre-June sigma_sales uses recycled 100k-range product codes that do not map
--   to current sigma_articles. Blank before June is by design (R20 class -- same
--   as the recycled-code rule). Do not attempt to recover pre-June via the current
--   code map; it would mis-assign recycled codes to wrong products.
--
-- REFRESH: call refresh_l2_consignment_daily(p_store) nightly after l2_kpi_daily.
-- SCOPE: store 10116 only (HMR SUSHI consignment counter). Extend p_store to other
--   stores only when those stores have a consignment arrangement.
--
-- CLASSIFICATION NOTE (2026-06-08): as of June 2026 all sold products classify as
--   item_type='c' (chinese/other) because the current sigma_ean_master barcode
--   assignments for the post-recycling product_codes are not in the 200000+ range
--   that the SUSHI_PLUS PLU set expects. The column is preserved; it will populate
--   correctly once barcode data is reconciled. Totals are unaffected.
--
-- Rule 19: DROP + clean CREATE. No ALTER TABLE workarounds.

DROP TABLE IF EXISTS l2_consignment_daily CASCADE;

CREATE TABLE l2_consignment_daily (
  id           bigserial     PRIMARY KEY,
  client_id    text          NOT NULL DEFAULT 'socialbrand',
  store_code   text          NOT NULL,
  sale_date    date          NOT NULL,
  product_code bigint        NOT NULL,
  description  text          NOT NULL,
  item_type    text          NOT NULL CHECK (item_type IN ('s', 'c')),
  -- s = sushi (PLU in SUSHI_PLUS set), c = chinese/other
  sales        numeric(12,2) NOT NULL DEFAULT 0,
  qty          numeric(10,4) NOT NULL DEFAULT 0,
  commission   numeric(12,2) NOT NULL DEFAULT 0,   -- 10% of sales
  owed         numeric(12,2) NOT NULL DEFAULT 0,   -- 90% of sales
  CONSTRAINT l2_consignment_daily_uq UNIQUE (store_code, sale_date, product_code)
);

CREATE INDEX l2_consignment_daily_store_date
  ON l2_consignment_daily (store_code, sale_date);

COMMENT ON TABLE l2_consignment_daily IS
  'Pre-classified HMR SUSHI consignment lines. L2 engine output. '
  'Anchor: sale_date >= 2026-06-01. Refreshed nightly by refresh_l2_consignment_daily().';

-- ---------------------------------------------------------------------------
-- refresh_l2_consignment_daily(p_store)
--
-- Deletes then re-inserts the current calendar month for p_store.
-- Historical months are committed and untouched -- safe to re-run at any time.
-- Initial run (deploy day) fills June 2026 (current month = anchor month).
-- Subsequent nightly runs keep the current month current; prior months stay.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS refresh_l2_consignment_daily(text);

CREATE OR REPLACE FUNCTION refresh_l2_consignment_daily(
  p_store text DEFAULT '10116'
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_month_start date    := date_trunc('month', CURRENT_DATE)::date;
  v_month_end   date    := (date_trunc('month', CURRENT_DATE)
                             + INTERVAL '1 month - 1 day')::date;
  v_inserted    integer := 0;
BEGIN
  -- Remove current-month rows for this store so we can re-derive cleanly
  DELETE FROM l2_consignment_daily
  WHERE store_code = p_store
    AND sale_date BETWEEN v_month_start AND v_month_end;

  -- CTE pre-classifies all articles for this store (merch_group 610, exclusions applied).
  -- The barcode -> PLU lookup (barcode - 200000 in SUSHI_PLUS) runs once per article,
  -- not per sales row, keeping the aggregate fast.
  INSERT INTO l2_consignment_daily (
    client_id, store_code, sale_date, product_code, description,
    item_type, sales, qty, commission, owed
  )
  WITH classified_articles AS (
    SELECT
      a.store_code,
      a.client_id,
      a.product_code,
      a.description,
      COALESCE((
        SELECT CASE
          WHEN (em.barcode - 200000) = ANY(ARRAY[
            653,650,895,888,863,851,846,844,843,841,835,533,831,824,818,810,792,790,
            785,778,773,767,766,749,747,832,762,737,722,744,718,715,9677,710,700,736,
            632,638,597,307,308,309,889,924,930,599,699,694,693,696,695,697,698,840,
            836,897,834,809,806,803,784,771,748,753
          ]::bigint[])
          THEN 's' ELSE 'c' END
        FROM sigma_ean_master em
        WHERE em.store_code   = a.store_code
          AND em.client_id    = a.client_id
          AND em.product_code = a.product_code
        LIMIT 1
      ), 'c') AS item_type
    FROM sigma_articles a
    WHERE a.store_code     = p_store
      AND a.client_id      = 'socialbrand'
      AND a.merch_group_nr = 610
      AND a.description NOT ILIKE 'BREAKFAST%'
      AND a.description NOT ILIKE 'MABELA%'
  )
  SELECT
    'socialbrand'                                    AS client_id,
    p_store                                          AS store_code,
    s.sale_date,
    ca.product_code,
    ca.description,
    ca.item_type,
    ROUND(SUM(s.sales_incl_vat)::numeric, 2)         AS sales,
    ROUND(SUM(s.qty)::numeric,            4)         AS qty,
    ROUND(SUM(s.sales_incl_vat)::numeric * 0.10, 2) AS commission,
    ROUND(SUM(s.sales_incl_vat)::numeric * 0.90, 2) AS owed
  FROM sigma_sales s
  JOIN classified_articles ca
    ON  ca.store_code   = s.store_code
    AND ca.client_id    = s.client_id
    AND ca.product_code = s.product_code
  WHERE s.store_code  = p_store
    AND s.client_id   = 'socialbrand'
    AND s.period_kind = 'T'
    AND s.txn_kind    = 1
    AND s.sale_date  >= '2026-06-01'                 -- anchor: combo-launch boundary
    AND s.sale_date BETWEEN v_month_start AND v_month_end
  GROUP BY ca.product_code, ca.description, ca.item_type, s.sale_date;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

-- Grant read to anon so the RPC (SECURITY DEFINER) can SELECT
GRANT SELECT ON l2_consignment_daily TO anon;

-- ---------------------------------------------------------------------------
-- Initial population -- run immediately after creating table + function
-- ---------------------------------------------------------------------------

SELECT refresh_l2_consignment_daily('10116') AS rows_inserted;

-- ---------------------------------------------------------------------------
-- Verification -- run after population, before deploying rpc_consignment_lines
-- June daily totals must match verified raw sigma_sales to the rand:
--   Jun 1=8110 / Jun 2=4119 / Jun 3=5093 / Jun 4=2179
--   Jun 5=4598 / Jun 6=3957 / Jun 7=2731
-- ---------------------------------------------------------------------------

SELECT
  sale_date,
  SUM(sales)                                       AS total_sales,
  SUM(commission)                                  AS total_commission,
  SUM(owed)                                        AS total_owed,
  COUNT(DISTINCT product_code)                     AS lines,
  COUNT(DISTINCT item_type)                        AS types_present
FROM l2_consignment_daily
WHERE store_code = '10116'
GROUP BY sale_date
ORDER BY sale_date;
