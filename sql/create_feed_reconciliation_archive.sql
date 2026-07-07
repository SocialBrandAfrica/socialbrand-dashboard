-- =============================================================================
-- create_feed_reconciliation_archive.sql
-- R22 preservation step (PM ruling 2026-07-07): the DBUMBA-vs-PRSSALE two-feed
-- reconciliation verdict for every day daily_snapshots ever covered must outlive
-- the frozen table before it truncates. This is a permanent, queryable record of
-- the same logic rpc_feed_health_daily ran for dates <= the 2026-06-28 horizon.
-- Run ONCE, before rpc_feed_health_daily is repointed single-feed and before
-- daily_snapshots is archived/truncated. Applied live 2026-07-07: 2,425 rows
-- (485 days x 5 stores, 2025-03-01 through 2026-06-28), verified against the
-- SQL file's own documented proof case (10116 05-29 EOD_MISSING, R383,387.74).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.feed_reconciliation_archive (
  client_id      text NOT NULL DEFAULT 'socialbrand',
  store_code     text NOT NULL,
  sale_date      date NOT NULL,
  day_name       text,
  dbumba_total   numeric,
  prssale_total  numeric,
  variance_pct   numeric,
  status         text,
  is_flagged     boolean,
  archived_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, sale_date)
);

COMMENT ON TABLE public.feed_reconciliation_archive IS
  'R22 permanent record of the DBUMBA (sigma_sales) vs PRSSALE (daily_snapshots) '
  'two-feed reconciliation for every day inside the PRSSALE horizon (<= 2026-06-28), '
  'preserved before daily_snapshots archive/truncate (PM ruling 2026-07-07). '
  'Same statuses as the retired two-feed leg of rpc_feed_health_daily: '
  'COMPLETE / EOD_MISSING / DIVERGENT / NO_TRADE / FUTURE.';

WITH date_spine AS (
  SELECT s.store_code, gs.d::date AS d
  FROM public.stores s
  CROSS JOIN LATERAL generate_series('2025-03-01'::date, '2026-06-28'::date, INTERVAL '1 day') AS gs(d)
  WHERE s.is_active
),
dbumba AS (
  SELECT store_code, sale_date, ROUND(SUM(sales_incl_vat)::numeric, 2) AS total
  FROM public.sigma_sales
  WHERE period_kind = 'T' AND txn_kind = 1
    AND sale_date BETWEEN '2025-03-01' AND '2026-06-28'
  GROUP BY store_code, sale_date
),
prssale AS (
  SELECT store_code, snapshot_date AS sale_date, ROUND(SUM(today_sales)::numeric, 2) AS total
  FROM public.daily_snapshots
  WHERE snapshot_date BETWEEN '2025-03-01' AND '2026-06-28'
  GROUP BY store_code, snapshot_date
)
INSERT INTO public.feed_reconciliation_archive
  (store_code, sale_date, day_name, dbumba_total, prssale_total, variance_pct, status, is_flagged)
SELECT
  ds.store_code, ds.d, TO_CHAR(ds.d, 'Dy'),
  COALESCE(db.total, 0) AS dbumba_total,
  COALESCE(pr.total, 0) AS prssale_total,
  CASE WHEN COALESCE(db.total,0) = 0 THEN NULL
       ELSE ROUND(ABS(COALESCE(db.total,0) - COALESCE(pr.total,0)) / db.total * 100, 2) END AS variance_pct,
  CASE
    WHEN ds.d > CURRENT_DATE THEN 'FUTURE'
    WHEN COALESCE(db.total,0) = 0 AND COALESCE(pr.total,0) = 0 THEN 'NO_TRADE'
    WHEN COALESCE(db.total,0) > 0 AND COALESCE(pr.total,0) = 0 THEN 'EOD_MISSING'
    WHEN ABS(COALESCE(db.total,0) - COALESCE(pr.total,0)) / NULLIF(db.total,0) > 0.03 THEN 'DIVERGENT'
    ELSE 'COMPLETE'
  END AS status,
  CASE
    WHEN ds.d > CURRENT_DATE THEN false
    WHEN COALESCE(db.total,0) > 0 AND COALESCE(pr.total,0) = 0 THEN true
    WHEN ABS(COALESCE(db.total,0) - COALESCE(pr.total,0)) / NULLIF(db.total,0) > 0.03 THEN true
    ELSE false
  END AS is_flagged
FROM date_spine ds
LEFT JOIN dbumba  db ON db.store_code = ds.store_code AND db.sale_date = ds.d
LEFT JOIN prssale pr ON pr.store_code = ds.store_code AND pr.sale_date = ds.d
ON CONFLICT (store_code, sale_date) DO NOTHING;

GRANT SELECT ON public.feed_reconciliation_archive TO authenticated;
