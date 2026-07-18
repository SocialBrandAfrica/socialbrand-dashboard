-- SB-CC / ENG-025 : the cadence law promoted from prose into ONE callable object (canon section 14
-- v9 item 7h, R21). Derives each DIRECT desk's cadence from its own R/W receipt ledger and RETURNS
-- the proposed supplier_calendar row WITH its evidence (R29). Order of operations (canon 7g/7f/7i):
-- value-relative noise floor -> regime-outlier exclusion (NAMED, never averaged) -> median gap ->
-- half-down rounding (GREATEST(1, CEIL(median/7.0 - 0.5)); Postgres ROUND(1.5)=2 is 7f backwards)
-- -> dow from the CURRENT regime (trailing lookback, not the whole window). Applied 2026-07-18,
-- migrations cadence_law_03c_derive_dow_recency (+ ALTER ... SET search_path = public).
-- SCOPE (named, R21 section 5): DIRECT_* desks that carry direct_supplier_nrs. DC_* and DIRECT_BEER
-- (merch-group classified, no supplier_nrs) are a separate pantry debt -- delivery_dows already ruled,
-- left untouched.
CREATE OR REPLACE FUNCTION public.rpc_derive_supplier_cadence(
  p_store_code text,
  p_route_key  text DEFAULT NULL,
  p_window_days int  DEFAULT NULL
)
RETURNS TABLE (
  store_code text, route_key text, supplier_nrs text[], window_days int,
  receipt_days int, drops int,
  med_receipt_day_cost numeric, drop_floor numeric,
  drop_min numeric, drop_max numeric, noise_max numeric, drop_separation_ratio numeric,
  median_gap_raw numeric, median_gap numeric, gaps_used int, outliers_excluded int, outlier_gaps int[],
  regime_start date, last_drop date,
  cycle_weeks smallint, cycle_anchor_week_start date,
  modal_dow int, modal_dow_pct numeric, distinct_dows int, proposed_delivery_dows int[],
  dow_confidence_ok boolean, dow_matches_calendar boolean,
  evidence text
)
LANGUAGE sql STABLE
SET search_path = public
AS $fn$
WITH params AS (
  SELECT
    COALESCE(p_window_days, (SELECT value_num FROM forge_config WHERE config_key='cadence_window_days' AND store_format='*')::int, 182) AS win,
    COALESCE((SELECT value_num FROM forge_config WHERE config_key='drop_floor_ratio' AND store_format='*'), 0.25) AS floor_ratio,
    COALESCE((SELECT value_num FROM forge_config WHERE config_key='regime_outlier_gap_multiple' AND store_format='*'), 3) AS outlier_mult,
    COALESCE((SELECT value_num FROM forge_config WHERE config_key='dow_confidence_min' AND store_format='*'), 60) AS dow_conf_min,
    COALESCE((SELECT value_num FROM forge_config WHERE config_key='dow_tolerance_days' AND store_format='*')::int, 1) AS dow_tol,
    COALESCE((SELECT value_num FROM forge_config WHERE config_key='dow_regime_lookback_days' AND store_format='*')::int, 84) AS dow_lookback
),
cfg AS (
  SELECT brc.store_code, brc.route_key, brc.direct_supplier_nrs AS snrs, sc.delivery_dows AS cal_dows
  FROM bloom_route_config brc
  LEFT JOIN supplier_calendar sc ON sc.store_code=brc.store_code AND sc.route_key=brc.route_key
  WHERE brc.store_code = p_store_code
    AND brc.route_key LIKE 'DIRECT\_%'
    AND brc.direct_supplier_nrs IS NOT NULL
    AND (p_route_key IS NULL OR brc.route_key = p_route_key)
),
rcpt AS (
  SELECT c.store_code, c.route_key, m.movement_date AS d, SUM(m.cost_value) AS day_cost
  FROM cfg c
  CROSS JOIN params p
  JOIN sigma_movements m
    ON m.store_code=c.store_code AND m.movement_type='R' AND m.movement_process='W'
   AND m.movement_date >= CURRENT_DATE - p.win
   AND m.supplier_nr = ANY (c.snrs::bigint[])
  GROUP BY c.store_code, c.route_key, m.movement_date
),
med AS (
  SELECT store_code, route_key,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY day_cost) AS med_day_cost,
    count(*)::int AS receipt_days
  FROM rcpt GROUP BY 1,2
),
tagged AS (
  SELECT r.store_code, r.route_key, r.d, r.day_cost,
    (r.day_cost >= p.floor_ratio * m.med_day_cost) AS is_drop,
    EXTRACT(ISODOW FROM r.d)::int AS dow
  FROM rcpt r JOIN med m USING(store_code,route_key) CROSS JOIN params p
),
drops AS (
  SELECT store_code, route_key, d, day_cost, dow FROM tagged WHERE is_drop
),
gaps AS (
  SELECT store_code, route_key, d, dow, day_cost,
    (d - LAG(d) OVER (PARTITION BY store_code,route_key ORDER BY d))::int AS gap
  FROM drops
),
graw AS (
  SELECT store_code, route_key, percentile_cont(0.5) WITHIN GROUP (ORDER BY gap) AS med_gap_raw
  FROM gaps WHERE gap IS NOT NULL GROUP BY 1,2
),
gflag AS (
  SELECT g.*, gr.med_gap_raw,
    (g.gap IS NOT NULL AND g.gap > p.outlier_mult * gr.med_gap_raw) AS is_outlier
  FROM gaps g JOIN graw gr USING(store_code,route_key) CROSS JOIN params p
),
regime AS (
  SELECT store_code, route_key,
    COALESCE(MAX(d) FILTER (WHERE is_outlier), MIN(d)) AS regime_start
  FROM gflag GROUP BY 1,2
),
median_regime AS (
  SELECT store_code, route_key,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY gap) FILTER (WHERE NOT is_outlier) AS med_gap,
    count(*) FILTER (WHERE gap IS NOT NULL AND NOT is_outlier)::int AS gaps_used,
    count(*) FILTER (WHERE is_outlier)::int AS outliers_excluded,
    array_remove(array_agg(gap ORDER BY d) FILTER (WHERE is_outlier), NULL) AS outlier_gaps
  FROM gflag GROUP BY 1,2
),
dropstats AS (
  SELECT store_code, route_key, count(*)::int AS drops,
    min(day_cost) AS drop_min, max(day_cost) AS drop_max, max(d) AS last_drop
  FROM drops GROUP BY 1,2
),
noisestats AS (
  SELECT store_code, route_key, max(day_cost) AS noise_max
  FROM tagged WHERE NOT is_drop GROUP BY 1,2
),
regime_drops AS (  -- DOW regime (canon 7i): trailing lookback window, floored at any gap-outlier boundary
  SELECT gf.store_code, gf.route_key, gf.d, gf.dow
  FROM gflag gf
  JOIN regime rg USING(store_code,route_key)
  JOIN dropstats ds USING(store_code,route_key)
  CROSS JOIN params p
  WHERE gf.d >= GREATEST(rg.regime_start, ds.last_drop - p.dow_lookback)
),
dow_counts AS (
  SELECT store_code, route_key, dow, count(*)::int AS cnt
  FROM regime_drops GROUP BY 1,2,3
),
dow_tot AS (
  SELECT store_code, route_key, sum(cnt) AS tot, max(cnt) AS max_cnt FROM dow_counts GROUP BY 1,2
),
dow_lag AS (
  SELECT dc.store_code, dc.route_key, dc.dow, dc.cnt, p.dow_tol,
    dc.dow - LAG(dc.dow) OVER (PARTITION BY dc.store_code,dc.route_key ORDER BY dc.dow) AS dgap
  FROM dow_counts dc CROSS JOIN params p
),
dow_clust AS (
  SELECT store_code, route_key, dow, cnt,
    SUM(CASE WHEN dgap IS NULL OR dgap > dow_tol THEN 1 ELSE 0 END)
      OVER (PARTITION BY store_code,route_key ORDER BY dow ROWS UNBOUNDED PRECEDING) AS cluster_id
  FROM dow_lag
),
cluster_agg AS (
  SELECT store_code, route_key, cluster_id, sum(cnt) AS weight,
    (array_agg(dow ORDER BY cnt DESC, dow))[1] AS rep_dow
  FROM dow_clust GROUP BY 1,2,3
),
cluster_keep AS (  -- a real delivery day recurs >= half as often as the main cluster
  SELECT ca.store_code, ca.route_key, ca.rep_dow, ca.weight
  FROM cluster_agg ca
  JOIN (SELECT store_code, route_key, max(weight) AS max_w FROM cluster_agg GROUP BY 1,2) mx USING(store_code,route_key)
  WHERE ca.weight >= 0.5 * mx.max_w
),
dow_final AS (
  SELECT store_code, route_key,
    array_agg(rep_dow ORDER BY rep_dow) AS proposed_dows, count(*)::int AS distinct_dows
  FROM cluster_keep GROUP BY 1,2
),
modal AS (
  SELECT dc.store_code, dc.route_key,
    (array_agg(dc.dow ORDER BY dc.cnt DESC, dc.dow))[1] AS modal_dow,
    round(100.0 * dt.max_cnt / NULLIF(dt.tot,0), 1) AS modal_dow_pct
  FROM dow_counts dc JOIN dow_tot dt USING(store_code,route_key)
  GROUP BY dc.store_code, dc.route_key, dt.max_cnt, dt.tot
)
SELECT
  c.store_code, c.route_key, c.snrs AS supplier_nrs, pr.win AS window_days,
  m.receipt_days, ds.drops,
  round(m.med_day_cost) AS med_receipt_day_cost,
  round(pr.floor_ratio * m.med_day_cost) AS drop_floor,
  round(ds.drop_min) AS drop_min, round(ds.drop_max) AS drop_max, round(ns.noise_max) AS noise_max,
  round(ds.drop_min / NULLIF(ns.noise_max,0), 1) AS drop_separation_ratio,
  gr.med_gap_raw AS median_gap_raw, mr.med_gap AS median_gap, mr.gaps_used, mr.outliers_excluded, mr.outlier_gaps,
  rg.regime_start, ds.last_drop,
  GREATEST(1, CEIL(mr.med_gap/7.0 - 0.5))::smallint AS cycle_weeks,
  (ds.last_drop - ((EXTRACT(ISODOW FROM ds.last_drop)::int + 1) % 7))::date AS cycle_anchor_week_start,
  mo.modal_dow, mo.modal_dow_pct, df.distinct_dows, df.proposed_dows AS proposed_delivery_dows,
  (mo.modal_dow_pct >= pr.dow_conf_min) AS dow_confidence_ok,
  (c.cal_dows IS NOT NULL AND NOT EXISTS (
     SELECT 1 FROM unnest(df.proposed_dows) pd
     WHERE NOT EXISTS (SELECT 1 FROM unnest(c.cal_dows) cd WHERE abs(cd - pd) <= pr.dow_tol)
   )) AS dow_matches_calendar,
  format('%s drop(s)/%s receipt-days; median gap %s (raw %s, %s outlier(s) excluded %s); cycle %s wk; dow %s @ %s%% conf, dows %s; drops R%s-R%s vs noise<=R%s (sep %sx); anchor %s',
    ds.drops, m.receipt_days, mr.med_gap, gr.med_gap_raw, mr.outliers_excluded, COALESCE(mr.outlier_gaps::text,'{}'),
    GREATEST(1, CEIL(mr.med_gap/7.0 - 0.5)),
    mo.modal_dow, mo.modal_dow_pct, df.proposed_dows::text,
    round(ds.drop_min), round(ds.drop_max), round(ns.noise_max),
    round(ds.drop_min / NULLIF(ns.noise_max,0), 1),
    (ds.last_drop - ((EXTRACT(ISODOW FROM ds.last_drop)::int + 1) % 7))::date
  ) AS evidence
FROM cfg c
CROSS JOIN params pr
JOIN med m USING(store_code,route_key)
JOIN dropstats ds USING(store_code,route_key)
LEFT JOIN noisestats ns USING(store_code,route_key)
JOIN graw gr USING(store_code,route_key)
JOIN median_regime mr USING(store_code,route_key)
JOIN regime rg USING(store_code,route_key)
JOIN dow_final df USING(store_code,route_key)
JOIN modal mo USING(store_code,route_key)
ORDER BY c.store_code, c.route_key
$fn$;

REVOKE ALL ON FUNCTION public.rpc_derive_supplier_cadence(text,text,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_derive_supplier_cadence(text,text,int) TO authenticated;
