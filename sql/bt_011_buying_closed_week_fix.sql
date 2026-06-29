-- =============================================================================
-- bt_011_buying_closed_week_fix.sql
-- SB-CC-BT-005 v1.1 -- two fixes on the buying gauge
--
-- FIX 1: Closed-week definition.
--   A week is only closed once its Sunday data has been fully extracted and
--   ingested.  Store extractors run overnight, so Sunday's sales are not in
--   Supabase until Monday night.  The BT-005 formula used
--     v_latest_sunday := DATE_TRUNC('week', CURRENT_DATE)::date - 1
--   which on Monday 29 Jun returns Sunday 28 Jun -- a day whose data has not
--   yet arrived.  Correct formula:
--     v_latest_sunday := DATE_TRUNC('week', CURRENT_DATE)::date - 8
--   This moves the cutoff back one full week so the gauge always reads off
--   confirmed data.  On Monday 29 Jun this gives Sunday 21 Jun.
--
-- FIX 2: Y-axis -- handled in bt.html JS (buildTrend auto-fit).
--         No SQL change needed for that fix.
--
-- ON PIETER: run in Supabase SQL editor.
--   The SELECT at the bottom re-seeds l2_bt_buying_weekly immediately.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.refresh_l2_bt_buying_weekly()
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    -- Latest Sunday whose data is confirmed in Supabase.
    -- Store extractors run Sunday night -> data arrives Monday night.
    -- Subtracting 8 (not 1) from this Monday's date skips the most recent
    -- Sunday (data still in transit) and lands on the prior confirmed Sunday.
    v_latest_sunday date :=
        (DATE_TRUNC('week', CURRENT_DATE)::date) - 8;
    v_from_sunday   date;
    v_scan_from     date;
BEGIN
    v_from_sunday := v_latest_sunday - 84;   -- 13 Sundays = 12 x 7 = 84 days
    v_scan_from   := v_from_sunday - 6;      -- Monday of the oldest week

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
          AND ss.sale_date  <= v_latest_sunday
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
          AND sm.movement_date   <= v_latest_sunday
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
    WHERE COALESCE(ws.week_ending, wp.week_ending) >= v_from_sunday
      AND COALESCE(ws.week_ending, wp.week_ending) <= v_latest_sunday;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_l2_bt_buying_weekly() TO authenticated;


-- Re-seed immediately so the card reflects the fix without waiting for tonight.
SELECT public.refresh_l2_bt_buying_weekly();
