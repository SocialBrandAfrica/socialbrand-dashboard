-- =============================================================================
-- fix_sales_ex_vat_views.sql
--
-- Adds total_sales_ex_vat to v_kpi_by_date, mv_kpi_by_date, and rpc_dept_summary.
--
-- WHY: The Rule Book (SB-INDEX-003 §3) requires ex-VAT sales to be computed
-- per item using each item's own vat_pct from daily_snapshots. Using a flat
-- ÷1.15 divisor on an already-summed total is a Shape 1 audit finding because
-- it applies 15% VAT to zero-rated lines (fresh produce, bread, etc.).
--
-- FORMULA (per item, then aggregated):
--   today_sales_ex_vat = today_sales / (1 + COALESCE(vat_pct, 15) / 100.0)
--
-- NULL vat_pct: defaults to 15 (SA standard rate). In Sigma data, zero-rated
-- lines carry vat_pct = 0 explicitly. NULL only occurs on very old rows
-- predating the PRSSALE vat_pct export. 15 is the safest default.
--
-- DEPLOYMENT ORDER:
--   1. Run Step 1 (v_kpi_by_date) — live immediately, no downtime.
--   2. Run Step 2 (mv_kpi_by_date) — brief unavailability (~30s refresh).
--      Run at low-traffic time.
--   3. Run Step 3 (rpc_dept_summary) — live immediately.
--   4. Run Step 4 (frontend wiring) — deploy after all SQL is confirmed.
--
-- After Step 2, run:
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_kpi_by_date;
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 — v_kpi_by_date (live view, used for single-date KPI queries)
-- ---------------------------------------------------------------------------
-- NOTE: total_sales_ex_vat is appended at the END.
-- CREATE OR REPLACE VIEW only allows adding columns at the end — inserting in the
-- middle causes "cannot change name of view column" because Postgres matches by position.
CREATE OR REPLACE VIEW v_kpi_by_date AS
SELECT
    store_code,
    store_name,
    snapshot_date,
    SUM(today_sales)                                                                    AS total_sales,
    SUM(today_cost)                                                                     AS total_cost,
    SUM(today_qty)                                                                      AS total_qty,
    COUNT(*) FILTER (WHERE soh < 0)                                                    AS neg_soh_count,
    COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0 AND is_placeholder = FALSE)      AS slow_mover_count,
    ROUND(SUM(
        CASE WHEN period_qty = 0 AND soh > 0 AND is_placeholder = FALSE
             THEN soh * COALESCE(unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                      AS capital_tied,
    ROUND(SUM(
        today_sales / (1.0 + COALESCE(vat_pct, 15) / 100.0)
    )::numeric, 2)                                                                      AS total_sales_ex_vat
FROM daily_snapshots
GROUP BY store_code, store_name, snapshot_date;

GRANT SELECT ON v_kpi_by_date TO anon, authenticated;

-- Quick verify: row with both VAT-inclusive and ex-VAT totals
SELECT store_code, snapshot_date, total_sales, total_sales_ex_vat,
       ROUND((1 - total_sales_ex_vat / NULLIF(total_sales, 0)) * 100, 2) AS implied_vat_pct
FROM   v_kpi_by_date
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;
-- Expected: implied_vat_pct should be ~13-14% (slightly below 15% because some zero-rated lines exist)
-- If it is exactly 13.04% (= 1 - 1/1.15), ALL lines are treated as 15% VAT — investigate vat_pct column


-- ---------------------------------------------------------------------------
-- STEP 2 — mv_kpi_by_date (materialized view, used for multi-date KPI queries)
-- Run during low-traffic window. The dashboard shows loading state briefly.
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS mv_kpi_by_date CASCADE;

CREATE MATERIALIZED VIEW mv_kpi_by_date AS
SELECT
    store_code,
    store_name,
    snapshot_date,
    SUM(today_sales)                                                                    AS total_sales,
    ROUND(SUM(
        today_sales / (1.0 + COALESCE(vat_pct, 15) / 100.0)
    )::numeric, 2)                                                                      AS total_sales_ex_vat,
    SUM(today_cost)                                                                     AS total_cost,
    SUM(today_qty)                                                                      AS total_qty,
    COUNT(*) FILTER (WHERE soh < 0)                                                    AS neg_soh_count,
    COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0 AND is_placeholder = FALSE)      AS slow_mover_count,
    ROUND(SUM(
        CASE WHEN period_qty = 0 AND soh > 0 AND is_placeholder = FALSE
             THEN soh * COALESCE(unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                      AS capital_tied
FROM daily_snapshots
GROUP BY store_code, store_name, snapshot_date
ORDER BY store_code, snapshot_date DESC;

CREATE UNIQUE INDEX idx_mv_kpi_store_date ON mv_kpi_by_date (store_code, snapshot_date);
GRANT SELECT ON mv_kpi_by_date TO anon, authenticated;

REFRESH MATERIALIZED VIEW mv_kpi_by_date;


-- ---------------------------------------------------------------------------
-- STEP 3 — rpc_dept_summary (adds total_sales_ex_vat for dept-filtered KPIs)
-- Per Function Change Protocol: check overloads, drop all, recreate.
-- ---------------------------------------------------------------------------
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'rpc_dept_summary';
-- Expected: 1 row. If more, they are overloads and will all be dropped below.

DROP FUNCTION IF EXISTS public.rpc_dept_summary CASCADE;

CREATE FUNCTION public.rpc_dept_summary(
    p_store_codes text[],
    p_dates       text[],
    p_eans        text[] DEFAULT NULL,
    p_subdept     text   DEFAULT NULL
)
RETURNS TABLE(
    dept_name          text,
    total_sales        numeric,
    total_sales_ex_vat numeric,
    total_cost         numeric,
    total_qty          numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        dept_name,
        ROUND(SUM(today_sales)::numeric, 2)                                    AS total_sales,
        ROUND(SUM(today_sales / (1.0 + COALESCE(vat_pct, 15) / 100.0))::numeric, 2) AS total_sales_ex_vat,
        ROUND(SUM(today_cost)::numeric,  2)                                    AS total_cost,
        SUM(today_qty)::numeric                                                AS total_qty
    FROM  daily_snapshots
    WHERE store_code          = ANY(p_store_codes)
      AND snapshot_date        = ANY(p_dates::date[])
      AND today_sales           > 0
      AND (p_eans    IS NULL OR ean           = ANY(p_eans))
      AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
    GROUP BY dept_name
    ORDER BY total_sales DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_dept_summary(text[], text[], text[], text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- STEP 4 — Frontend wiring (after SQL confirmed)
-- Once deployed, update page.jsx to use total_sales_ex_vat:
--
-- In loadViews (mv_kpi_by_date query): add total_sales_ex_vat to .select()
-- In kpiSales useMemo: when filterActive, sum r.total_sales_ex_vat from deptSummary
--                      when whole-store, sum r.total_sales_ex_vat from kpiData
-- In lyKpiSales / wowKpiSales: same pattern for LY/WoW data
-- In Sales KPI card: value = zarShort(kpiSalesExVat) from the DB column
--   NOT kpiSales / 1.15 (that was the Shape 1 violation)
-- basisNote: 'ex-VAT · per-item vat_pct'
-- ---------------------------------------------------------------------------
