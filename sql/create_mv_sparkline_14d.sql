-- =============================================================================
-- create_mv_sparkline_14d.sql
-- SB-CC-DASH-SOURCE-002 -- mv_sparkline_14d sales-facts migration onto sigma_sales.
-- (last Phase-2 sales matview; mirrors create_mv_kpi_by_date.sql Step 2.)
-- =============================================================================
-- WHAT THIS DOES:
--   Re-sources the SALES FACTS of mv_sparkline_14d (KPI-card sparklines,
--   independent of the active date filter) onto sigma_sales (DBUMBA exact
--   ledger, period_kind='T' AND txn_kind=1) -- native VAT:
--       total_sales        = SUM(sales_incl_vat)
--       total_sales_ex_vat = SUM(sales_incl_vat - vat_value)   (fixes the prior
--                            flat-1.15 divisor in fix_sparkline_ex_vat.sql)
--       total_cost         = SUM(cost_value)  (dEKUmsatz)
--
-- HELD on PRSSALE / daily_snapshots (unchanged -- coordinated stock-facts step
--   migrates these later):
--       total_qty        (Sigma qty diverges ~20% at 10116; unit def unconfirmed)
--       neg_soh_count, slow_mover_count, capital_tied  (this matview's EXISTING
--           formulas, intentionally untouched -- note sparkline never carried the
--           classify_snapshot_item / is_fresh_perishable exclusions and still
--           does not, by design, until the stock-facts step aligns all matviews).
--
-- DATE SET: driver stays daily_snapshots (latest 14 distinct snapshot_dates).
--   Sparkline is a 14-day operational glance and must stay EOD-complete +
--   stock-bearing; sourcing the 14 dates off sigma_sales would risk an intraday
--   partial current day and would carry NULL stock facts. Sales facts are
--   LEFT JOINed on (store_code, date); on the rare missed-EOD day inside the
--   last 14 (no daily_snapshots row) that day is absent from the glance -- the
--   recovered historical missed-EOD days (05-29 etc.) live in mv_kpi_by_date,
--   not in the rolling 14.
--
-- Reconcile: sales CTE is byte-identical to mv_kpi_by_date's; sparkline is a
--   date subset, so it reconciles to the rand by construction (delta 0.00 x5).
--
-- Rule 19: DROP + clean CREATE. anon/authenticated SELECT. CONCURRENTLY refresh
--   preserved via the unique index. refresh_kpi_view() already refreshes this MV
--   nightly -- not touched here.
-- =============================================================================
SET statement_timeout = '10min';

DROP MATERIALIZED VIEW IF EXISTS public.mv_sparkline_14d CASCADE;

CREATE MATERIALIZED VIEW public.mv_sparkline_14d AS
WITH latest_14_dates AS (
    SELECT DISTINCT snapshot_date
    FROM   public.daily_snapshots
    ORDER  BY snapshot_date DESC
    LIMIT  14
),
stock AS (
    SELECT
        ds.store_code,
        ds.store_name,
        ds.snapshot_date,
        SUM(ds.today_qty)                                                                       AS total_qty,
        COUNT(*) FILTER (WHERE ds.soh < 0::numeric)                                             AS neg_soh_count,
        COUNT(*) FILTER (WHERE ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false) AS slow_mover_count,
        ROUND(SUM(
            CASE WHEN ds.period_qty = 0::numeric AND ds.soh > 0::numeric AND ds.is_placeholder = false
                 THEN ds.soh * COALESCE(ds.unit_cost, 0::numeric)
                 ELSE 0::numeric
            END)::numeric, 2)                                                                   AS capital_tied
    FROM   public.daily_snapshots ds
    WHERE  ds.snapshot_date IN (SELECT snapshot_date FROM latest_14_dates)
    GROUP  BY ds.store_code, ds.store_name, ds.snapshot_date
),
sales AS (
    SELECT
        ss.store_code,
        ss.sale_date,
        ROUND(SUM(ss.sales_incl_vat), 2)                  AS total_sales,
        ROUND(SUM(ss.sales_incl_vat - ss.vat_value), 2)   AS total_sales_ex_vat,
        ROUND(SUM(ss.cost_value), 2)                      AS total_cost
    FROM   public.sigma_sales ss
    WHERE  ss.period_kind = 'T' AND ss.txn_kind = 1
      AND  ss.sale_date IN (SELECT snapshot_date FROM latest_14_dates)
    GROUP  BY ss.store_code, ss.sale_date
)
SELECT
    st.store_code,
    st.store_name,
    st.snapshot_date,
    sa.total_sales,
    sa.total_sales_ex_vat,
    sa.total_cost,
    st.total_qty,
    st.neg_soh_count,
    st.slow_mover_count,
    st.capital_tied
FROM   stock st
LEFT   JOIN sales sa
       ON sa.store_code = st.store_code AND sa.sale_date = st.snapshot_date
ORDER  BY st.store_code, st.snapshot_date ASC;

CREATE UNIQUE INDEX idx_mv_sparkline_store_date
    ON public.mv_sparkline_14d (store_code, snapshot_date);

GRANT SELECT ON public.mv_sparkline_14d TO anon, authenticated;
