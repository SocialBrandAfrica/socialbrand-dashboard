-- =============================================================================
-- BUG-2 FIX: Add sell_price, unit_cost, vat_pct to rpc_product_detail
--            Add sell_price, unit_cost to rpc_focus_chart
--            (SB-AUD-002)
--
-- rpc_product_detail previously returned: snapshot_date, store_code,
-- store_name, today_qty, today_sales, today_cost, soh, sell_price.
-- Missing: unit_cost and vat_pct — needed to compute GP% on an ex-VAT basis
-- in the per-store summary table.
--
-- rpc_focus_chart previously returned no pricing at all — sell_price and
-- unit_cost are needed for the Focus Area multi-item comparison card.
--
-- GP% formula (SocialBrand SPAR scorecard, ex-VAT basis):
--   ex_vat_sell = sell_price / (1 + vat_pct/100)   -- typically /1.15
--   GP%         = (ex_vat_sell - unit_cost) / ex_vat_sell * 100
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. rpc_product_detail — add unit_cost + vat_pct to RETURNS + SELECT
-- ---------------------------------------------------------------------------
-- PostgreSQL does not allow CREATE OR REPLACE to change a function's return
-- type. DROP first, then recreate. GRANT is re-applied immediately after.
DROP FUNCTION IF EXISTS rpc_product_detail(text, text[], text[]);

CREATE OR REPLACE FUNCTION rpc_product_detail(
    p_ean         text,
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    snapshot_date  text,
    store_code     text,
    store_name     text,
    today_qty      numeric,
    today_sales    numeric,
    today_cost     numeric,
    soh            numeric,
    sell_price     numeric,
    unit_cost      numeric,
    vat_pct        numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        snapshot_date::text,
        store_code,
        store_name,
        today_qty::numeric,
        today_sales::numeric,
        today_cost::numeric,
        soh::numeric,
        sell_price::numeric,
        unit_cost::numeric,
        vat_pct::numeric
    FROM  daily_snapshots
    WHERE ean                = p_ean
      AND store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    ORDER BY snapshot_date ASC;
$$;

GRANT EXECUTE ON FUNCTION rpc_product_detail(text, text[], text[])
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. rpc_focus_chart — add sell_price + unit_cost to RETURNS + SELECT
-- ---------------------------------------------------------------------------
-- Same reason — return type changes require DROP first.
DROP FUNCTION IF EXISTS rpc_focus_chart(text[], text[], text[]);

CREATE OR REPLACE FUNCTION rpc_focus_chart(
    p_eans        text[],
    p_store_codes text[],
    p_dates       text[]
)
RETURNS TABLE(
    ean           text,
    description   text,
    size          text,
    unit          text,
    snapshot_date text,
    store_code    text,
    today_sales   numeric,
    today_qty     numeric,
    soh           numeric,
    sell_price    numeric,
    unit_cost     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        description,
        size,
        unit,
        snapshot_date::text,
        store_code,
        ROUND(today_sales::numeric, 2) AS today_sales,
        today_qty::numeric             AS today_qty,
        soh::numeric                   AS soh,
        sell_price::numeric            AS sell_price,
        unit_cost::numeric             AS unit_cost
    FROM  daily_snapshots
    WHERE ean                = ANY(p_eans)
      AND store_code         = ANY(p_store_codes)
      AND snapshot_date::text = ANY(p_dates)
    ORDER BY snapshot_date ASC;
$$;

GRANT EXECUTE ON FUNCTION rpc_focus_chart(text[], text[], text[])
    TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname  = 'public'
  AND  p.proname IN ('rpc_product_detail', 'rpc_focus_chart')
ORDER BY p.proname;
-- Expected: 2 rows — rpc_focus_chart and rpc_product_detail
