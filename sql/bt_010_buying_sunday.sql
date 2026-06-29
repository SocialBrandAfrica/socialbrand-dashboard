-- =============================================================================
-- bt_010_buying_sunday.sql
-- SB-CC-BT-004 bug fix + SB-CC-BT-005 Sunday-week buying gauge
-- Branch: bt-perf-001  |  Builds on bt_009_identifiers_dept.sql
--
-- Two changes in one file:
--
--   BUG FIX (BT-004) -- sigma_departments join used sd.dept_code which does not
--   exist. PM confirmed correct column is department_nr. Fixed in both:
--     refresh_l2_bt_tail():   sd.department_nr = ss.department_nr
--     refresh_l2_bt_heroes(): sd.department_nr = t.department_nr
--
--   BT-005 -- weeks end on Sunday, 13-week rolling window.
--     l2_bt_buying_weekly keyed on week_ending (Sunday date).
--     refresh_l2_bt_buying_weekly() recomputes from sigma_sales / sigma_movements.
--     rpc_bt_buying() returns week_ending instead of week_start.
--     Only closed weeks (week_ending strictly before current Monday) are stored.
--
-- ON PIETER: run SELECT refresh_bt_precompute() at the bottom re-seeds all.
-- =============================================================================


-- =============================================================================
-- 1. Fix refresh_l2_bt_tail() -- correct sigma_departments join
--    Only change: sd.dept_code = ss.department_nr::text
--             --> sd.department_nr = ss.department_nr
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
        eb.ean                                          AS ean,
        sd.name                                         AS department_name,
        (ct.product_code IS NOT NULL)                   AS counted_91d,
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
        ON  sd.store_code    = ss.store_code
        AND sd.department_nr = ss.department_nr
    LEFT JOIN counted ct
        ON  ct.store_code   = ss.store_code
        AND ct.product_code = ss.product_code
    WHERE ss.units_365 > 0
      AND ss.units_91  <= 2;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_tail() TO authenticated;


-- =============================================================================
-- 2. Fix refresh_l2_bt_heroes() -- correct sigma_departments join
--    Only change: sd.dept_code = t.department_nr::text
--             --> sd.department_nr = t.department_nr
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
        sd.name                     AS department_name
    FROM trailing_91 t
    LEFT JOIN rate_28d r
        ON  r.store_code   = t.store_code
        AND r.product_code = t.product_code
    LEFT JOIN public.v_ean_bridge eb
        ON  eb.store_code   = t.store_code
        AND eb.product_code = t.product_code
    LEFT JOIN public.sigma_departments sd
        ON  sd.store_code    = t.store_code
        AND sd.department_nr = t.department_nr
    WHERE t.rn <= 5;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_heroes() TO authenticated;


-- =============================================================================
-- 3. l2_bt_buying_weekly -- keyed on week_ending (Sunday)
--    Drop and recreate: the table is fully recomputed on every refresh so
--    there is no persistent data to preserve.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_bt_buying_weekly;

CREATE TABLE public.l2_bt_buying_weekly (
    store_code      text    NOT NULL,
    week_ending     date    NOT NULL,   -- Sunday: DATE_TRUNC('week', d)::date + 6
    sales_ex        numeric,
    cogs            numeric,
    purchases       numeric,
    build           numeric,
    purchase_ratio  numeric,
    CONSTRAINT l2_bt_buying_weekly_pk PRIMARY KEY (store_code, week_ending)
);

CREATE INDEX IF NOT EXISTS idx_l2_bt_buying_weekly_store
    ON public.l2_bt_buying_weekly (store_code, week_ending DESC);


-- =============================================================================
-- 4. refresh_l2_bt_buying_weekly() -- Sunday-week logic, 13 closed weeks
--    week_ending = DATE_TRUNC('week', sale_date)::date + 6  (always a Sunday)
--    Closed week = week_ending < DATE_TRUNC('week', CURRENT_DATE)::date
--                  (the current Mon-Sun block is excluded until it closes)
--    Window = 13 Sundays = 91 days back from last completed Sunday.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_buying_weekly()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    -- Last completed Sunday: this week's Monday minus one day.
    -- DATE_TRUNC('week', CURRENT_DATE) always returns the Monday of the current
    -- ISO week.  Subtracting 1 gives the Sunday that closed last week.
    v_latest_sunday date :=
        (DATE_TRUNC('week', CURRENT_DATE)::date) - 1;
    -- 13-week window: keep the 13 most recent closed Sundays.
    -- 13 Sundays = 12 intervals of 7 days = 84 days before v_latest_sunday.
    v_from_sunday   date;
    -- Earliest sale date to scan (Monday of the oldest week).
    v_scan_from     date;
