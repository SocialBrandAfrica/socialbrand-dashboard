-- =============================================================================
-- create_mv_sparkline_14d.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 3.
-- Supersedes: SB-CC-DASH-SOURCE-002 (2026-06-17, date driver still daily_snapshots).
-- =============================================================================
-- WHY:
--   daily_snapshots frozen at 2026-06-28. The prior file deliberately held the
--   date driver on daily_snapshots ("DATE SET: driver stays daily_snapshots") to
--   keep stock facts aligned. With daily_snapshots dead as a write target, the
--   sparkline would freeze at the last 14 dates ending 06-28. RETIRE-002 completes
--   what was held.
--
-- WHAT CHANGES:
--   latest_14_dates: NOW from sigma_sales (sale_date DESC LIMIT 14) so today's
--     date enters the sparkline window as soon as sigma_sales lands (18:40 SAST).
--   stock CTE: NOW from l2_soh_daily + l2_stock_position (same proven CTEs as
--     mv_kpi_by_date post-RETIRE-001). Replaces daily_snapshots stock aggregation.
--   total_qty: NOW from sigma_sales.qty (was daily_snapshots.today_qty; PRSSALE
--     qty retired with the pipeline).
--   store_name: from stores LEFT JOIN on COALESCE(store_codes) (same as
--     mv_kpi_by_date pattern; was ds.store_name inline).
--   FULL OUTER JOIN (stock x sales) preserved so a date with stock-only or
--     sales-only still appears in the sparkline.
--   daily_snapshots dependency dropped entirely.
--
-- NULLS (R22): stock facts NULL for dates before l2_soh_daily floor (2026-06-11
--   x4 stores, 2026-06-21 for 80579). Sales facts populate for any date in
--   sigma_sales. Intraday current day: sales populate at 18:40; stock facts
--   appear after the 22:15 L2 engine run. Prior day note in old file rescinded.
--
-- COLUMN ORDER: preserved exactly (zero client breakage).
-- INDEX: idx_mv_sparkline_store_date (store_code, snapshot_date) -- recreated.
-- GRANT: anon + authenticated SELECT.
-- CASCADE on DROP: no dependents confirmed.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================
SET statement_timeout = '10min';

DROP MATERIALIZED VIEW IF EXISTS public.mv_sparkline_14d CASCADE;

CREATE MATERIALIZED VIEW public.mv_sparkline_14d AS
WITH latest_14_dates AS (
  SELECT DISTINCT ss.sale_date AS snapshot_date
  FROM   public.sigma_sales ss
  WHERE  ss.period_kind = 'T' AND ss.txn_kind = 1
  ORDER  BY snapshot_date DESC
  LIMIT  14
),
stock AS (
  SELECT
    ls.store_code,
    ls.snapshot_date,
    SUM(CASE WHEN ls.soh < 0 THEN 1 ELSE 0 END)::bigint               AS neg_soh_count,
    SUM(CASE WHEN sp.slow_mover_signal THEN 1 ELSE 0 END)::bigint     AS slow_mover_count,
    COALESCE(ROUND(SUM(
      CASE WHEN sp.class = 'NORMAL' AND ls.soh > 0
           THEN ls.soh * COALESCE(sp.unit_cost, 0)
      END)::numeric, 2), 0)                                            AS capital_tied
  FROM public.l2_soh_daily ls
  JOIN public.l2_stock_position sp
    ON  sp.store_code   = ls.store_code
    AND sp.product_code = ls.product_code
  WHERE ls.snapshot_date IN (SELECT snapshot_date FROM latest_14_dates)
  GROUP BY ls.store_code, ls.snapshot_date
),
sales AS (
  SELECT
    ss.store_code,
    ss.sale_date,
    ROUND(SUM(ss.sales_incl_vat), 2)                 AS total_sales,
    ROUND(SUM(ss.sales_incl_vat - ss.vat_value), 2) AS total_sales_ex_vat,
    ROUND(SUM(ss.cost_value), 2)                     AS total_cost,
    ROUND(SUM(ss.qty), 2)                            AS total_qty
  FROM public.sigma_sales ss
  WHERE ss.period_kind = 'T' AND ss.txn_kind = 1
    AND ss.sale_date IN (SELECT snapshot_date FROM latest_14_dates)
  GROUP BY ss.store_code, ss.sale_date
)
SELECT
  COALESCE(sa.store_code, st.store_code)           AS store_code,
  s.store_name,
  COALESCE(sa.sale_date, st.snapshot_date)         AS snapshot_date,
  sa.total_sales,
  sa.total_sales_ex_vat,
  sa.total_cost,
  sa.total_qty,
  st.neg_soh_count,
  st.slow_mover_count,
  st.capital_tied
FROM sales sa
FULL OUTER JOIN stock st
  ON  st.store_code    = sa.store_code
  AND st.snapshot_date = sa.sale_date
LEFT JOIN public.stores s
  ON  s.store_code = COALESCE(sa.store_code, st.store_code)
ORDER BY COALESCE(sa.store_code, st.store_code), COALESCE(sa.sale_date, st.snapshot_date);

CREATE UNIQUE INDEX idx_mv_sparkline_store_date
  ON public.mv_sparkline_14d (store_code, snapshot_date);

GRANT SELECT ON public.mv_sparkline_14d TO anon, authenticated;
