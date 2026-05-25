-- =============================================================================
-- create_product_catalog.sql
--
-- Enrichment table loaded monthly from DIWAAIS2 XLS reports.
-- Provides supplier data, PLU reference list, and cost intelligence
-- that daily_snapshots cannot carry (Sigma PRSSALE doesn't export them).
--
-- Key design decisions:
--   - Primary key is (store_code, ean) using the SYNTHETIC 13-digit EAN.
--     For PLU items: ean = store_code.zfill(5) + plu.zfill(8)
--     For real barcodes: ean = the EAN-13 as-is.
--   - plu_raw stores the original short code (1-8 digits) so the EAN fix
--     query can join daily_snapshots.ean = product_catalog.plu_raw AND
--     daily_snapshots.store_code = product_catalog.store_code
--     using the existing daily_snapshots unique index instead of a full
--     table scan (avoids statement_timeout on 18M rows).
--   - No TOPS stores in this table (TOPS exports no PLU codes).
--
-- Run in Supabase SQL Editor. Safe to re-run (CREATE TABLE IF NOT EXISTS).
-- After creating, run load_plu_reference.py to populate from DIWAAIS2.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.product_catalog (
  -- ── Identity ───────────────────────────────────────────────────────────
  store_code            text        NOT NULL,   -- '10116','80175','21355', etc.
  ean                   text        NOT NULL,   -- always 13-digit (synthetic for PLUs)
  plu_raw               text,                  -- original short PLU e.g. '201110' (NULL for real EANs)
  sigma_product_code    text,                  -- Sigma internal product code (= internal_ref in daily_snapshots)
  dc_product_code       text,                  -- SPAR DC product code

  -- ── Description ────────────────────────────────────────────────────────
  description           text        NOT NULL,
  size_label            text,                  -- e.g. '500ML', '1KG', '750ML'
  detail_unit           text,                  -- e.g. 'KG', 'ML', 'GM', 'EA'
  shelf_label_text      text,                  -- full consumer-facing label (Roosville only)

  -- ── Supplier ───────────────────────────────────────────────────────────
  supplier_code         text,                  -- Sigma supplier ID
  supplier_name         text,                  -- e.g. 'COCA-COLA BEVERAGES SA'
  supplier_product_code text,                  -- supplier's own SKU reference
  analysis_group        text,                  -- Sigma analysis group code

  -- ── Department ─────────────────────────────────────────────────────────
  dept_code             text,                  -- Sigma department number
  sub_dept_code         text,                  -- Sigma sub-department number

  -- ── Pricing & Cost ─────────────────────────────────────────────────────
  sell_price            numeric(12,4),         -- SP at pull date
  list_cost             numeric(12,4),         -- agreed list cost
  last_rcvd_cost        numeric(12,4),         -- actual last delivery cost (Del only)
  min_stock_sp          numeric(12,4),         -- minimum stock level at SP (Del only)

  -- ── Stock snapshot ─────────────────────────────────────────────────────
  soh                   numeric(12,3),         -- SOH at pull time
  on_order_qty          numeric(12,3),         -- units on order at pull time

  -- ── Classification ─────────────────────────────────────────────────────
  status_diwaais        text,                  -- A=active, S=suspended, L=listed-not-received
  is_plu                boolean     NOT NULL DEFAULT false, -- true = synthetic EAN assigned
  ean_category          text,                  -- 'EAN13','EAN_SHORT','PLU','NO_EAN'

  -- ── Audit ──────────────────────────────────────────────────────────────
  pulled_date           date        NOT NULL,  -- date DIWAAIS2 report was pulled
  loaded_at             timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (store_code, ean)
);

-- ── Indexes ───────────────────────────────────────────────────────────────
-- Used by sb_ean_002_fix.sql to join daily_snapshots without a full table scan
CREATE INDEX IF NOT EXISTS product_catalog_plu_raw_idx
  ON public.product_catalog (store_code, plu_raw)
  WHERE plu_raw IS NOT NULL;

-- Supplier lookup
CREATE INDEX IF NOT EXISTS product_catalog_supplier_idx
  ON public.product_catalog (supplier_code);

-- Sigma product code (= internal_ref in daily_snapshots)
CREATE INDEX IF NOT EXISTS product_catalog_sigma_code_idx
  ON public.product_catalog (store_code, sigma_product_code)
  WHERE sigma_product_code IS NOT NULL;

-- ── Grant anon SELECT ──────────────────────────────────────────────────────
GRANT SELECT ON public.product_catalog TO anon;

-- Reload PostgREST schema cache
SELECT pg_notify('pgrst', 'reload schema');

-- ── Verify ────────────────────────────────────────────────────────────────
-- Run after load_plu_reference.py to confirm:
SELECT
  store_code,
  COUNT(*)                                  AS total_products,
  COUNT(*) FILTER (WHERE is_plu)            AS plu_products,
  COUNT(*) FILTER (WHERE NOT is_plu)        AS ean_products,
  COUNT(*) FILTER (WHERE ean_category = 'NO_EAN') AS no_barcode,
  COUNT(DISTINCT supplier_name)             AS unique_suppliers,
  MAX(pulled_date)                          AS last_pull
FROM public.product_catalog
GROUP BY store_code
ORDER BY store_code;