BEGIN
    v_from_sunday := v_latest_sunday - 84;
    v_scan_from   := v_from_sunday - 6;   -- Monday of that week

    TRUNCATE public.l2_bt_buying_weekly;
    INSERT INTO public.l2_bt_buying_weekly
        (store_code, week_ending, sales_ex, cogs, purchases, build, purchase_ratio)
    WITH scoped_stores AS (
        SELECT DISTINCT store_code FROM public.l2_bt_scope
    ),
    weekly_sales AS (
        SELECT
            s.store_code,
            (DATE_TRUNC('week', ss.sale_date)::date + 6)    AS week_ending,
            SUM(ss.sales_incl_vat - ss.vat_value)           AS sales_ex,
            SUM(ss.cost_value)                               AS cogs
        FROM public.sigma_sales ss
        JOIN scoped_stores s ON s.store_code = ss.store_code
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
          AND ss.sale_date  >= v_scan_from
          AND ss.sale_date   < DATE_TRUNC('week', CURRENT_DATE)::date
        GROUP BY s.store_code,
                 (DATE_TRUNC('week', ss.sale_date)::date + 6)
    ),
    weekly_purchases AS (
        SELECT
            s.store_code,
            (DATE_TRUNC('week', sm.movement_date)::date + 6) AS week_ending,
            SUM(sm.cost_value)                                AS purchases
        FROM public.sigma_movements sm
        JOIN scoped_stores s ON s.store_code = sm.store_code
        WHERE sm.movement_type    = 'R'
          AND sm.movement_date   IS NOT NULL
          AND sm.movement_date   >= v_scan_from
          AND sm.movement_date    < DATE_TRUNC('week', CURRENT_DATE)::date
        GROUP BY s.store_code,
                 (DATE_TRUNC('week', sm.movement_date)::date + 6)
    )
    SELECT
        COALESCE(ws.store_code, wp.store_code)              AS store_code,
        COALESCE(ws.week_ending, wp.week_ending)            AS week_ending,
        COALESCE(ws.sales_ex, 0)                            AS sales_ex,
        COALESCE(ws.cogs, 0)                                AS cogs,
        COALESCE(wp.purchases, 0)                           AS purchases,
        COALESCE(wp.purchases, 0) - COALESCE(ws.cogs, 0)   AS build,
        CASE WHEN COALESCE(ws.sales_ex, 0) > 0
             THEN COALESCE(wp.purchases, 0) / ws.sales_ex * 100
             ELSE NULL END                                   AS purchase_ratio
    FROM weekly_sales ws
    FULL OUTER JOIN weekly_purchases wp
        ON  wp.store_code  = ws.store_code
        AND wp.week_ending = ws.week_ending
    -- Keep only the 13-week window and exclude any partial-week rows.
    -- FULL OUTER on scoped stores means both sides are already scoped;
    -- the date filters above already exclude the current open week.
    WHERE COALESCE(ws.week_ending, wp.week_ending) >= v_from_sunday
      AND COALESCE(ws.week_ending, wp.week_ending) <= v_latest_sunday;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_buying_weekly() TO authenticated;


-- =============================================================================
-- 5. rpc_bt_buying() -- returns week_ending (Sunday) instead of week_start
--    Params unchanged: p_store text, p_from date, p_to date.
--    Alarm logic unchanged: HIGH >95 on a single closed week, OVER >88 two in a row.
--    All rows in the table are closed weeks, so status is always valid.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bt_buying(text, date, date);

CREATE OR REPLACE FUNCTION public.rpc_bt_buying(
    p_store text,
    p_from  date,
    p_to    date
)
RETURNS TABLE (
    store_code      text,
    week_ending     date,
    sales_ex        numeric,
    cogs            numeric,
    purchases       numeric,
    build           numeric,
    purchase_ratio  numeric,
    status          text
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $$
WITH series AS (
    SELECT
        bw.store_code,
        bw.week_ending,
        bw.sales_ex,
        bw.cogs,
        bw.purchases,
        bw.build,
        bw.purchase_ratio,
        LAG(bw.purchase_ratio) OVER (
            PARTITION BY bw.store_code ORDER BY bw.week_ending
        ) AS prev_ratio
    FROM public.l2_bt_buying_weekly bw
    WHERE bw.store_code  = p_store
      AND bw.week_ending >= p_from
      AND bw.week_ending <= p_to
)
SELECT
    store_code,
    week_ending,
    sales_ex,
    cogs,
    purchases,
    build,
    purchase_ratio,
    CASE
        WHEN purchase_ratio > 95                          THEN 'HIGH'
        WHEN purchase_ratio > 88 AND prev_ratio > 88      THEN 'OVER'
        ELSE 'OK'
    END AS status
FROM series
ORDER BY week_ending;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_buying(text, date, date) TO anon, authenticated;


-- =============================================================================
-- 6. Re-seed all tables.
--    refresh_bt_precompute() orchestrates all four refresh functions with guards.
-- =============================================================================

SELECT public.refresh_bt_precompute();
