-- =============================================================================
-- bt_008_precompute.sql
-- SB-CC-BT-003 Bonnie Tyler Engine: precompute for speed (timeout fix)
-- Branch: bt-perf-001  |  Priority: HIGH -- live cards failing on anon key
-- ON PIETER: run ONCE in Supabase SQL editor after all prior bt_00N files
--            applied. Populates all four tables immediately.
-- =============================================================================
-- PROBLEM: rpc_bt_prune_list and rpc_bt_buying time out on the anon key
-- because they scan sigma_sales (3.6m), l2_soh_daily (6.3m), and
-- sigma_movements (2.7m) live on every call. Even rpc_bt_scorecard is slow.
--
-- FIX: convert the four heavy views to nightly-refreshed L2 tables.
-- Every rpc_bt_* call then reads a small precomputed table (<10k rows each).
-- Target: every card <1s on the anon key, cold open.
--
-- Changes in this file:
--   1. l2_bt_monthly       VIEW -> TABLE + refresh_l2_bt_monthly()
--   2. l2_bt_buying_weekly VIEW -> TABLE + refresh_l2_bt_buying_weekly()
--   3. l2_bt_tail          VIEW -> TABLE + refresh_l2_bt_tail()
--   4. l2_bt_heroes        VIEW -> TABLE (+ daily_rate) + refresh_l2_bt_heroes()
--   5. rpc_bt_availability() rewired to precomputed heroes + bounded SOH
--   6. refresh_bt_precompute() -- orchestrates all four refreshes
--   7. PERFORM refresh_bt_precompute() -- seeds the tables immediately
--
-- Nightly scheduling: add PERFORM refresh_bt_precompute(); to
-- refresh_l2_pipeline() -- see create_refresh_l2_pipeline.sql (updated).
-- =============================================================================


-- =============================================================================
-- 1. l2_bt_monthly  (VIEW -> TABLE)
-- =============================================================================

DROP VIEW IF EXISTS public.l2_bt_monthly;

CREATE TABLE IF NOT EXISTS public.l2_bt_monthly (
    store_code      text        NOT NULL,
    merch_group_nr  integer     NOT NULL,
    label           text,
    bucket          text,
    month_start     date        NOT NULL,
    sales_ex        numeric,
    gp              numeric,
    gp_pct          numeric,
    units           numeric,
    CONSTRAINT l2_bt_monthly_pk PRIMARY KEY (store_code, merch_group_nr, month_start)
);

CREATE INDEX IF NOT EXISTS idx_l2_bt_monthly_month
    ON public.l2_bt_monthly (month_start);

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_monthly()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
    TRUNCATE public.l2_bt_monthly;
    INSERT INTO public.l2_bt_monthly
        (store_code, merch_group_nr, label, bucket, month_start,
         sales_ex, gp, gp_pct, units)
    SELECT
        sc.store_code,
        sc.merch_group_nr,
        sc.label,
        sc.bucket,
        DATE_TRUNC('month', ss.sale_date)::date     AS month_start,
        SUM(ss.sales_incl_vat - ss.vat_value)       AS sales_ex,
        SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value) AS gp,
        CASE WHEN SUM(ss.sales_incl_vat - ss.vat_value) > 0
             THEN SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value)
                  / SUM(ss.sales_incl_vat - ss.vat_value) * 100
             ELSE 0 END                             AS gp_pct,
        SUM(ss.qty)                                 AS units
    FROM public.l2_bt_scope sc
    JOIN public.sigma_sales ss ON ss.store_code = sc.store_code
    JOIN public.sigma_articles sa
        ON  sa.store_code     = ss.store_code
        AND sa.product_code   = ss.product_code
        AND sa.merch_group_nr = sc.merch_group_nr
    WHERE ss.period_kind = 'T'
      AND ss.txn_kind    = 1
      AND ss.sale_date  >= '2025-02-01'
    GROUP BY sc.store_code, sc.merch_group_nr, sc.label, sc.bucket,
             DATE_TRUNC('month', ss.sale_date);
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_monthly() TO authenticated;


