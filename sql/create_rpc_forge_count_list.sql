-- =============================================================================
-- create_rpc_forge_count_list.sql
-- Forge toolkit -- the count-worklist generator.
-- =============================================================================
-- SB-CC-TOOLKIT-002 items 1+2 (Pieter ruling 2026-08-12, PM brief; applied
-- 2026-08-13 via migration forge_count_list_ordering_impact_tiers). This body is
-- byte-faithful to the applied migration so main does not diverge from live
-- (canon section 13 rule 3).
--
-- ITEM 1 -- FIXED VOLUME. daily_budget = forge_config.daily_count_volume per
--   store format (SPAR 200 / TOPS 70), replacing the self-sizing
--   ceil(pool / (cycle_weeks * trading_days_per_week)) that produced the 408-611
--   line lists the stores could not execute. count_cycle_weeks stays in config,
--   informational, no longer drives the budget.
--
-- ITEM 2 -- THE PRIORITY LAW (ordering impact, never label). A lower tier never
--   displaces a higher one; the tier is decided by BEHAVIOUR/signals, not the
--   category of the line (Pieter refinement, so a negative or old code that is
--   ordering-relevant is tier 1, and a KVI/on-order negative outranks a dead one):
--     Tier 1  Ordering influencer = on order (delivery imminent, l2_on_order)
--             OR KVI (l2_kvi_profile kvi_band CRITICAL/IMPORTANT)
--             OR actively ranged / VERIFY (l2_range_state HERO/CORE/VERIFY)
--             OR the Engine's own count indictment (classification artifact='stockflow').
--             A wrong SOH here buys wrong stock or misses a sale THIS WEEK.
--     Tier 2  the rest of buy-and-sell (sold within inactive_window_days).
--     Tier 4  cosmetic ledger (negatives on dead lines, dead stock) -- still
--             counted, fills the tail, never pushes a tier-1 line off the list.
--   The old 5 categorical strata (NEW negative / Engine indictment / Inactive
--   rotation / Cyclical backbone first) are RETIRED. Cyclical coverage is
--   preserved WITHIN each tier by ordering on last_counted (never-counted first),
--   so the full tier-1 population still rotates through as lines get counted.
--
-- Every line carries its reason in plain words (R29). A small forced zero-SOH
-- audit slice (zero_audit_pct of the volume) rides the daily list. Deposits are
-- excluded (own Fixer list, ENG-007). Emission gate: class NORMAL, exists in
-- sigma_articles (SIGMA-CLEANUP base query). Modes random/targeted unchanged.
--
-- R22 (2026-08-13, all 5 stores): volumes exactly 200/70/200/70/70; every main
-- line tier-1 (ordering-relevant lines exceed the budget, so cosmetic is never
-- reached); deterministic (same seed = same list); emission gate 0 leaks; a
-- reason on every line.
--
-- ENG-006 (2026-07-11, retained): last_counted derives from the nightly
-- l2_last_counted pantry (I/DIWAINV ledger), NEVER l2_stock_position.last_inv_date
-- which is stale since 2023-06.
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
    SELECT s.store_code AS sc, s.store_type AS fmt,
      (SELECT value_num FROM forge_config f WHERE f.config_key='daily_count_volume'
         AND f.retired_on IS NULL AND f.store_format IN (s.store_type,'*') ORDER BY f.store_format DESC LIMIT 1)::int AS vol,
      (SELECT value_num FROM forge_config f WHERE f.config_key='zero_audit_pct' AND f.retired_on IS NULL LIMIT 1) AS zero_pct,
      (SELECT value_num FROM forge_config f WHERE f.config_key='inactive_window_days' AND f.retired_on IS NULL LIMIT 1)::int AS inact_days
    FROM stores s WHERE s.is_active AND s.store_code = ANY(p_stores)
  ),
  counted AS (
    SELECT lc.store_code AS sc, lc.product_code AS pc, lc.last_counted_date AS last_i, lc.last_counted_soh AS counted_soh
    FROM l2_last_counted lc WHERE lc.store_code = ANY(p_stores)
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
           (COALESCE(oo.open_order_count,0) > 0) AS on_order,
           (k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) AS is_kvi,
           rs.range_state AS range_state,
           (rs.range_state IN ('HERO','CORE','VERIFY')) AS is_ranged,
           (c.artifact = 'stockflow') AS engine_suspect,
           (random()) AS rnd
    FROM l2_stock_position sp
    JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
    LEFT JOIN counted ct ON ct.sc = sp.store_code AND ct.pc = sp.product_code
    LEFT JOIN cls_latest c ON c.sc = sp.store_code AND c.pc = sp.product_code
    LEFT JOIN l2_on_order oo ON oo.store_code = sp.store_code AND oo.product_code = sp.product_code
    LEFT JOIN l2_kvi_profile k ON k.store_code = sp.store_code AND k.product_code = sp.product_code
    LEFT JOIN l2_range_state rs ON rs.store_code = sp.store_code AND rs.product_code = sp.product_code
    WHERE sp.store_code = ANY(p_stores)
      AND sp.class = 'NORMAL'
      AND COALESCE(c.bucket,'') <> 'DEPOSIT'
      AND (p_dept_names IS NULL OR sp.dept_name = ANY(p_dept_names))
  ),
  tiered AS (
    SELECT p.*, cfg.vol, cfg.zero_pct, cfg.inact_days,
      CASE WHEN p.on_order OR p.is_kvi OR p.is_ranged OR p.engine_suspect THEN 1
           WHEN p.last_sale_date IS NOT NULL AND p.last_sale_date >= CURRENT_DATE - cfg.inact_days THEN 2
           ELSE 4 END AS order_tier
    FROM pool p JOIN cfg ON cfg.sc = p.sc
  ),
  main_sel AS (
    SELECT t.*,
      CEIL(t.vol * t.zero_pct / 100.0)::int AS zero_slice,
      ROW_NUMBER() OVER (PARTITION BY t.sc
        ORDER BY t.order_tier ASC, t.last_inv_date ASC NULLS FIRST, t.cap DESC NULLS LAST, t.subdept, t.pc) AS rn
    FROM tiered t WHERE t.soh0 <> 0
  ),
  main_pick AS ( SELECT *, false AS is_zero_audit, NULL::text AS mode_label FROM main_sel WHERE rn <= (vol - zero_slice) ),
  zero_sel AS (
    SELECT t.*, CEIL(t.vol * t.zero_pct / 100.0)::int AS zero_slice,
      ROW_NUMBER() OVER (PARTITION BY t.sc ORDER BY t.rnd) AS rn
    FROM tiered t WHERE t.soh0 = 0
  ),
  zero_pick AS ( SELECT *, true AS is_zero_audit, NULL::text AS mode_label FROM zero_sel WHERE rn <= zero_slice ),
  daily AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,
           on_order,is_kvi,range_state,engine_suspect,order_tier,is_zero_audit,mode_label
    FROM main_pick WHERE p_mode='daily'
    UNION ALL
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,
           on_order,is_kvi,range_state,engine_suspect,order_tier,is_zero_audit,mode_label
    FROM zero_pick WHERE p_mode='daily'
  ),
  rand_mode AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,
           on_order,is_kvi,range_state,engine_suspect, NULL::int AS order_tier, false AS is_zero_audit, 'Random sample'::text AS mode_label
    FROM (
      SELECT p.*, c.vol AS store_vol,
             ROW_NUMBER() OVER (PARTITION BY p.sc ORDER BY p.rnd) AS rn
      FROM pool p JOIN cfg c ON c.sc = p.sc WHERE p.soh0 <> 0
    ) x WHERE p_mode='random' AND x.rn <= COALESCE(p_n, x.store_vol)
  ),
  targeted AS (
    SELECT sc,pc,descr,dept,subdept,soh0,cap,last_inv_date,last_sale_date,tier0,bucket_reason,ek,es,
           on_order,is_kvi,range_state,engine_suspect, NULL::int AS order_tier, false AS is_zero_audit, 'Targeted area'::text AS mode_label
    FROM pool p WHERE p_mode='targeted' AND p.soh0 <> 0
  ),
  chosen AS ( SELECT * FROM daily UNION ALL SELECT * FROM rand_mode UNION ALL SELECT * FROM targeted )
  SELECT ch.sc, ch.pc, ch.descr, ch.dept, ch.subdept, ch.soh0, ch.cap, ch.ek, ch.es, ch.tier0,
         ch.last_inv_date, ch.last_sale_date,
         CASE WHEN ch.mode_label IS NOT NULL THEN 0
              WHEN ch.is_zero_audit THEN 5
              WHEN ch.order_tier=1 THEN 1
              WHEN ch.order_tier=2 THEN 4
              ELSE 3 END AS stratum,
         CASE WHEN ch.mode_label IS NOT NULL THEN ch.mode_label
              WHEN ch.is_zero_audit THEN 'Zero-SOH audit'
              WHEN ch.order_tier=1 THEN 'Ordering influencer'
              WHEN ch.order_tier=2 THEN 'Buy-and-sell'
              ELSE 'Cosmetic ledger' END AS stratum_label,
         (ch.soh0 = 0) AS forced_zero_soh,
         CASE
           WHEN ch.mode_label IS NOT NULL THEN 'Selected by '||ch.mode_label||' mode.'
           WHEN ch.is_zero_audit THEN 'Ledger says none. Spot audit that catches stock the system does not know it has.'
           WHEN ch.order_tier=1 THEN
             (CASE WHEN ch.soh0 < 0 THEN 'Below zero and ordering-relevant. ' ELSE '' END)
             || (CASE
                   WHEN ch.on_order THEN 'On order now, count before it lands so the receiving is right.'
                   WHEN ch.engine_suspect THEN 'The Engine suspects the shelf and the ledger disagree ('||COALESCE(ch.bucket_reason,'count')||').'
                   WHEN ch.is_kvi THEN 'Key line (KVI). A wrong number here misses a sale or over-buys this week.'
                   WHEN ch.range_state = 'VERIFY' THEN 'Flagged to verify before ordering.'
                   ELSE 'Actively ranged seller. Its SOH feeds an order this week.'
                 END)
           WHEN ch.order_tier=2 THEN 'Buy-and-sell line, routine rotation. Last counted '||COALESCE(ch.last_inv_date::text,'never')||'.'
           ELSE (CASE WHEN ch.soh0 < 0 THEN 'Below zero on a line that is not selling. A procedural error to clean up.'
                      ELSE 'Holding stock but not selling, presence unproven. Last counted '||COALESCE(ch.last_inv_date::text,'never')||'.' END)
         END AS story
  FROM chosen ch
  ORDER BY ch.sc,
    CASE WHEN ch.mode_label IS NOT NULL THEN 9 WHEN ch.is_zero_audit THEN 8 ELSE ch.order_tier END,
    ch.subdept, ch.pc;
END $function$;

GRANT EXECUTE ON FUNCTION public.rpc_forge_count_list(text[], text, text[], integer, double precision) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
