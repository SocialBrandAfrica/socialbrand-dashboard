-- =============================================================================
-- fix_sparkline_ex_vat.sql
--
-- Adds total_sales_ex_vat to mv_sparkline_14d so the GP% sparkline on the
-- KPI card uses per-item vat_pct instead of a flat divisor.
--
-- mv_sparkline_14d uses CREATE MATERIALIZED VIEW IF NOT EXISTS so it cannot
-- be updated with CREATE OR REPLACE. Must DROP and recreate.
--
-- Safe to run: the MV is rebuilt immediately. Dashboard shows loading briefly.
-- pg_cron refreshes it nightly (already configured via refresh_kpi_view()).
-- =============================================================================


DROP MATERIALIZED VIEW IF EXISTS public.mv_sparkline_14d CASCADE;

CREATE MATERIALIZED VIEW public.mv_sparkline_14d AS
WITH latest_14_dates AS (
    SELECT DISTINCT snapshot_date
    FROM   public.daily_snapshots
    ORDER  BY snapshot_date DESC
    LIMIT  14
)
SELECT
    ds.store_code,
    ds.store_name,
    ds.snapshot_date,
    SUM(ds.today_sales)                                                                     AS total_sales,
    ROUND(SUM(
        ds.today_sales / (1.0 + COALESCE(ds.vat_pct, 15) / 100.0)
    )::numeric, 2)                                                                          AS total_sales_ex_vat,
    SUM(ds.today_cost)                                                                      AS total_cost,
    SUM(ds.today_qty)                                                                       AS total_qty,
    COUNT(*) FILTER (WHERE ds.soh < 0)                                                     AS neg_soh_count,
    COUNT(*) FILTER (WHERE ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE) AS slow_mover_count,
    ROUND(SUM(
        CASE WHEN ds.period_qty = 0 AND ds.soh > 0 AND ds.is_placeholder = FALSE
             THEN ds.soh * COALESCE(ds.unit_cost, 0)
             ELSE 0
        END
    )::numeric, 2)                                                                          AS capital_tied
FROM   public.daily_snapshots ds
WHERE  ds.snapshot_date IN (SELECT snapshot_date FROM latest_14_dates)
GROUP  BY ds.store_code, ds.store_name, ds.snapshot_date
ORDER  BY ds.store_code, ds.snapshot_date ASC;

CREATE UNIQUE INDEX idx_mv_sparkline_store_date
    ON public.mv_sparkline_14d (store_code, snapshot_date);

GRANT SELECT ON public.mv_sparkline_14d TO anon, authenticated;

-- Verify: check total_sales_ex_vat is present and below total_sales
SELECT store_code, snapshot_date,
       total_sales, total_sales_ex_vat,
       ROUND((1 - total_sales_ex_vat / NULLIF(total_sales, 0)) * 100, 2) AS implied_vat_pct
FROM   public.mv_sparkline_14d
WHERE  store_code = '10116'
ORDER  BY snapshot_date DESC
LIMIT  3;
-- Expected: implied_vat_pct ~10-11% (matching v_kpi_by_date result)
