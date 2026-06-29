-- =============================================================================
-- bt_009_identifiers_dept.sql
-- SB-CC-BT-004 Identifiers, department grouping, counted-dead rule, full PDF
-- Branch: bt-perf-001  |  Builds on BT-003 (bt_008_precompute.sql)
-- ON PIETER: run AFTER bt_008_precompute.sql has been applied and seeded.
--            This file ALTERs the existing tables and replaces the refresh
--            functions. Run SELECT refresh_bt_precompute() at the bottom
--            re-seeds everything automatically.
-- =============================================================================
-- WHAT THIS ADDS (four changes from the brief):
--
--   1. IDENTIFIERS -- every product row in Heroes and Dead Lines carries
--      store_code, product_code, EAN (from v_ean_bridge, real GS1 only).
--      A line with no real GS1 EAN stores NULL -- the UI shows "no EAN".
--
--   2. DEPARTMENT -- every product line carries department_name
--      (sigma_articles.department_nr -> sigma_departments.name) so the UI
--      can group Heroes and Dead Lines by department first, sub-department
--      (merch group label) second.
--
--   3. COUNTED-DEAD RULE + ACTION BUCKETS -- Dead Lines (DEAD_91D) split into
--      three action buckets precomputed at refresh time:
--        MARKDOWN  -- dead, has SOH, counted in DIWAINV in last 91 days.
--                     Cash we know is there. Markdown or price action needed.
--        DERANGE   -- dead, no SOH. Nothing on floor. Delist from order screen.
--        VERIFY    -- dead, has SOH but NOT counted in 91 days. SOH unproven.
--                     Count before actioning.
--      Very-slow lines (VSLOW_91D) stay as SLOW bucket -- separate action.
--      counted_91d precomputed from sigma_movements (movement_type='I',
--      module='DIWAINV', last 91 days). 27,427 counts confirmed on SPAR stores.
--
--   4. DOWNLOAD -- multi-page PDF detail handled in bt.html JS (not SQL).
--      The RPCs already return all fields needed; bt.html builds the detail
--      pages from _pruneData and _heroData stored on page load.
--
-- Performance: all new joins (EAN bridge, sigma_departments, counted CTE)
-- run at nightly refresh time, NOT in the read path. RPCs read the
-- precomputed columns -- no new live scans.
-- =============================================================================


-- =============================================================================
-- 1. Extend l2_bt_tail with new columns
-- =============================================================================

ALTER TABLE public.l2_bt_tail
    ADD COLUMN IF NOT EXISTS ean             text,
    ADD COLUMN IF NOT EXISTS department_name text,
    ADD COLUMN IF NOT EXISTS counted_91d     boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS action_bucket   text;

-- Drop index if changing (safe -- IF NOT EXISTS on recreation)
DROP INDEX IF EXISTS public.idx_l2_bt_tail_bucket;
CREATE INDEX IF NOT EXISTS idx_l2_bt_tail_bucket
    ON public.l2_bt_tail (action_bucket) WHERE action_bucket IS NOT NULL;


-- =============================================================================
-- 2. Extend l2_bt_heroes with new columns
-- =============================================================================

ALTER TABLE public.l2_bt_heroes
    ADD COLUMN IF NOT EXISTS ean             text,
    ADD COLUMN IF NOT EXISTS department_name text;


