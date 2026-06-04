-- =============================================================================
-- O1 FIX (PULSE-VALIDATION-20260604, SB-VAL-001) -- rpc_dept_summary overload
-- collision returns PGRST203 -> "Sales by Department" shows "No sales data".
--
-- Root cause (confirmed live, HTTP 300 PGRST203):
--   TWO overloads of rpc_dept_summary coexist in the database --
--     (a) public.rpc_dept_summary(p_store_codes, p_dates, p_eans, p_subdept)
--         from fix_index_rule_dept_rpcs.sql -- index-SAFE, 4 cols, no capital.
--     (b) public.rpc_dept_summary(p_store_codes, p_dates, p_subdept, p_eans)
--         from sb_cc_dept_kpi_001_capital_in_dept_summary.sql -- 5 cols with
--         capital_tied, but index-UNSAFE (snapshot_date::text = ANY(p_dates))
--         AND it re-introduced the Rule 4 cast that the fix had removed.
--   sb_cc_dept_kpi_001 tried to DROP signature (text[],text[],text,text[]) but
--   the live version was (text[],text[],text[],text), so the DROP missed and
--   CREATE added a second overload. PostgREST cannot choose between them on the
--   named call rpc_dept_summary(p_store_codes,p_dates,p_subdept,p_eans) -> 300.
--
-- Fix: drop BOTH explicit signatures, recreate exactly ONE canonical function.
--   - Keeps capital_tied (the SB-CC-DEPT-KPI-001 feature).
--   - Uses the index-safe predicate snapshot_date = ANY(p_dates::date[])
--     on BOTH the latest CTE and the main query (CLAUDE-CODE-RULES Rule 4).
--   - Canonical param order (p_store_codes, p_dates, p_subdept, p_eans) matches
--     the frontend named call in src/app/page.jsx (rpc_dept_summary block).
--
-- Calls the 4-arg classify_snapshot_item(dept, subdept, soh, last_sold) -- the
-- patch1 (never-sold) overload that v_kpi_by_date already uses. This is required
-- on two counts: (1) a 3-arg call is now ambiguous against the 4-arg DEFAULT NULL
-- overload (42725 not unique), and (2) dept-level capital_tied must use the SAME
-- exclusion expression as v_kpi_by_date so dept capital reconciles to the
-- headline. The CASE below is a line-for-line mirror of v_kpi_by_date.capital_tied.
--
-- Depends on classify_snapshot_item(text,text,numeric,date) and
-- is_fresh_perishable() -- both already live (v_kpi_by_date uses them).
--
-- Run in Supabase SQL Editor. Then hard-refresh the dashboard.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- STEP 1 -- Drop BOTH overloads (Rule 3: never leave two callable signatures)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text[], text) CASCADE;
DROP FUNCTION IF EXISTS public.rpc_dept_summary(text[], text[], text, text[]) CASCADE;

-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate the single canonical function
-- ---------------------------------------------------------------------------
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
        WHERE  store_code    = ANY(p_store_codes)
          AND  snapshot_date = ANY(p_dates::date[])   -- index-safe (Rule 4)
        GROUP  BY store_code
    )
    SELECT
        ds.dept_name,
        ROUND(SUM(ds.today_sales)::numeric, 2)  AS total_sales,
        ROUND(SUM(ds.today_cost)::numeric,  2)  AS total_cost,
        SUM(ds.today_qty)::numeric              AS total_qty,
        -- Point-in-time capital_tied: matches Option C definition in v_kpi_by_date.
        -- Excludes PRODUCTION, NON_STOCK, and fresh impossible-stock.
        ROUND(SUM(
            CASE WHEN ds.snapshot_date = l.d
                  AND ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE
                  AND classify_snapshot_item(ds.dept_name, ds.sub_dept_name, ds.soh, ds.last_sales_date_iso)
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
    WHERE  ds.store_code    = ANY(p_store_codes)
      AND  ds.snapshot_date = ANY(p_dates::date[])    -- index-safe (Rule 4)
      AND  (p_subdept IS NULL OR ds.sub_dept_name = p_subdept)
      AND  (p_eans    IS NULL OR ds.ean            = ANY(p_eans))
    GROUP  BY ds.dept_name
    ORDER  BY ds.dept_name;
$$;

-- ---------------------------------------------------------------------------
-- STEP 3 -- Re-grant EXECUTE (DROP CASCADE discards grants)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text, text[])
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- STEP 4 -- Reload PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');

-- ---------------------------------------------------------------------------
-- VERIFY -- expect EXACTLY 1 row (no overloads), then hard-refresh dashboard
-- ---------------------------------------------------------------------------
SELECT
    p.proname                        AS function_name,
    pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'rpc_dept_summary'
ORDER  BY p.proname;
-- Expected: 1 row. Sales by Department should load in under 3 seconds.
