-- =============================================================================
-- ENG-233 -- THE UNCOUNTED POOL HAS ONE HOME (SB-CC-STOCKTAKE-001 section 2 check)
--
-- THE DEFECT, measured 2026-10-13 16:2x SAST at 10116 (whole pool, R22):
--   The toolkit scoreboard (rpc_forge_integrity, count_coverage_91d) read 3,229 counted of
--   8,533 = 5,304 uncounted. Its drill-down list (rpc_forge_integrity_lines) returned 5,419.
--   The 115 lines are ALL lines last counted on 2026-07-13, none in the other direction.
--   MECHANISM (DEDUCTIVE): the scoreboard read l2_last_counted.counted_91d, a boolean computed
--   against CURRENT_DATE at the nightly refresh (2026-10-12 UTC, cutoff 07-13), while the list
--   recomputed against CURRENT_DATE - 91 live (2026-10-13, cutoff 07-14). A stored boolean
--   frozen against a moving date is a stored aggregate that disagrees with its own lines
--   the day after (canon 12e 4b). Two definitions of "counted in 91 days", one day apart.
--
-- THE FIX. One view, v_stocktake_pool: the countable pool (class NORMAL, soh <> 0, exists in
-- sigma_articles) with counted_91 DERIVED ON READ from l2_last_counted.last_counted_date
-- against the STORE-LOCAL date (stores.timezone, ENG-117), never the stored boolean.
-- Three readers, one home: rpc_forge_integrity (the scoreboard), rpc_forge_integrity_lines
-- (its list) and the stocktake count app (rpc_stocktake_*). R32/R33: one L2 fact.
--
-- l2_last_counted.last_counted_date equals the live MAX I-movement date on every pool line
-- (0 differing of 8,533 at 10116, measured), so the live NOT EXISTS over sigma_movements the
-- list used to run is replaced without moving a line except the boundary day.
--
-- R30 ADDENDUM 3 SITE COUNT (the pattern "counted in 91 days"): 7 functions carry it.
--   CHANGED (3 readers on the one home): rpc_forge_integrity, rpc_forge_integrity_lines, new app.
--   NOT CHANGED, named: refresh_l2_last_counted (the writer, keeps the flag),
--   refresh_l2_range_state and refresh_l2_bt_tail (run in the nightly chain straight after the
--   writer, so the flag is current at the moment they read), refresh_l2_classification (its own
--   counted_91 signal, anchored to the store's freshest movement date by canon 8.3, a
--   different anchor on purpose), rpc_bt_prune_list (reads the flag at request time, up to a
--   day of drift, BT lane, owner CC, rides its next touch).
--
-- GRANTS (R30 addendum extension): the view is read only by SECURITY DEFINER functions, so
-- it is revoked from PUBLIC, anon and authenticated. The two integrity functions keep their
-- ACL (CREATE OR REPLACE keeps it): they are anon-readable read RPCs by design.
--
-- ROLLBACK: sql/_archive/rpc_forge_integrity_5f7b3f70_pre_eng233.sql and
--           sql/_archive/rpc_forge_integrity_lines_2049519b_pre_eng233.sql, then DROP VIEW.
-- PRE-FLIGHT (done before writing): one overload each; no SET LOCAL; LANGUAGE sql so no
-- RETURNS TABLE shadowing; ACL read; pre-state files hash-proven to the live md5.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_stocktake_pool AS
SELECT sp.client_id,
       sp.store_code,
       sp.product_code,
       sp.description,
       sp.dept_name,
       sp.subdept_name,
       sp.soh,
       sp.capital_value,
       sp.unit_cost,
       lc.last_counted_date,
       (lc.last_counted_date IS NOT NULL
        AND lc.last_counted_date >= ((now() AT TIME ZONE s.timezone)::date - 91)) AS counted_91
FROM public.l2_stock_position sp
JOIN public.sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
JOIN public.stores s ON s.store_code = sp.store_code AND s.is_active
LEFT JOIN public.l2_last_counted lc ON lc.store_code = sp.store_code AND lc.product_code = sp.product_code
WHERE sp.class = 'NORMAL' AND sp.soh <> 0;

COMMENT ON VIEW public.v_stocktake_pool IS
'GRADE: CALCULATED. The countable pool, one row per (store, product): class NORMAL, soh <> 0, exists in sigma_articles. counted_91 is DERIVED ON READ from l2_last_counted.last_counted_date against the store-local date, never from the stored l2_last_counted.counted_91d (frozen at the nightly refresh, up to a day stale: ENG-233). The ONE home of "uncounted in 91 days" for rpc_forge_integrity, rpc_forge_integrity_lines and the stocktake count app (SB-CC-STOCKTAKE-001). Read by SECURITY DEFINER functions only.';

REVOKE ALL ON public.v_stocktake_pool FROM PUBLIC;
REVOKE ALL ON public.v_stocktake_pool FROM anon;
REVOKE ALL ON public.v_stocktake_pool FROM authenticated;
GRANT SELECT ON public.v_stocktake_pool TO service_role;