-- =============================================================================
-- 2. l2_bt_buying_weekly  (VIEW -> TABLE)
-- =============================================================================

DROP VIEW IF EXISTS public.l2_bt_buying_weekly;

CREATE TABLE IF NOT EXISTS public.l2_bt_buying_weekly (
    store_code      text    NOT NULL,
    week_start      date    NOT NULL,
    sales_ex        numeric,
    cogs            numeric,
    purchases       numeric,
    build           numeric,
    purchase_ratio  numeric,
    CONSTRAINT l2_bt_buying_weekly_pk PRIMARY KEY (store_code, week_start)
);

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_buying_weekly()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
    TRUNCATE public.l2_bt_buying_weekly;
    INSERT INTO public.l2_bt_buying_weekly
        (store_code, week_start, sales_ex, cogs, purchases, build, purchase_ratio)
    WITH scoped_stores AS (
        SELECT DISTINCT store_code FROM public.l2_bt_scope
    ),
    weekly_sales AS (
        SELECT
            ss.store_code,
            DATE_TRUNC('week', ss.sale_date)::date  AS week_start,
            SUM(ss.sales_incl_vat - ss.vat_value)   AS sales_ex,
            SUM(ss.cost_value)                       AS cogs
        FROM public.sigma_sales ss
        JOIN scoped_stores sc ON sc.store_code = ss.store_code
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
        GROUP BY ss.store_code, DATE_TRUNC('week', ss.sale_date)
    ),
    weekly_purchases AS (
        SELECT
            sm.store_code,
            DATE_TRUNC('week', sm.movement_date)::date AS week_start,
            SUM(sm.cost_value)                          AS purchases
        FROM public.sigma_movements sm
        JOIN scoped_stores sc ON sc.store_code = sm.store_code
        WHERE sm.movement_type   = 'R'
          AND sm.movement_date IS NOT NULL
        GROUP BY sm.store_code, DATE_TRUNC('week', sm.movement_date)
    )
    SELECT
        COALESCE(ws.store_code, wp.store_code)              AS store_code,
        COALESCE(ws.week_start, wp.week_start)              AS week_start,
        COALESCE(ws.sales_ex, 0)                            AS sales_ex,
        COALESCE(ws.cogs, 0)                                AS cogs,
        COALESCE(wp.purchases, 0)                           AS purchases,
        COALESCE(wp.purchases, 0) - COALESCE(ws.cogs, 0)   AS build,
        CASE WHEN COALESCE(ws.sales_ex, 0) > 0
             THEN COALESCE(wp.purchases, 0) / ws.sales_ex * 100
             ELSE NULL END                                  AS purchase_ratio
    FROM weekly_sales ws
    FULL OUTER JOIN weekly_purchases wp
        ON  wp.store_code = ws.store_code
        AND wp.week_start = ws.week_start;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_buying_weekly() TO authenticated;


-- =============================================================================
-- 3. l2_bt_tail  (VIEW -> TABLE)
-- =============================================================================

DROP VIEW IF EXISTS public.l2_bt_tail;

