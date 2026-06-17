-- =============================================================================
-- HOLD LIFTED (2026-06-02, SB-AP-004 Option C).
-- Capital Tied definition is now stable: exclude PRODUCTION, NON_STOCK, and
-- fresh impossible-stock via classify_snapshot_item() and is_fresh_perishable()
-- (deployed in sb_ap_004_c_interim_exclusion.sql).
-- Run sb_ap_004_c_interim_exclusion.sql FIRST, then run this file.
-- =============================================================================
-- SB-CC-DEPT-KPI-001 / SB-CC-SEL-001 Part 3 -- Add dept-level capital_tied to rpc_dept_summary
--
-- Why: the KPI cards make Sales / GP / Qty respect the dept (and sub-dept / EAN)
-- selection via rpc_dept_summary, but Capital Tied and Stock Turn had no
-- dept-level source -- they read whole-store capital_tied from mv_kpi_by_date.
-- With a dept selected, Stock Turn became a mismatched ratio (dept COGS over
-- whole-store capital) and Capital Tied stayed at the whole-store figure.
--
-- This adds capital_tied to rpc_dept_summary, computed point-in-time at each
-- store's latest snapshot within p_dates -- the same basis as the headline
-- card (latest position, not a period sum) and the same formula as
-- mv_kpi_by_date.capital_tied:
--     period_qty = 0 AND soh > 0 AND NOT is_placeholder  ->  soh * unit_cost
--
-- Adding a column changes the RETURNS TABLE signature, so the function must be
-- dropped and recreated (CREATE OR REPLACE cannot change the return type).
-- Existing callers select named columns, so the extra column is non-breaking.
--
-- Run in Supabase SQL Editor. Returns nothing destructive beyond the function
-- redefinition. Pairs with the frontend change in src/app/page.jsx (SB-CC-PUSH
-- session 2026-05-30) which already reads r.capital_tied defensively.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text, text[]);

CREATE FUNCTION public.rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_subdept     text   DEFAULT NULL,
    p_eans        text[] DEFAULT NULL
)
RETURNS TABLE(
    dept_name    text,
    total_sales  numeric,
    total_cost   numeric,
    total_qty    numeric,
    capital_tied numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH latest AS (
        SELECT store_code, MAX(snapshot_date) AS d
        FROM   daily_snapshots
        WHERE  store_code       = ANY(p_store_codes)
          AND  snapshot_date::text = ANY(p_dates)
        GROUP  BY store_code
    )
    SELECT
        ds.dept_name,
        ROUND(SUM(ds.today_sales)::numeric, 2)  AS total_sales,
        ROUND(SUM(ds.today_cost)::numeric,  2)  AS total_cost,
        SUM(ds.today_qty)::numeric              AS total_qty,
        -- Point-in-time capital_tied: matches Option C definition in v_kpi_by_date.
        -- Excludes PRODUCTION, NON_STOCK, and fresh impossible-stock.
        -- Requires classify_snapshot_item() and is_fresh_perishable() (deployed in
        -- sb_ap_004_c_interim_exclusion.sql).
        ROUND(SUM(
            CASE WHEN ds.snapshot_date = l.d
                  AND ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE
                  AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh)
                      IS NULL
                  AND NOT (
                      is_fresh_perishable(ds.dept_name, ds.sub_dept_name)
                      AND (ds.last_sales_date_iso IS NULL
                           OR ds.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
                  )
                 THEN ds.soh * COALESCE(ds.unit_cost, 0)
                 ELSE 0
            END
        )::numeric, 2)                          AS capital_tied
    FROM   daily_snapshots ds
    JOIN   latest l ON l.store_code = ds.store_code
    WHERE  ds.store_code          = ANY(p_store_codes)
      AND  ds.snapshot_date::text = ANY(p_dates)
      AND  (p_subdept IS NULL OR ds.sub_dept_name = p_subdept)
      AND  (p_eans    IS NULL OR ds.ean            = ANY(p_eans))
    GROUP  BY ds.dept_name
    ORDER  BY ds.dept_name;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text, text[])
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');

-- Verify: capital_tied should be present and non-negative; total_sales unchanged
-- from the previous definition for the same params.
-- SELECT * FROM rpc_dept_summary(ARRAY['10116'], ARRAY['2026-05-29']) ORDER BY total_sales DESC LIMIT 5;
