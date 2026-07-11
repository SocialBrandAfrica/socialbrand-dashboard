-- =============================================================================
-- create_rpc_forge_integrity.sql
-- Forge toolkit (2026-07-10 build). Built live, never committed to the repo
-- until this pass (HANDOVER-CURRENT item 10, "Forge fold-in" debt).
-- =============================================================================
-- Seven trust instruments per store: purified_capital_share (UP is good),
-- ambiguity_debt, unresolved_ean, costless_real_stock, hidden_family_demand
-- (ENG-005's family-draw-exceeds-scan lines), count_coverage_91d (UP is
-- good), negative_book, kvi_lines_oos -- each with pool_num/ratio_pct and a
-- named story (R29). kvi_lines_oos returns NULL (not zero) for a store with
-- no KVI profile yet (Ship 2 ran SPAR-first, ENG-007) -- a named gap, never a
-- false "zero OOS" reading.
--
-- ENG-006 (2026-07-11): the `counted` CTE (count_coverage_91d's numerator)
-- originally scanned sigma_movements ad hoc per request (movement_type='I',
-- movement_date >= CURRENT_DATE - 91, GROUP BY store/product). Repointed to
-- the nightly `l2_last_counted` pantry fact's `counted_91d` flag -- same
-- ledger source. Verified identical output before/after (R22):
-- count_coverage_91d totals byte-identical bank-wide (10116=2807, 21355=500,
-- 80175=4123, 80176=596, 80579=421).
-- =============================================================================

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
counted AS (
  -- ENG-006 (2026-07-11): repointed from an ad-hoc sigma_movements 91d scan to
  -- the nightly l2_last_counted pantry fact's counted_91d flag, same source.
  SELECT lc.store_code AS sc, lc.product_code AS pc
  FROM l2_last_counted lc JOIN st ON st.sc = lc.store_code
  WHERE lc.counted_91d
),
pool AS (
  SELECT sp.store_code AS sc,
         COUNT(*) FILTER (WHERE sp.soh <> 0) AS gate_pool,
         COUNT(*) FILTER (WHERE sp.soh <> 0 AND ct.pc IS NOT NULL) AS counted_91,
         COUNT(*) FILTER (WHERE sp.soh < 0) AS negatives
  FROM l2_stock_position sp
  JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
  JOIN st ON st.sc = sp.store_code
  LEFT JOIN counted ct ON ct.sc = sp.store_code AND ct.pc = sp.product_code
  WHERE sp.class = 'NORMAL'
  GROUP BY sp.store_code
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
  -- LEFT from the store list: every store gets a row; no-profile stores carry NULLs (named gap)
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
         'AMBIGUOUS is a work queue, not a resting place (canon §8.10). Target 0, resolved by fixing data at source, never by guessing.'
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

GRANT EXECUTE ON FUNCTION public.rpc_forge_integrity(text[]) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