CREATE TABLE IF NOT EXISTS public.l2_bt_tail (
    store_code      text        NOT NULL,
    merch_group_nr  integer     NOT NULL,
    label           text,
    bucket          text,
    product_code    bigint      NOT NULL,
    description     text,
    units_91        numeric,
    units_365       numeric,
    flag            text,
    last_sale_date  date,
    soh             numeric,
    soh_cash        numeric,
    CONSTRAINT l2_bt_tail_pk PRIMARY KEY (store_code, merch_group_nr, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_bt_tail_flag
    ON public.l2_bt_tail (flag) WHERE flag IS NOT NULL;

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_tail()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
    TRUNCATE public.l2_bt_tail;
    INSERT INTO public.l2_bt_tail
        (store_code, merch_group_nr, label, bucket, product_code, description,
         units_91, units_365, flag, last_sale_date, soh, soh_cash)
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
             ELSE 0 END                                 AS soh_cash
    FROM scoped_sales ss
    LEFT JOIN soh_current sc
        ON  sc.store_code   = ss.store_code
        AND sc.product_code = ss.product_code
    LEFT JOIN last_cost lc
        ON  lc.store_code   = ss.store_code
        AND lc.product_code = ss.product_code
    WHERE ss.units_365 > 0
      AND ss.units_91  <= 2;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_tail() TO authenticated;


-- =============================================================================
-- 4. l2_bt_heroes  (VIEW -> TABLE + daily_rate column)
--    daily_rate is the 28-day rate of sale precomputed at refresh time.
--    rpc_bt_availability then only needs one day of l2_soh_daily.
-- =============================================================================

DROP VIEW IF EXISTS public.l2_bt_heroes;

CREATE TABLE IF NOT EXISTS public.l2_bt_heroes (
    store_code      text        NOT NULL,
    merch_group_nr  integer     NOT NULL,
    label           text,
    bucket          text,
    product_code    bigint      NOT NULL,
    description     text,
    gp_91d          numeric,
    units_91d       numeric,
    rn              integer     NOT NULL,
    daily_rate      numeric     NOT NULL DEFAULT 0,
    CONSTRAINT l2_bt_heroes_pk PRIMARY KEY (store_code, merch_group_nr, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_bt_heroes_store
    ON public.l2_bt_heroes (store_code, merch_group_nr, rn);

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_heroes()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE v_today date := CURRENT_DATE;
BEGIN
    TRUNCATE public.l2_bt_heroes;
    INSERT INTO public.l2_bt_heroes
        (store_code, merch_group_nr, label, bucket, product_code,
         description, gp_91d, units_91d, rn, daily_rate)
    WITH trailing_91 AS (
        SELECT
            sc.store_code,
            sc.merch_group_nr,
            sc.label,
            sc.bucket,
            ss.product_code,
            MAX(sa.description)                                                AS description,
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
        COALESCE(r.daily_rate, 0) AS daily_rate
    FROM trailing_91 t
    LEFT JOIN rate_28d r
        ON  r.store_code   = t.store_code
        AND r.product_code = t.product_code
    WHERE t.rn <= 5;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_heroes() TO authenticated;


-- =============================================================================
-- 5. rpc_bt_availability() -- rewired to precomputed l2_bt_heroes
--    Supersedes definition in bt_005_heroes_availability.sql.
--    Reads precomputed daily_rate from l2_bt_heroes (60 rows).
--    Bounds l2_soh_daily to one snapshot date per store -- fast index lookup.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bt_availability();

CREATE OR REPLACE FUNCTION public.rpc_bt_availability()
RETURNS TABLE (
    store_code      text,
    merch_group_nr  integer,
    label           text,
    bucket          text,
    product_code    bigint,
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
    -- One row per store: the most recent snapshot date.
    -- Fast index-only scan on (store_code, snapshot_date).
    SELECT store_code, MAX(snapshot_date) AS snap_date
    FROM public.l2_soh_daily
    GROUP BY store_code
)
SELECT
    h.store_code,
    h.merch_group_nr,
    h.label,
    h.bucket,
    h.product_code,
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
-- 6. refresh_bt_precompute() -- orchestrates all four nightly refreshes
--    Called from refresh_l2_pipeline(). Each step guarded so one failure
--    does not abort the others.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_bt_precompute()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
    BEGIN
        PERFORM public.refresh_l2_bt_monthly();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'refresh_l2_bt_monthly failed: %', SQLERRM;
    END;

    BEGIN
        PERFORM public.refresh_l2_bt_buying_weekly();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'refresh_l2_bt_buying_weekly failed: %', SQLERRM;
    END;

    BEGIN
        PERFORM public.refresh_l2_bt_tail();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'refresh_l2_bt_tail failed: %', SQLERRM;
    END;

    BEGIN
        PERFORM public.refresh_l2_bt_heroes();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'refresh_l2_bt_heroes failed: %', SQLERRM;
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_bt_precompute() TO authenticated;


-- =============================================================================
-- 7. Initial populate -- seeds all four tables immediately.
--    Run once after applying this file. Nightly runs handled by pipeline.
-- =============================================================================

SELECT public.refresh_bt_precompute();
