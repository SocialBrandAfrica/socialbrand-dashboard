-- =============================================================================
-- create_rpc_forge_count_list.sql
-- Forge toolkit (2026-07-10 build). Built live, never committed to the repo
-- until this pass (HANDOVER-CURRENT item 10, "Forge fold-in" debt).
-- =============================================================================
-- The count-worklist generator: 5 strata in priority order (1 NEW negative,
-- 2 engine indictment/stockflow artifact, 3 inactive rotation, 4 cyclical
-- backbone filling the remaining daily budget, 5 forced zero-SOH random
-- audit), plus 'random'/'targeted' modes for ad hoc sampling. Daily budget
-- per store = ceil(countable pool / (cycle_weeks x trading_days_per_week)),
-- store-format-aware via forge_config. Deposits (bucket='DEPOSIT') are
-- EXCLUDED from every stratum -- own manual list via rpc_forge_lines
-- (ENG-007), never the routine count stack.
--
-- ENG-006 (2026-07-11): the `counted` CTE originally scanned sigma_movements
-- ad hoc per request (DISTINCT ON (store,product), movement_type='I',
-- movement_date DESC, ~1s/store). Repointed to the nightly `l2_last_counted`
-- pantry fact -- same ledger source and selection, precomputed once instead
-- of per request. Verified identical output before/after (R22): daily-mode
-- strata sizes unchanged at all 5 stores; one line's last-counted-date
-- presence shifted at 10116 (427->426 between the two verification calls --
-- real trading activity landing a new stocktake row in the interval, not a
-- defect).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_forge_count_list(p_stores text[], p_mode text DEFAULT 'daily'::text, p_dept_names text[] DEFAULT NULL::text[], p_n integer DEFAULT NULL::integer, p_seed double precision DEFAULT NULL::double precision)
 RETURNS TABLE(store_code text, product_code bigint, description text, dept_name text, subdept_name text, soh numeric, capital_value numeric, ean_key text, ean_status text, tier text, last_counted date, last_sale date, stratum integer, stratum_label text, forced_zero_soh boolean, story text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_seed float := COALESCE(p_seed, 0.42);
BEGIN
  PERFORM setseed(v_seed);
  RETURN QUERY
  WITH cfg AS (
    SELECT s.store_code AS sc,
      (SELECT value_num FROM forge_config f WHERE f.config_key='count_cycle_weeks'
        AND f.retired_on IS NULL AND f.store_format IN (s.store_type,'*') ORDER BY f.store_format DESC LIMIT 1) AS cycle_weeks,
      (SELECT value_num FROM forge_config f WHERE f.config_key='trading_days_per_week' AND f.retired_on IS NULL LIMIT 1) AS tdpw,
      (SELECT value_num FROM forge_config f WHERE f.config_key='inactive_window_days' AND f.retired_on IS NULL LIMIT 1) AS inact_days,
      (SELECT value_num FROM forge_config f WHERE f.config_key='inactive_slice_pct' AND f.retired_on IS NULL LIMIT 1) AS inact_pct,
      (SELECT value_num FROM forge_config f WHERE f.config_key='zero_audit_pct' AND f.retired_on IS NULL LIMIT 1) AS zero_pct
    FROM stores s WHERE s.is_active AND s.store_code = ANY(p_stores)
  ),
  counted AS (
    -- ENG-006 (2026-07-11): repointed from an ad-hoc sigma_movements scan to
    -- the nightly l2_last_counted pantry fact -- same ledger source, same
    -- DISTINCT ON (store,product)/movement_date DESC selection, precomputed.
    SELECT lc.store_code AS sc, lc.product_code AS pc, lc.last_counted_date AS last_i, lc.last_counted_soh AS counted_soh
    FROM l2_last_counted lc
    WHERE lc.store_code = ANY(p_stores)
  ),
  cls_latest AS (
    SELECT c.store_code AS sc, c.product_code AS pc, c.bucket, c.artifact, c.bucket_reason, c.ean_key, c.ean_status
    FROM l2_classification c
    JOIN (SELECT store_code, MAX(snapshot_date) d FROM l2_classification
          WHERE store_code = ANY(p_stores) GROUP BY store_code) lx
      ON lx.store_code = c.store_code AND lx.d = c.snapshot_date
  ),
  pool AS (
    SELECT sp.store_code AS sc, sp.product_code AS pc, sp.description AS descr,
           sp.dept_name AS dept, sp.subdept_name AS subdept, sp.soh AS soh0, sp.capital_value AS cap,
           ct.last_i AS last_inv_date, ct.counted_soh AS last_inv_soh,
           sp.last_sale_date, sp.tier AS tier0,
           c.artifact, c.bucket_reason, c.ean_key AS ek, c.ean_status AS es,
           (random()) AS rnd
    FROM l2_stock_position sp
    JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
    LEFT JOIN counted ct ON ct.sc = sp.store_code AND ct.pc = sp.product_code
    LEFT JOIN cls_latest c ON c.sc = sp.store_code AND c.pc = sp.product_code
    WHERE sp.store_code = ANY(p_stores)
      AND sp.class = 'NORMAL'
      AND COALESCE(c.bucket,'') <> 'DEPOSIT'   -- deposits: own manual list (Fixer), never the routine stack
      AND (p_dept_names IS NULL OR sp.dept_name = ANY(p_dept_names))
  ),
  budget AS (
    SELECT cfg.sc,
           CEIL( (SELECT COUNT(*) FROM pool WHERE pool.sc = cfg.sc AND pool.soh0 <> 0)::numeric
                 / GREATEST(cfg.cycle_weeks * cfg.tdpw, 1) )::int AS daily_budget,
           cfg.inact_days, cfg.inact_pct, cfg.zero_pct
    FROM cfg
  ),
  s1 AS (
    SELECT p.*, 1 AS st, 'NEW negative' AS lbl FROM pool p
    WHERE p.soh0 < 0 AND (p.last_inv_date IS NULL OR COALESCE(p.last_inv_soh,0) >= 0 OR p.soh0 < p.last_inv_soh)
  ),
  s2 AS (
    SELECT p.*, 2 AS st, 'Engine indictment' AS lbl FROM pool p
    WHERE p.soh0 <> 0 AND p.artifact = 'stockflow'
      AND p.pc NOT IN (SELECT s1.pc FROM s1 WHERE s1.sc = p.sc)
  ),
  s3 AS (
    SELECT * FROM (
      SELECT p.*, 3 AS st, 'Inactive rotation' AS lbl,
             ROW_NUMBER() OVER (PARTITION BY p.sc ORDER BY p.last_inv_date ASC NULLS FIRST, p.cap DESC) AS rn,
             b.daily_budget, b.inact_pct
      FROM pool p JOIN budget b ON b.sc = p.sc
      WHERE p.soh0 <> 0
        AND (p.last_sale_date IS NULL OR p.last_sale_date < CURRENT_DATE - (b.inact_days)::int)
        AND p.pc NOT IN (SELECT s1.pc FROM s1 WHERE s1.sc = p.sc)
        AND p.pc NOT IN (SELECT s2.pc FROM s2 WHERE s2.sc = p.sc)
    ) x WHERE x.rn <= CEIL(x.daily_budget * x.inact_pct / 100.0)
  ),
  s4 AS (
    SELECT * FROM (
      SELECT p.*, 4 AS st, 'Cyclical backbone' AS lbl,
             ROW_NUMBER() OVER (PARTITION BY p.sc
               ORDER BY p.last_inv_date ASC NULLS FIRST, p.subdept, p.pc) AS rn,
             b.daily_budget
             - (SELECT COUNT(*) FROM s1 WHERE s1.sc = p.sc)
             - (SELECT COUNT(*) FROM s2 WHERE s2.sc = p.sc)
             - (SELECT COUNT(*) FROM s3 WHERE s3.sc = p.sc) AS remaining
      FROM pool p JOIN budget b ON b.sc = p.sc
      WHERE p.soh0 <> 0
        AND p.pc NOT IN (SELECT s1.pc FROM s1 WHERE s1.sc = p.sc)
        AND p.pc NOT IN (SELECT s2.pc FROM s2 WHERE s2.sc = p.sc)
        AND p.pc NOT IN (SELECT s3.pc FROM s3 WHERE s3.sc = p.sc)
    ) x WHERE x.rn <= GREATEST(x.remaining, 0)
  ),
  s5 AS (
    SELECT * FROM (
      SELECT p.*, 5 AS st, 'Zero-SOH audit (FORCED)' AS lbl,
             ROW_NUMBER() OVER (PARTITION BY p.sc ORDER BY p.rnd) AS rn,
             b.daily_budget, b.zero_pct
      FROM pool p JOIN budget b ON b.sc = p.sc
      WHERE p.soh0 = 0
    ) x WHERE x.rn <= CEIL(x.daily_budget * x.zero_pct / 100.0)
  ),
  daily AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM s1 WHERE p_mode='daily'
    UNION ALL SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM s2 WHERE p_mode='daily'
    UNION ALL SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM s3 WHERE p_mode='daily'
    UNION ALL SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM s4 WHERE p_mode='daily'
    UNION ALL SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM s5 WHERE p_mode='daily'
  ),
  rand_mode AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,st,lbl FROM (
      SELECT p.*, 0 AS st, 'Random sample' AS lbl,
             ROW_NUMBER() OVER (PARTITION BY p.sc, p.dept ORDER BY p.rnd) AS rn
      FROM pool p WHERE p.soh0 <> 0
    ) x WHERE p_mode='random' AND x.rn <= COALESCE(p_n, 50)
  ),
  targeted AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,0 AS st,'Targeted area' AS lbl
    FROM pool p WHERE p_mode='targeted' AND p.soh0 <> 0
  ),
  chosen AS (
    SELECT * FROM daily UNION ALL SELECT * FROM rand_mode UNION ALL SELECT * FROM targeted
  )
  SELECT ch.sc, ch.pc, ch.descr, ch.dept, ch.subdept, ch.soh0, ch.cap, ch.ek, ch.es, ch.tier0,
         ch.last_inv_date, ch.last_sale_date, ch.st, ch.lbl, (ch.soh0 = 0) AS forced_zero_soh,
         CASE ch.st
           WHEN 1 THEN 'SOH '||ch.soh0||', negative and not yet counted at this depth. Receiving gap or depletion error, count settles it.'
           WHEN 2 THEN 'Engine verdict: '||COALESCE(ch.bucket_reason,'cascade COUNT')||'. SOH '||ch.soh0||', capital R'||ROUND(ch.cap)||'.'
           WHEN 3 THEN 'No sale since '||COALESCE(ch.last_sale_date::text,'ever')||', last counted '||COALESCE(ch.last_inv_date::text,'never')||'. Presence unproven.'
           WHEN 4 THEN 'Cycle rotation, last counted '||COALESCE(ch.last_inv_date::text,'never')||'. Guarantees the full-store pass.'
           WHEN 5 THEN 'Ledger says 0. Random audit line, catches stock the ledger does not know it has.'
           ELSE 'Selected by '||ch.lbl||' mode.'
         END AS story
  FROM chosen ch
  ORDER BY ch.sc, ch.st, ch.subdept, ch.pc;
END $function$;

GRANT EXECUTE ON FUNCTION public.rpc_forge_count_list(text[], text, text[], integer, double precision) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
