-- =============================================================================
-- stage2_wrap_list_c.sql
-- SB-CC-SEC-001 Stage 2a -- SECURITY DEFINER wrappers for list C tables
-- Branch: sec-001-rls  |  ON PIETER: apply BEFORE stage2_lock_list_c.sql
--
-- Creates 5 RPCs that replace the 4 direct table reads in the dashboard
-- (push_log x2, product_search_index, product_catalog, products).
-- Apply this file first, deploy the front-end, verify panels, THEN lock.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. rpc_push_status()
-- Replaces PushStatusStrip direct push_log read.
-- Returns latest successful push per store (snapshot_date + completed_at).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_push_status();

CREATE OR REPLACE FUNCTION public.rpc_push_status()
RETURNS TABLE (
    store_code    text,
    snapshot_date date,
    completed_at  timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT DISTINCT ON (pl.store_code)
    pl.store_code,
    pl.snapshot_date,
    pl.completed_at
FROM public.push_log pl
WHERE pl.status        = 'SUCCESS'
  AND pl.rows_pushed   > 0
  AND pl.snapshot_date IS NOT NULL
ORDER BY pl.store_code, pl.snapshot_date DESC, pl.completed_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_push_status() TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. rpc_push_available_dates()
-- Replaces page.jsx direct push_log read for date-picker population.
-- Returns distinct snapshot_dates where a successful push landed.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_push_available_dates();

CREATE OR REPLACE FUNCTION public.rpc_push_available_dates()
RETURNS TABLE (snapshot_date date)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT DISTINCT snapshot_date
FROM public.push_log
WHERE status        = 'SUCCESS'
  AND snapshot_date IS NOT NULL
ORDER BY snapshot_date DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_push_available_dates() TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. rpc_product_search_index(p_dept text, p_stores text[])
-- Replaces page.jsx direct product_search_index read.
-- p_dept  = null means all depts; p_stores = null means all stores.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_product_search_index(text, text[]);

CREATE OR REPLACE FUNCTION public.rpc_product_search_index(
    p_dept   text    DEFAULT NULL,
    p_stores text[]  DEFAULT NULL
)
RETURNS TABLE (
    ean         text,
    description text,
    dept        text,
    subdept     text,
    stores      text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT ean, description, dept, subdept, stores
FROM public.product_search_index
WHERE (p_dept   IS NULL OR dept = p_dept)
  AND (p_stores IS NULL OR stores && p_stores);
$$;

GRANT EXECUTE ON FUNCTION public.rpc_product_search_index(text, text[]) TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. rpc_supplier_by_ean(p_stores text[])
-- Replaces page.jsx direct product_catalog read for supplier_name per EAN.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_supplier_by_ean(text[]);

CREATE OR REPLACE FUNCTION public.rpc_supplier_by_ean(p_stores text[])
RETURNS TABLE (
    ean           text,
    supplier_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT ean, supplier_name
FROM public.product_catalog
WHERE store_code = ANY(p_stores)
  AND supplier_name IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_supplier_by_ean(text[]) TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 5. rpc_eans_by_supplier(p_supplier text)
-- Replaces FocusDrilldown.jsx direct products read for supplier EAN lookup.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_eans_by_supplier(text);

CREATE OR REPLACE FUNCTION public.rpc_eans_by_supplier(p_supplier text)
RETURNS TABLE (ean text)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT ean
FROM public.products
WHERE supplier ILIKE '%' || p_supplier || '%';
$$;

GRANT EXECUTE ON FUNCTION public.rpc_eans_by_supplier(text) TO anon, authenticated;