CREATE OR REPLACE FUNCTION public.rpc_forge_integrity(p_stores text[] DEFAULT NULL::text[])
 RETURNS TABLE(store_code text, instrument text, value_num numeric, pool_num numeric, ratio_pct numeric, direction text, story text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH st AS (
  SELECT s.store_code AS sc FROM stores s
  WHERE s.is_active AND (p_stores IS NULL OR s.store_code = ANY(p_stores))
),
latest AS (
  SELECT c.store_code AS sc, MAX(c.snapshot_date) AS d
  FROM l2_classification c JOIN st ON st.sc = c.store_code GROUP BY c.store_code
),
cls AS (
  SELECT c.* FROM l2_classification c JOIN latest l ON l.sc = c.store_code AND l.d = c.snapshot_date
),
cap AS (
  SELECT v.store_code AS sc, v.capital_purified, v.capital_in_scope_total
  FROM v_l2_capital_by_store v JOIN st ON st.sc = v.store_code
),
pool AS (
  -- ENG-233 (2026-10-13): the countable pool and its counted-in-91-days test now come from
  -- the one home, v_stocktake_pool, derived on read against the store-local date. The stored
  -- l2_last_counted.counted_91d flag this read before was frozen at the nightly refresh.
  SELECT v.store_code AS sc,
         COUNT(*) AS gate_pool,
         COUNT(*) FILTER (WHERE v.counted_91) AS counted_91,
         COUNT(*) FILTER (WHERE v.soh < 0) AS negatives
  FROM v_stocktake_pool v
  JOIN st ON st.sc = v.store_code
  GROUP BY v.store_code
),
fam AS (
  SELECT p.store_code AS sc,
         COUNT(*) FILTER (WHERE NOT p.unit_incommensurable AND p.ros_draw_28d > p.ros_28d) AS hidden_lines,
         ROUND(SUM(GREATEST(p.ros_draw_28d - p.ros_28d, 0)) FILTER (WHERE NOT p.unit_incommensurable)::numeric, 0) AS hidden_units_day,
         COUNT(*) FILTER (WHERE NOT p.unit_incommensurable) AS commensurable
  FROM l2_bloom_ros_pantry p JOIN st ON st.sc = p.store_code
  GROUP BY p.store_code
),
kvi AS (
  SELECT st.sc,
         CASE WHEN COUNT(k.product_code) FILTER (WHERE k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) > 0
              THEN COUNT(*) FILTER (WHERE sp.soh <= 0 AND k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) END AS kvi_oos,
         NULLIF(COUNT(k.product_code) FILTER (WHERE k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')), 0) AS kvi_pool
  FROM st
  LEFT JOIN l2_kvi_profile k ON k.store_code = st.sc
  LEFT JOIN l2_stock_position sp ON sp.store_code = k.store_code AND sp.product_code = k.product_code AND sp.class = 'NORMAL'
  GROUP BY st.sc
)
SELECT sc, instrument, value_num, pool_num,
       CASE WHEN pool_num > 0 THEN ROUND(100.0 * value_num / pool_num, 1) END AS ratio_pct,
       direction, story
FROM (
  SELECT cap.sc, 'purified_capital_share' AS instrument,
         ROUND(cap.capital_purified::numeric,0) AS value_num,
         ROUND(cap.capital_in_scope_total::numeric,0) AS pool_num,
         'UP' AS direction,
         'Engine-verified sellable capital over the whole in-scope pool. Rises with real cleanup, falls silently when something moves underneath. Watch the pool too.' AS story
  FROM cap
  UNION ALL
  SELECT c.store_code, 'ambiguity_debt', COUNT(*) FILTER (WHERE c.bucket='AMBIGUOUS'), COUNT(*), 'DOWN',
         'AMBIGUOUS is a work queue, not a resting place (canon s8.10). Target 0, resolved by fixing data at source, never by guessing.'
  FROM cls c GROUP BY c.store_code
  UNION ALL
  SELECT c.store_code, 'unresolved_ean', COUNT(*) FILTER (WHERE c.ean_status='UNRESOLVED'), COUNT(*), 'DOWN',
         'Lines with no proven identity. Every one blocks TLX and cross-store intelligence.'
  FROM cls c GROUP BY c.store_code
  UNION ALL
  SELECT c.store_code, 'costless_real_stock', COUNT(*) FILTER (WHERE c.bucket='HEALTHY' AND c.soh > 0 AND COALESCE(c.unit_cost,0) = 0), COUNT(*) FILTER (WHERE c.bucket='HEALTHY'), 'DOWN',
         'HEALTHY stock carrying zero cost. Its capital is invisible, GP on it is fiction. Fix cost at source.'
  FROM cls c GROUP BY c.store_code
  UNION ALL
  SELECT fam.sc, 'hidden_family_demand', fam.hidden_lines, fam.commensurable, 'DOWN',
         'Lines whose family ledger draw exceeds their till scan ('||COALESCE(fam.hidden_units_day,0)||' units/day hidden). Ordering on scan alone understates these (ENG-005).'
  FROM fam
  UNION ALL
  SELECT pool.sc, 'count_coverage_91d', pool.counted_91, pool.gate_pool, 'UP',
         'Share of the countable pool humanly verified in 91 days (ledger I-channel, never the stale summary field). The count law pushes this to 100 inside each cycle.'
  FROM pool
  UNION ALL
  SELECT pool.sc, 'negative_book', pool.negatives, pool.gate_pool, 'DOWN',
         'Ledger lines below zero. Every one is a receiving gap or depletion error a count or GRV must settle.'
  FROM pool
  UNION ALL
  SELECT kvi.sc, 'kvi_lines_oos', kvi.kvi_oos, kvi.kvi_pool, 'DOWN',
         CASE WHEN kvi.kvi_pool IS NULL
              THEN 'NO DATA YET: the KVI profile has not been built for this store (Ship 2 ran SPAR-first). A named gap, not a zero -- the TOPS KVI pass closes it.'
              ELSE 'KVI Critical/Important lines at or below zero stock right now. Ordering exists to order what is not there (the scope-gate finding).' END
  FROM kvi
) t
ORDER BY sc, instrument
$function$;

CREATE OR REPLACE FUNCTION public.rpc_forge_integrity_lines(p_store text, p_instrument text)
 RETURNS TABLE(product_code bigint, description text, dept_name text, subdept_name text, soh numeric, capital_value numeric, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH latest AS (
  SELECT MAX(snapshot_date) AS d FROM l2_classification WHERE store_code = p_store
),
cls AS (
  SELECT c.* FROM l2_classification c JOIN latest l ON l.d = c.snapshot_date
  WHERE c.store_code = p_store
)
-- untrusted capital: what is dragging Trusted capital down (the excluded lines still carrying soh)
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'excluded from trusted capital: '||c.bucket||COALESCE(' — '||c.bucket_reason,'')
FROM cls c
WHERE p_instrument = 'purified_capital_share'
  AND c.bucket NOT IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED') AND c.soh <> 0
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       COALESCE(c.bucket_reason,'unclassifiable — data gap')
FROM cls c WHERE p_instrument = 'ambiguity_debt' AND c.bucket = 'AMBIGUOUS'
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'no proven barcode — bucket '||c.bucket
FROM cls c WHERE p_instrument = 'unresolved_ean' AND c.ean_status = 'UNRESOLVED'
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'healthy and selling, cost R0 — load the cost in Sigma'
FROM cls c WHERE p_instrument = 'costless_real_stock'
  AND c.bucket = 'HEALTHY' AND c.soh > 0 AND COALESCE(c.unit_cost,0) = 0
UNION ALL
SELECT sp.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       'SOH '||sp.soh||', last sale '||COALESCE(sp.last_sale_date::text,'never')
FROM l2_stock_position sp
JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
WHERE p_instrument = 'negative_book' AND sp.store_code = p_store AND sp.class = 'NORMAL' AND sp.soh < 0
UNION ALL
-- ENG-233 (2026-10-13): the uncounted list reads the same home as the scoreboard, so the list
-- and the number can never differ. The branch used to re-test sigma_movements against
-- CURRENT_DATE - 91 while the scoreboard read a flag frozen at the nightly refresh.
SELECT v.product_code, v.description, v.dept_name, v.subdept_name, v.soh, v.capital_value,
       'not counted in 91 days (ledger I-channel)'
FROM v_stocktake_pool v
WHERE p_instrument = 'count_coverage_91d' AND v.store_code = p_store AND NOT v.counted_91
UNION ALL
SELECT sp.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       k.kvi_band||', SOH '||sp.soh||' — order or count today'
FROM l2_stock_position sp
JOIN l2_kvi_profile k ON k.store_code = sp.store_code AND k.product_code = sp.product_code
WHERE p_instrument = 'kvi_lines_oos' AND sp.store_code = p_store AND sp.class = 'NORMAL'
  AND sp.soh <= 0 AND k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')
UNION ALL
SELECT p.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       'family draw '||ROUND(p.ros_draw_28d::numeric,1)||'/day vs till scan '||ROUND(p.ros_28d::numeric,1)||'/day — '
       ||ROUND((p.ros_draw_28d - p.ros_28d)::numeric,1)||'/day invisible to scan-based ordering'
FROM l2_bloom_ros_pantry p
LEFT JOIN l2_stock_position sp ON sp.store_code = p.store_code AND sp.product_code = p.product_code
WHERE p_instrument = 'hidden_family_demand' AND p.store_code = p_store
  AND NOT p.unit_incommensurable AND p.ros_draw_28d > p.ros_28d
ORDER BY capital_value DESC NULLS LAST
$function$;

NOTIFY pgrst, 'reload schema';
