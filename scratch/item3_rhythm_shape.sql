-- SCRATCH, NOT A MIGRATION. Never applied as source of record. Runs on the live database only between 20:00 and 22:00 SAST (PM 14-10-2026, no tests or scratch builds 07:00 to 20:00).
-- ITEM 3 FIRST STEP (BLOOM-035 item 3, "falsify the CANDIDATE"): read the month shape from the store's own ledger, weekday taken out, on the WHOLE STORE (PM's scope)
-- and on DC AMBIENT departments only (the live projection's scope), at the two SPARs, and compare it with (a) PM's worked split for November 2026 at 10116
-- (22.6 / 21.2 / 20.0 / 24.7 / 11.5), (b) the live l2_sales_budget weeks of November, (c) a backtest of the live projection with and without its rhythm layer.
-- Two methods, so the one that reproduces PM's split names the method: DOM (day of month) and PENSION (offset from the older-persons date, the 21 anchors of CAL-RHYTHM-001 s1,
-- researched, only the 2026/27 rows are in calendar_events). Writes cc_scratch_b035_r3_* (service_role only), net sales ex-VAT = sales_incl_vat - vat_value.
-- RUN IN THREE PARTS, each its own cron job and its own transaction (A 19:00 UTC, B 19:15, C 19:20): a failure in one keeps the tables of the parts before it.

-- ===== PART A: daily sales, the DC ambient pool, the weekday factor, the detrended day =====
DROP TABLE IF EXISTS public.cc_scratch_b035_r3_day, public.cc_scratch_b035_r3_pool, public.cc_scratch_b035_r3_wdf, public.cc_scratch_b035_r3_det;
CREATE TABLE public.cc_scratch_b035_r3_day AS
SELECT ss.store_code, 'STORE'::text AS scope, ss.sale_date AS d, SUM(ss.sales_incl_vat - ss.vat_value) AS net
  FROM public.sigma_sales ss
 WHERE ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sale_date >= DATE '2025-04-02'
 GROUP BY 1, 3;

CREATE TABLE public.cc_scratch_b035_r3_pool AS
SELECT DISTINCT sl.store_code, sl.product_code
  FROM public.sigma_supplier_link sl
  JOIN public.sigma_supplier_master sm ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
  JOIN public.l2_stock_position sp ON sp.store_code = sl.store_code AND sp.product_code = sl.product_code
  JOIN public.bloom_dc_config dc ON dc.store_code = sl.store_code AND dc.status = 'RULED'
 WHERE sl.store_code IN ('10116', '80175') AND COALESCE(sl.status, '') <> 'S' AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
   AND sm.supplier_type = 'Z' AND sp.department_nr = ANY(dc.dc_cycle_dept_nrs) AND sp.class = 'NORMAL';

INSERT INTO public.cc_scratch_b035_r3_day
SELECT p.store_code, 'DCAMB', ss.sale_date, SUM(ss.sales_incl_vat - ss.vat_value)
  FROM public.sigma_sales ss
  JOIN public.cc_scratch_b035_r3_pool p ON p.store_code = ss.store_code AND p.product_code = ss.product_code
 WHERE ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.sale_date >= DATE '2025-04-02'
 GROUP BY 1, 3;

-- the weekday factor: the mean of the weekday over the mean of every trading day, per store and scope
CREATE TABLE public.cc_scratch_b035_r3_wdf AS
SELECT x.store_code, x.scope, EXTRACT(ISODOW FROM x.d)::int AS dow, AVG(x.net) / (SELECT AVG(t.net) FROM public.cc_scratch_b035_r3_day t
         WHERE t.store_code = x.store_code AND t.scope = x.scope AND t.net > 0 AND t.d < CURRENT_DATE - 2) AS f
  FROM public.cc_scratch_b035_r3_day x
 WHERE x.net > 0 AND x.d < CURRENT_DATE - 2
 GROUP BY 1, 2, 3;

CREATE TABLE public.cc_scratch_b035_r3_det AS
SELECT x.store_code, x.scope, x.d, x.net / w.f AS det
  FROM public.cc_scratch_b035_r3_day x
  JOIN public.cc_scratch_b035_r3_wdf w ON w.store_code = x.store_code AND w.scope = x.scope AND w.dow = EXTRACT(ISODOW FROM x.d)::int
 WHERE x.net > 0 AND x.d < CURRENT_DATE - 2;

