-- =============================================================================
-- bt_006_tail_prune.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 6 (Instrument 3)
-- l2_bt_tail view + rpc_bt_prune_list()
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_005_heroes_availability.sql
-- R22: total DEAD_91D across the 12 = 271 at baseline;
--      Cereals 36, Skincare 47, Baby Food Dly 42
-- =============================================================================

-- ---------------------------------------------------------------------------
-- View: l2_bt_tail
-- Per (store, merch_group, product): units sold in last 91d and 365d,
-- flag DEAD_91D (sold in 365d but zero in 91d) or VSLOW_91D (1-2 units in 91d),
-- last_sale_date, SOH (latest l2_soh_daily), soh_cash at last-known unit cost.
-- Only rows with units_365 > 0 and units_91 <= 2 to keep view lean.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.l2_bt_tail AS
WITH scoped_sales AS (
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
        sd.store_code,
        sd.product_code,
        sd.soh
    FROM public.l2_soh_daily sd
    ORDER BY sd.store_code, sd.product_code, sd.snapshot_date DESC
),
last_cost AS (
    -- Last unit cost from a goods-receipt movement
    SELECT DISTINCT ON (sm.store_code, sm.product_code)
        sm.store_code,
        sm.product_code,
        CASE WHEN ABS(sm.qty) > 0
             THEN ABS(sm.cost_value) / ABS(sm.qty)
             ELSE NULL END AS unit_cost
    FROM public.sigma_movements sm
    WHERE sm.movement_type = 'R'
      AND sm.cost_value  IS NOT NULL
      AND sm.qty         IS NOT NULL
      AND sm.qty          <> 0
    ORDER BY sm.store_code, sm.product_code, sm.movement_date DESC
)
SELECT
    ss.store_code,
    ss.merch_group_nr,
    ss.label,
    ss.bucket,
    ss.product_code,
    ss.description,
    ss.units_91,
    ss.units_365,
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


-- ---------------------------------------------------------------------------
-- RPC: rpc_bt_prune_list()
-- Actionable list of DEAD_91D and VSLOW_91D lines, sorted by soh_cash desc
-- so lines holding the most capital are actioned first.
-- VOLATILE: mandated for all BT RPCs (SB-CC-BT-001).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_bt_prune_list();

CREATE OR REPLACE FUNCTION public.rpc_bt_prune_list()
RETURNS TABLE (
    store_code      text,
    merch_group_nr  integer,
    label           text,
    bucket          text,
    product_code    bigint,
    description     text,
    flag            text,
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
    product_code,
    description,
    flag,
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
ORDER BY soh_cash DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_prune_list() TO anon, authenticated;
