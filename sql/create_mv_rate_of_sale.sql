-- =============================================================================
-- create_mv_rate_of_sale.sql
-- SB-CC-DASH-SOURCE-002 (SB-INDEX-005 Phase 2) -- rate-of-sale source migration.
-- STATUS: DEPLOYED LIVE 2026-06-13 via dash_source_002_mv_rate_of_sale_to_sigma;
--   refresh wired into refresh_l2_pipeline via _wire_mv_rate_of_sale_into_pipeline.
--   Reconciled: 35,531 rows == 35,531 distinct (store,ean) keys (no fan-out);
--   ROS matches PM worked example; SIZZLER days_cover 0.6 (soh 9 / ros 15.69).
-- =============================================================================
-- HYBRID migration (per PM qty/ROS ruling):
--   ROS (SALES FACT) -> sigma_sales. daily_ros = SUM(qty over 91d)/91 in
--     SELLING-UNITS (no weight/unit conversion; KG-line ROS = weigh-tickets/day,
--     a sound ordering proxy). Keyed by canonical ean via the SHARED
--     v_ean_bridge view (one ean per (store, product_code) -- no fan-out).
--     91-day window anchored on each store's MAX(sale_date) in sigma_sales
--     (more current than the old snapshot anchor; sigma is intraday-fresh).
--   SOH + dims + sell_price + unit_cost + status (STOCK FACTS) -> STAY on
--     daily_snapshots (the held stock-facts thread). days_cover = SOH / ROS
--     therefore straddles both: held SOH / sigma ROS. When SOH migrates in the
--     coordinated stock step, the 'latest' CTE moves to sigma-native and the
--     ean-keying below becomes fully canonical.
--
-- KNOWN CAVEAT (ean keying across the two sources):
--   'latest' is keyed by daily_snapshots.ean (PRSSALE-expanded form); 'ros_window'
--   by the canonical sigma ean. For the lone product_catalog dup (SRC-001, 10116
--   product 34937 CAMEL ONE BOX: snapshot may carry the PLU ean while sigma
--   carries 42139126) the LEFT JOIN can miss -> days_cover NULL for that 1 SKU.
--   Blast radius = 1 product across all 5 stores; clears when SRC-001 is fixed at
--   the loader and/or when SOH migrates to canonical ean. Logged in BUG-LOG.
--
-- REFRESH WIRING (done): added to refresh_l2_pipeline beside mv_kpi_by_date
--   (plain REFRESH -- pg_cron wraps the pipeline call in a txn so CONCURRENTLY is
--   not usable there; the unique index still supports a manual CONCURRENTLY).
--
-- ROS foundation reconcile (read-only, live, 10116, 91d to MAX sale_date):
--   1011600240103 = 266.16/day (24,221u) | 1011600200332 = 15.69/day (1,428u) |
--   6001008772719 = 3.13/day (285u). Matches PM's worked example; the two
--   store-internal-coded sellers read ROS 0 on the old PRSSALE source.
--
-- DROP + CREATE (R19); recreate both indexes; grant anon/authenticated.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_rate_of_sale;

CREATE MATERIALIZED VIEW mv_rate_of_sale AS
WITH sigma_max AS (
    SELECT store_code, MAX(sale_date) AS max_date
    FROM   sigma_sales
    WHERE  period_kind = 'T' AND txn_kind = 1
    GROUP  BY store_code
),
ros_window AS (                         -- SALES FACT: 91d selling-unit ROS off sigma
    SELECT b.ean,
           ss.store_code,
           SUM(ss.qty) AS total_qty_91d
    FROM   sigma_sales ss
    JOIN   v_ean_bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    JOIN   sigma_max sm   ON sm.store_code = ss.store_code
    WHERE  ss.sale_date >= (sm.max_date - INTERVAL '90 days')
      AND  ss.sale_date <= sm.max_date
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
    GROUP  BY b.ean, ss.store_code
),
store_max_date AS (                     -- held: snapshot anchor for SOH/dims
    SELECT store_code, MAX(snapshot_date) AS max_date
    FROM   daily_snapshots
    GROUP  BY store_code
),
latest AS (                             -- STOCK FACTS + dims (held on daily_snapshots)
    SELECT DISTINCT ON (ds.store_code, ds.ean)
           ds.store_code, ds.store_name, ds.ean, ds.description, ds.dept_name,
           ds.sub_dept_name, ds.dept_code, ds.sub_dept_code, ds.soh, ds.sell_price,
           ds.unit_cost, ds.status, ds.internal_ref
    FROM   daily_snapshots ds
    JOIN   store_max_date smd ON ds.store_code = smd.store_code AND ds.snapshot_date = smd.max_date
    ORDER  BY ds.store_code, ds.ean
)
SELECT l.store_code,
       l.store_name,
       l.ean,
       l.description,
       l.dept_name,
       l.sub_dept_name,
       l.dept_code,
       l.sub_dept_code,
       l.soh,
       l.sell_price,
       l.unit_cost,
       l.status,
       l.internal_ref,
       ROUND(COALESCE(r.total_qty_91d, 0::numeric) / 91.0, 4) AS daily_ros,
       CASE WHEN COALESCE(r.total_qty_91d, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE ROUND(l.soh / (r.total_qty_91d / 91.0), 1)
       END AS days_cover
FROM   latest l
LEFT   JOIN ros_window r ON l.ean = r.ean AND l.store_code = r.store_code;

CREATE UNIQUE INDEX mv_rate_of_sale_pk  ON public.mv_rate_of_sale USING btree (store_code, ean);
CREATE INDEX        mv_rate_of_sale_ean ON public.mv_rate_of_sale USING btree (ean);

GRANT SELECT ON mv_rate_of_sale TO anon, authenticated;