REVOKE ALL ON public.cc_scratch_b035_r3_day, public.cc_scratch_b035_r3_pool, public.cc_scratch_b035_r3_wdf, public.cc_scratch_b035_r3_det FROM PUBLIC, anon, authenticated;

-- ===== PART B: the two shapes =====
DROP TABLE IF EXISTS public.cc_scratch_b035_r3_f_dom, public.cc_scratch_b035_r3_anchor, public.cc_scratch_b035_r3_cyc, public.cc_scratch_b035_r3_f_off;
-- METHOD DOM: every complete month from 2025-04 to 2026-09, each day over its own month's mean, averaged by day of month
CREATE TABLE public.cc_scratch_b035_r3_f_dom AS
WITH m AS (
  SELECT store_code, scope, d, det, AVG(det) OVER (PARTITION BY store_code, scope, date_trunc('month', d)) AS mmean,
         count(*) OVER (PARTITION BY store_code, scope, date_trunc('month', d)) AS n
    FROM public.cc_scratch_b035_r3_det WHERE d >= DATE '2025-04-01' AND d < DATE '2026-10-01')
SELECT store_code, scope, EXTRACT(day FROM d)::int AS dom, AVG(det / mmean) AS f, count(*) AS months
  FROM m WHERE n >= 28 GROUP BY 1, 2, 3;

-- METHOD PENSION: the older-persons dates of CAL-RHYTHM-001 s1, each cycle over its own mean, averaged by offset, offsets 28 and beyond pooled into one tail bucket
CREATE TABLE public.cc_scratch_b035_r3_anchor (anchor date);
INSERT INTO public.cc_scratch_b035_r3_anchor VALUES
 ('2025-04-02'), ('2025-05-06'), ('2025-06-03'), ('2025-07-02'), ('2025-08-05'), ('2025-09-02'), ('2025-10-02'), ('2025-11-04'), ('2025-12-02'),
 ('2026-01-06'), ('2026-02-03'), ('2026-03-03'), ('2026-04-02'), ('2026-05-05'), ('2026-06-02'), ('2026-07-02'), ('2026-08-04'), ('2026-09-02'),
 ('2026-10-02'), ('2026-11-03'), ('2026-12-02');

CREATE TABLE public.cc_scratch_b035_r3_cyc AS
SELECT x.store_code, x.scope, x.d, x.det, a.anchor, (x.d - a.anchor) AS off,
       AVG(x.det) OVER (PARTITION BY x.store_code, x.scope, a.anchor) AS cmean
  FROM public.cc_scratch_b035_r3_det x
  JOIN LATERAL (SELECT MAX(an.anchor) AS anchor FROM public.cc_scratch_b035_r3_anchor an WHERE an.anchor <= x.d) a ON true
 WHERE x.d >= DATE '2025-04-02' AND x.d < DATE '2026-09-02';

CREATE TABLE public.cc_scratch_b035_r3_f_off AS
SELECT store_code, scope, LEAST(off, 28) AS off_bucket, AVG(det / cmean) AS f, count(*) AS n, count(DISTINCT anchor) AS cycles
  FROM public.cc_scratch_b035_r3_cyc GROUP BY 1, 2, 3;

REVOKE ALL ON public.cc_scratch_b035_r3_f_dom, public.cc_scratch_b035_r3_anchor, public.cc_scratch_b035_r3_cyc, public.cc_scratch_b035_r3_f_off FROM PUBLIC, anon, authenticated;

-- ===== PART C: November 2026 shares, the actual months, the live projection and the backtest =====
DROP TABLE IF EXISTS public.cc_scratch_b035_r3_nov, public.cc_scratch_b035_r3_actual, public.cc_scratch_b035_r3_live, public.cc_scratch_b035_r3_bt;
-- November 2026: each budget week (Saturday to Friday) takes its November days, share = the sum of the day indices of those days over the month's sum
CREATE TABLE public.cc_scratch_b035_r3_nov AS
WITH days AS (SELECT g::date AS d FROM generate_series(DATE '2026-11-01', DATE '2026-11-30', INTERVAL '1 day') g),
 wk AS (SELECT d, d - ((EXTRACT(ISODOW FROM d)::int + 1) % 7) AS week_start FROM days),
 s AS (SELECT DISTINCT store_code, scope FROM public.cc_scratch_b035_r3_f_dom),
 a AS (SELECT w.d, w.week_start, s.store_code, s.scope, 'DOM'::text AS method, f.f
         FROM wk w CROSS JOIN s JOIN public.cc_scratch_b035_r3_f_dom f ON f.store_code = s.store_code AND f.scope = s.scope AND f.dom = EXTRACT(day FROM w.d)::int),
 b AS (SELECT w.d, w.week_start, s.store_code, s.scope, 'PENSION'::text AS method, f.f
         FROM wk w CROSS JOIN s
         JOIN LATERAL (SELECT MAX(an.anchor) AS anchor FROM public.cc_scratch_b035_r3_anchor an WHERE an.anchor <= w.d) an2 ON true
         JOIN public.cc_scratch_b035_r3_f_off f ON f.store_code = s.store_code AND f.scope = s.scope AND f.off_bucket = LEAST(w.d - an2.anchor, 28)),
 u AS (SELECT * FROM a UNION ALL SELECT * FROM b)
