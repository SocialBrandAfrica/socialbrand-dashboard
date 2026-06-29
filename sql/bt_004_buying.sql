-- =============================================================================
-- bt_004_buying.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 4 (Instrument 4)
-- l2_bt_buying_weekly view + rpc_bt_buying(p_store, p_from, p_to)
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_003_monthly_scorecard.sql
-- R22: Apr 10116 month ratio 105.8%, build R1,354,833; May 80175 ratio 98.5%
-- =============================================================================

-- ---------------------------------------------------------------------------
-- View: l2_bt_buying_weekly
-- Per store per ISO week: sales_ex, cogs, purchases (movement_type='R'),
-- build = purchases - cogs, purchase_ratio = purchases / sales_ex * 100.
-- Scope: l2_bt_scope stores only (10116 + 80175).
-- FULL OUTER ensures weeks with only purchases or only sales still appear.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.l2_bt_buying_weekly AS
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
        DATE_TRUNC('week', sm.movement_date)::date  AS week_start,
        SUM(sm.cost_value)                           AS purchases
    FROM public.sigma_movements sm
    JOIN scoped_stores sc ON sc.store_code = sm.store_code
    WHERE sm.movement_type    = 'R'
      AND sm.movement_date IS NOT NULL
    GROUP BY sm.store_code, DATE_TRUNC('week', sm.movement_date)
)
SELECT
    COALESCE(ws.store_code, wp.store_code)          AS store_code,
    COALESCE(ws.week_start, wp.week_start)          AS week_start,
    COALESCE(ws.sales_ex, 0)                        AS sales_ex,
    COALESCE(ws.cogs, 0)                            AS cogs,
    COALESCE(wp.purchases, 0)                       AS purchases,
    COALESCE(wp.purchases, 0) - COALESCE(ws.cogs, 0) AS build,
    CASE WHEN COALESCE(ws.sales_ex, 0) > 0
         THEN COALESCE(wp.purchases, 0) / ws.sales_ex * 100
         ELSE NULL END                              AS purchase_ratio
FROM weekly_sales ws
FULL OUTER JOIN weekly_purchases wp
    ON  wp.store_code  = ws.store_code
    AND wp.week_start  = ws.week_start;


-- ---------------------------------------------------------------------------
-- RPC: rpc_bt_buying(p_store text, p_from date, p_to date)
-- Returns weekly series for one store with status:
--   HIGH = single week ratio > 95
--   OVER = ratio > 88 for this week AND the prior week (two running)
--   OK   = otherwise
-- VOLATILE: mandated for all BT RPCs (SB-CC-BT-001).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_bt_buying(text, date, date);

CREATE OR REPLACE FUNCTION public.rpc_bt_buying(
    p_store text,
    p_from  date,
    p_to    date
)
RETURNS TABLE (
    store_code      text,
    week_start      date,
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
        bw.week_start,
        bw.sales_ex,
        bw.cogs,
        bw.purchases,
        bw.build,
        bw.purchase_ratio,
        LAG(bw.purchase_ratio) OVER (
            PARTITION BY bw.store_code ORDER BY bw.week_start
        ) AS prev_ratio
    FROM public.l2_bt_buying_weekly bw
    WHERE bw.store_code  = p_store
      AND bw.week_start >= p_from
      AND bw.week_start <= p_to
)
SELECT
    store_code,
    week_start,
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
ORDER BY week_start;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_buying(text, date, date) TO anon, authenticated;