-- =============================================================================
-- 3. refresh_l2_bt_tail() -- replaces BT-003 version
--    Adds: EAN from v_ean_bridge, department_name from sigma_departments,
--    counted_91d from sigma_movements (I/DIWAINV last 91d), action_bucket.
--    NOTE: sigma_departments.name -- if the live column is dept_name, change
--    sd.name below to sd.dept_name (one occurrence). The brief confirms .name.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_tail()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
    TRUNCATE public.l2_bt_tail;
    INSERT INTO public.l2_bt_tail
        (store_code, merch_group_nr, label, bucket, product_code, description,
         units_91, units_365, flag, last_sale_date, soh, soh_cash,
         ean, department_name, counted_91d, action_bucket)
    WITH scoped_stores AS (
        SELECT DISTINCT store_code FROM public.l2_bt_scope
    ),
    scoped_sales AS (
        SELECT
            sc.store_code,
            sc.merch_group_nr,
            sc.label,
            sc.bucket,
            ss.product_code,
            MAX(sa.description)                                 AS description,
            MAX(sa.department_nr)                               AS department_nr,
            SUM(CASE WHEN ss.sale_date >= CURRENT_DATE - 91
                     THEN ss.qty ELSE 0 END)                    AS units_91,
            SUM(CASE WHEN ss.sale_date >= CURRENT_DATE - 365
                     THEN ss.qty ELSE 0 END)                    AS units_365,
            MAX(CASE WHEN ss.qty > 0
                     THEN ss.sale_date ELSE NULL END)           AS last_sale_date
        FROM public.l2_bt_scope sc
        JOIN public.sigma_sales ss ON ss.store_code = sc.store_code
        JOIN public.sigma_articles sa
            ON  sa.store_code     = ss.store_code
            AND sa.product_code   = ss.product_code
            AND sa.merch_group_nr = sc.merch_group_nr
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
        GROUP BY sc.store_code, sc.merch_group_nr, sc.label, sc.bucket,
                 ss.product_code
    ),
    soh_current AS (
        SELECT DISTINCT ON (sd.store_code, sd.product_code)
            sd.store_code, sd.product_code, sd.soh
        FROM public.l2_soh_daily sd
        JOIN scoped_stores s ON s.store_code = sd.store_code
        ORDER BY sd.store_code, sd.product_code, sd.snapshot_date DESC
    ),
    last_cost AS (
        SELECT DISTINCT ON (sm.store_code, sm.product_code)
            sm.store_code, sm.product_code,
            CASE WHEN ABS(sm.qty) > 0
                 THEN ABS(sm.cost_value) / ABS(sm.qty)
                 ELSE NULL END AS unit_cost
        FROM public.sigma_movements sm
        JOIN scoped_stores s ON s.store_code = sm.store_code
        WHERE sm.movement_type = 'R'
          AND sm.cost_value  IS NOT NULL
          AND sm.qty         IS NOT NULL
          AND sm.qty          <> 0
        ORDER BY sm.store_code, sm.product_code, sm.movement_date DESC
    ),
    -- Stocktake counts from DIWAINV in the last 91 days.
    -- movement_type='I', module='DIWAINV' = physical stocktake count line.
    -- Scoped to BT stores only. 27,427 counts on SPAR stores confirmed live.
    counted AS (
        SELECT DISTINCT sm.store_code, sm.product_code
        FROM public.sigma_movements sm
        JOIN scoped_stores s ON s.store_code = sm.store_code
        WHERE sm.movement_type = 'I'
          AND sm.module        = 'DIWAINV'
          AND sm.movement_date >= CURRENT_DATE - 91
          AND sm.movement_date IS NOT NULL
    )
    SELECT
        ss.store_code, ss.merch_group_nr, ss.label, ss.bucket,
        ss.product_code, ss.description,
        ss.units_91, ss.units_365,
        CASE
            WHEN ss.units_365 > 0 AND ss.units_91 = 0  THEN 'DEAD_91D'
            WHEN ss.units_91 BETWEEN 1 AND 2            THEN 'VSLOW_91D'
            ELSE NULL
        END                                             AS flag,
        ss.last_sale_date,
        COALESCE(sc.soh, 0)                             AS soh,
        CASE WHEN COALESCE(sc.soh, 0) > 0 AND lc.unit_cost IS NOT NULL
             THEN COALESCE(sc.soh, 0) * lc.unit_cost
             ELSE 0 END                                 AS soh_cash,
        -- EAN: real GS1 from v_ean_bridge. NULL = no bridge row (show "no EAN").
        eb.ean                                          AS ean,
        -- Department name: sigma_departments.name keyed by department_nr.
        -- If live column is dept_name not name, change sd.name -> sd.dept_name.
        sd.name                                         AS department_name,
        -- Counted: true if a DIWAINV stocktake line exists in last 91 days.
        (ct.product_code IS NOT NULL)                   AS counted_91d,
        -- Action bucket precomputed at refresh time so RPCs read, never compute.
        CASE
            WHEN ss.units_365 > 0 AND ss.units_91 = 0
                 AND COALESCE(sc.soh, 0) > 0 AND ct.product_code IS NOT NULL
                THEN 'MARKDOWN'
            WHEN ss.units_365 > 0 AND ss.units_91 = 0
                 AND COALESCE(sc.soh, 0) <= 0
                THEN 'DERANGE'
            WHEN ss.units_365 > 0 AND ss.units_91 = 0
                 AND COALESCE(sc.soh, 0) > 0 AND ct.product_code IS NULL
                THEN 'VERIFY'
            ELSE 'SLOW'
        END                                             AS action_bucket
    FROM scoped_sales ss
    LEFT JOIN soh_current sc
        ON  sc.store_code   = ss.store_code
        AND sc.product_code = ss.product_code
    LEFT JOIN last_cost lc
        ON  lc.store_code   = ss.store_code
        AND lc.product_code = ss.product_code
    LEFT JOIN public.v_ean_bridge eb
        ON  eb.store_code   = ss.store_code
        AND eb.product_code = ss.product_code
    LEFT JOIN public.sigma_departments sd
        ON  sd.store_code = ss.store_code
        AND sd.dept_code  = ss.department_nr::text
    LEFT JOIN counted ct
        ON  ct.store_code   = ss.store_code
        AND ct.product_code = ss.product_code
    WHERE ss.units_365 > 0
      AND ss.units_91  <= 2;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_tail() TO authenticated;