SELECT store_code, scope, method, week_start, count(*)::int AS days, ROUND(100 * SUM(f) / SUM(SUM(f)) OVER (PARTITION BY store_code, scope, method), 1) AS share_pct
  FROM u GROUP BY 1, 2, 3, 4;

-- what the same weeks of a month really did: November 2025 and September 2026, Saturday to Friday weeks cut at the month edge
CREATE TABLE public.cc_scratch_b035_r3_actual AS
SELECT store_code, scope, mo, week_start, count(*)::int AS days, ROUND(100 * SUM(net) / SUM(SUM(net)) OVER (PARTITION BY store_code, scope, mo), 1) AS share_pct
  FROM (SELECT x.store_code, x.scope, date_trunc('month', x.d)::date AS mo, x.d - ((EXTRACT(ISODOW FROM x.d)::int + 1) % 7) AS week_start, x.net
          FROM public.cc_scratch_b035_r3_day x
         WHERE (x.d >= DATE '2025-11-01' AND x.d < DATE '2025-12-01') OR (x.d >= DATE '2026-09-01' AND x.d < DATE '2026-10-01')) q
 GROUP BY 1, 2, 3, 4;

-- the live projection of the weeks of November at DC ambient, and the backtest of the projection with and without its rhythm layer (anchor 2026-04-04, 26 weeks)
CREATE TABLE public.cc_scratch_b035_r3_live AS
SELECT store_code, route_key, budget_week_start, ly_base_cost, trend_factor, rhythm_seasonality_projected_cost, projected_sales_cost
  FROM public.l2_sales_budget
 WHERE route_key = 'DC_AMBIENT' AND store_code IN ('10116', '80175') AND budget_week_start BETWEEN DATE '2026-10-03' AND DATE '2026-12-26';

CREATE TABLE public.cc_scratch_b035_r3_bt (store_code text, route_key text, budget_week_start date, ly_base_cost numeric, trend_factor numeric, rhythm_proj numeric, projected numeric, actual numeric);
INSERT INTO public.cc_scratch_b035_r3_bt
SELECT '10116', 'DC_AMBIENT', p.budget_week_start, p.ly_base_cost, p.trend_factor, p.rhythm_seasonality_projected_cost, p.projected_sales_cost, b.actual_sales_cost
  FROM public.rpc_project_route_sales_budget('10116', 'DC_AMBIENT', DATE '2026-04-04', 26) p
  LEFT JOIN public.rpc_backtest_l2_sales_budget('10116', 'DC_AMBIENT', DATE '2026-04-04', 26) b ON b.budget_week_start = p.budget_week_start;
INSERT INTO public.cc_scratch_b035_r3_bt
SELECT '80175', 'DC_AMBIENT', p.budget_week_start, p.ly_base_cost, p.trend_factor, p.rhythm_seasonality_projected_cost, p.projected_sales_cost, b.actual_sales_cost
  FROM public.rpc_project_route_sales_budget('80175', 'DC_AMBIENT', DATE '2026-04-04', 26) p
  LEFT JOIN public.rpc_backtest_l2_sales_budget('80175', 'DC_AMBIENT', DATE '2026-04-04', 26) b ON b.budget_week_start = p.budget_week_start;

REVOKE ALL ON public.cc_scratch_b035_r3_nov, public.cc_scratch_b035_r3_actual, public.cc_scratch_b035_r3_live, public.cc_scratch_b035_r3_bt FROM PUBLIC, anon, authenticated;
