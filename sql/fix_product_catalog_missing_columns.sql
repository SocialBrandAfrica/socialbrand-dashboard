-- =============================================================================
-- fix_product_catalog_missing_columns.sql
--
-- Run this if create_product_catalog.sql fails with
--   "column plu_raw does not exist"
--
-- Root cause: the table was created in an earlier session before plu_raw and
-- other columns were added to the schema.  CREATE TABLE IF NOT EXISTS skips
-- the entire definition on re-run, so new columns are never added.
--
-- This script adds all columns that may be missing using ADD COLUMN IF NOT
-- EXISTS (no-op when the column already exists -- safe to re-run).
-- After running this, re-run create_product_catalog.sql to create the indexes.
-- =============================================================================

ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS plu_raw               text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS sigma_product_code    text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS dc_product_code       text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS size_label            text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS detail_unit           text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS shelf_label_text      text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS supplier_code         text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS supplier_product_code text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS analysis_group        text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS dept_code             text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS sub_dept_code         text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS list_cost             numeric(12,4);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS last_rcvd_cost        numeric(12,4);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS min_stock_sp          numeric(12,4);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS soh                   numeric(12,3);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS on_order_qty          numeric(12,3);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS status_diwaais        text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS ean_category          text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS description           text;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS sell_price            numeric(12,4);
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS is_plu                boolean NOT NULL DEFAULT false;
ALTER TABLE public.product_catalog ADD COLUMN IF NOT EXISTS loaded_at             timestamptz NOT NULL DEFAULT now();

-- Confirm what was added:
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'product_catalog'
ORDER BY ordinal_position;
