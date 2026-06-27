-- l2_consignment_daily
-- SB-CC-AUDIT-002 (L2 restructure, 2026-06-08)
-- 2026-06-10: function fixed for sigma_ean_master.barcode bigint->text migration.
-- 2026-06-17 (SB-CC-PMINI-WIRE-001): item_type RE-SOURCED off the Sigma-native
--   scan refs via v_consignment_catalog (R25). The deprecated sigma_ean_master
--   read is GONE. See the CLASSIFICATION NOTE below.
--   STATUS: STAGED — DO NOT RUN until PM signs the Pulse Mini close-out plan.
--   Requires create_v_consignment_catalog.sql to be deployed FIRST.
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
-- CLASSIFICATION NOTE (UPDATED 2026-06-17): item_type s/c is now stamped from
--   v_consignment_catalog, which reads the Sigma-native scale PLU
--   (sigma_scan_refs DBREFE 200000+ code minus 200000) vs the SUSHI_PLUS menu set.
--   This REPLACES the old sigma_ean_master.barcode path, which had collapsed every
--   line to 'c' after the product-code recycling (the 200000+ scale barcodes were
--   no longer present in sigma_ean_master). Proven live 2026-06-17: 22 sushi /
--   21 chinese on the 43 June-sold products (was 0 / 43). Totals are unaffected.
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

  -- Classification is pre-computed once in v_consignment_catalog (the single home
  -- of the sushi/Chinese rule, R21) off the Sigma-native scale PLU. The refresh
  -- just reads it -- no inline barcode lookup, no sigma_ean_master.
  INSERT INTO l2_consignment_daily (
    client_id, store_code, sale_date, product_code, description,
    item_type, sales, qty, commission, owed
  )
  WITH classified_articles AS (
    SELECT
      cat.store_code,
      cat.client_id,
      cat.product_code,
      cat.description,
      cat.item_type
    FROM v_consignment_catalog cat
    WHERE cat.store_code = p_store
      AND cat.client_id  = 'socialbrand'
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