-- =============================================================================
-- 4. refresh_l2_bt_heroes() -- replaces BT-003 version
--    Adds: EAN from v_ean_bridge, department_name from sigma_departments.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_heroes()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE v_today date := CURRENT_DATE;
BEGIN
    TRUNCATE public.l2_bt_heroes;
    INSERT INTO public.l2_bt_heroes
        (store_code, merch_group_nr, label, bucket, product_code,
         description, gp_91d, units_91d, rn, daily_rate,
         ean, department_name)
    WITH trailing_91 AS (
        SELECT
            sc.store_code,
            sc.merch_group_nr,
            sc.label,
            sc.bucket,
            ss.product_code,
            MAX(sa.description)                                                AS description,
            MAX(sa.department_nr)                                              AS department_nr,
            SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value)             AS gp_91d,
            SUM(ss.qty)                                                        AS units_91d,
            ROW_NUMBER() OVER (
                PARTITION BY sc.store_code, sc.merch_group_nr
                ORDER BY SUM(ss.sales_incl_vat - ss.vat_value
                             - ss.cost_value) DESC
            )                                                                  AS rn
        FROM public.l2_bt_scope sc
        JOIN public.sigma_sales ss ON ss.store_code = sc.store_code
        JOIN public.sigma_articles sa
            ON  sa.store_code     = ss.store_code
            AND sa.product_code   = ss.product_code
            AND sa.merch_group_nr = sc.merch_group_nr
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
          AND ss.sale_date  >= v_today - 91
        GROUP BY sc.store_code, sc.merch_group_nr, sc.label, sc.bucket,
                 ss.product_code
    ),
    rate_28d AS (
        SELECT ss.store_code, ss.product_code,
               SUM(ss.qty) / 28.0 AS daily_rate
        FROM public.sigma_sales ss
        JOIN trailing_91 h
            ON  h.store_code   = ss.store_code
            AND h.product_code = ss.product_code
            AND h.rn          <= 5
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
          AND ss.sale_date  >= v_today - 28
        GROUP BY ss.store_code, ss.product_code
    )
    SELECT
        t.store_code, t.merch_group_nr, t.label, t.bucket,
        t.product_code, t.description, t.gp_91d, t.units_91d, t.rn,
        COALESCE(r.daily_rate, 0)   AS daily_rate,
        eb.ean                      AS ean,
        -- sigma_departments.name: if live column is dept_name, change to sd.dept_name
        sd.name                     AS department_name
    FROM trailing_91 t
    LEFT JOIN rate_28d r
        ON  r.store_code   = t.store_code
        AND r.product_code = t.product_code
    LEFT JOIN public.v_ean_bridge eb
        ON  eb.store_code   = t.store_code
        AND eb.product_code = t.product_code
    LEFT JOIN public.sigma_departments sd
        ON  sd.store_code = t.store_code
        AND sd.dept_code  = t.department_nr::text
    WHERE t.rn <= 5;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_heroes() TO authenticated;


-- =============================================================================
-- 5. rpc_bt_prune_list() -- replaces BT-003/BT-001 version
--    Adds: ean, department_name, counted_91d, action_bucket.
--    Return type changes -- must DROP old overloads first.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bt_prune_list();

CREATE OR REPLACE FUNCTION public.rpc_bt_prune_list()
RETURNS TABLE (
    store_code      text,
    merch_group_nr  integer,
    label           text,
    bucket          text,
    department_name text,
    product_code    bigint,
    ean             text,
    description     text,
    flag            text,
    action_bucket   text,
    counted_91d     boolean,
    reason          text,
    last_sale_date  date,
    soh             numeric,
    soh_cash        numeric,
    units_91        numeric,
    units_365       numeric
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $$
SELECT
    store_code,
    merch_group_nr,
    label,
    bucket,
    department_name,
    product_code,
    ean,
    description,
    flag,
    action_bucket,
    counted_91d,
    CASE flag
        WHEN 'DEAD_91D'  THEN 'No sales in 91 days; stock holding cash -- markdown or derange'
        WHEN 'VSLOW_91D' THEN 'Only ' || units_91::int
                              || ' unit(s) in 91 days; marginal movement'
        ELSE NULL
    END             AS reason,
    last_sale_date,
    soh,
    soh_cash,
    units_91,
    units_365
FROM public.l2_bt_tail
WHERE flag IS NOT NULL
ORDER BY action_bucket, department_name NULLS LAST, soh_cash DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_prune_list() TO anon, authenticated;


-- =============================================================================
-- 6. rpc_bt_availability() -- replaces BT-003 version
--    Adds: ean, department_name. Return type changes -- DROP old overload.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bt_availability();

CREATE OR REPLACE FUNCTION public.rpc_bt_availability()
RETURNS TABLE (
    store_code      text,
    merch_group_nr  integer,
    label           text,
    bucket          text,
    department_name text,
    product_code    bigint,
    ean             text,
    description     text,
    soh             numeric,
    daily_rate      numeric,
    days_cover      numeric,
    status          text
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $$
WITH latest_snap AS (
    SELECT store_code, MAX(snapshot_date) AS snap_date
    FROM public.l2_soh_daily
    GROUP BY store_code
)
SELECT
    h.store_code,
    h.merch_group_nr,
    h.label,
    h.bucket,
    h.department_name,
    h.product_code,
    h.ean,
    h.description,
    COALESCE(ls.soh, 0)                                                 AS soh,
    h.daily_rate,
    CASE WHEN h.daily_rate > 0
         THEN COALESCE(ls.soh, 0) / h.daily_rate
         ELSE NULL END                                                   AS days_cover,
    CASE
        WHEN COALESCE(ls.soh, 0) <= 0                                   THEN 'OUT'
        WHEN h.daily_rate > 0
         AND COALESCE(ls.soh, 0) / h.daily_rate < 7                    THEN 'SHORT'
        ELSE 'OK'
    END                                                                  AS status
FROM public.l2_bt_heroes h
LEFT JOIN latest_snap sn ON sn.store_code = h.store_code
LEFT JOIN public.l2_soh_daily ls
    ON  ls.store_code    = h.store_code
    AND ls.product_code  = h.product_code
    AND ls.snapshot_date = sn.snap_date
ORDER BY h.store_code, h.merch_group_nr, h.rn;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_availability() TO anon, authenticated;


-- =============================================================================
-- 7. Re-seed all four tables with the new columns populated.
--    refresh_bt_precompute() orchestrates all four refreshes with guards.
-- =============================================================================

SELECT public.refresh_bt_precompute();
