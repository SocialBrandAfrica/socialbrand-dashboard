-- =============================================================================
-- bt_003_monthly_scorecard.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 3 (Instrument 1)
-- l2_bt_monthly view + rpc_bt_scorecard(p_month text)
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_002_baseline.sql
-- R22: rpc_bt_scorecard('2026-05') basket GP = R76,515 within rounding
-- =============================================================================

-- ---------------------------------------------------------------------------
-- View: l2_bt_monthly
-- Live monthly totals per (store, merch_group) from 2025-02 onward.
-- Only scoped pairs via l2_bt_scope join.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.l2_bt_monthly AS
SELECT
    sc.store_code,
    sc.merch_group_nr,
    sc.label,
    sc.bucket,
    DATE_TRUNC('month', ss.sale_date)::date                             AS month_start,
    SUM(ss.sales_incl_vat - ss.vat_value)                              AS sales_ex,
    SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value)              AS gp,
    CASE WHEN SUM(ss.sales_incl_vat - ss.vat_value) > 0
         THEN SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value)
              / SUM(ss.sales_incl_vat - ss.vat_value) * 100
         ELSE 0 END                                                     AS gp_pct,
    SUM(ss.qty)                                                         AS units
FROM public.l2_bt_scope sc
JOIN public.sigma_sales ss ON ss.store_code = sc.store_code
JOIN public.sigma_articles sa
    ON  sa.store_code      = ss.store_code
    AND sa.product_code    = ss.product_code
    AND sa.merch_group_nr  = sc.merch_group_nr
WHERE ss.period_kind = 'T'
  AND ss.txn_kind    = 1
  AND ss.sale_date  >= '2025-02-01'
GROUP BY sc.store_code, sc.merch_group_nr, sc.label, sc.bucket,
         DATE_TRUNC('month', ss.sale_date);


-- ---------------------------------------------------------------------------
-- RPC: rpc_bt_scorecard(p_month text)
-- p_month = 'YYYY-MM', e.g. '2026-05'
-- Returns per-sub-dept detail rows, per-bucket subtotal rows, and basket total.
-- target_gp is NULL until l2_bt_target is created and populated.
-- VOLATILE: mandated for all BT RPCs (SB-CC-BT-001 + SB-CC-DASH-VOLATILE-001).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_bt_scorecard(text);

CREATE OR REPLACE FUNCTION public.rpc_bt_scorecard(p_month text)
RETURNS TABLE (
    store_code      text,
    merch_group_nr  integer,
    label           text,
    bucket          text,
    row_type        text,
    sales_ex        numeric,
    gp              numeric,
    gp_pct          numeric,
    units           numeric,
    baseline_gp     numeric,
    delta_gp_rand   numeric,
    delta_gp_pct    numeric,
    target_gp       numeric
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $$
WITH current_month AS (
    SELECT
        m.store_code,
        m.merch_group_nr,
        m.label,
        m.bucket,
        m.sales_ex,
        m.gp,
        m.gp_pct,
        m.units
    FROM public.l2_bt_monthly m
    WHERE m.month_start = (p_month || '-01')::date
),
with_baseline AS (
    SELECT
        cm.store_code,
        cm.merch_group_nr,
        cm.label,
        cm.bucket,
        cm.sales_ex,
        cm.gp,
        cm.gp_pct,
        cm.units,
        COALESCE(bl.gp, 0)                              AS baseline_gp,
        cm.gp - COALESCE(bl.gp, 0)                     AS delta_gp_rand,
        CASE WHEN COALESCE(bl.gp, 0) <> 0
             THEN (cm.gp - bl.gp) / ABS(bl.gp) * 100
             ELSE NULL END                              AS delta_gp_pct,
        NULL::numeric                                   AS target_gp
    FROM current_month cm
    LEFT JOIN public.l2_bt_baseline bl
        ON  bl.store_code     = cm.store_code
        AND bl.merch_group_nr = cm.merch_group_nr
),
detail_rows AS (
    SELECT
        store_code, merch_group_nr, label, bucket,
        'DETAIL'::text AS row_type,
        sales_ex, gp, gp_pct, units,
        baseline_gp, delta_gp_rand, delta_gp_pct, target_gp,
        1 AS sort_order
    FROM with_baseline
),
bucket_rows AS (
    SELECT
        MIN(store_code)     AS store_code,
        NULL::integer       AS merch_group_nr,
        bucket              AS label,
        bucket,
        'BUCKET'::text      AS row_type,
        SUM(sales_ex)       AS sales_ex,
        SUM(gp)             AS gp,
        CASE WHEN SUM(sales_ex) > 0
             THEN SUM(gp) / SUM(sales_ex) * 100
             ELSE 0 END     AS gp_pct,
        SUM(units)          AS units,
        SUM(baseline_gp)    AS baseline_gp,
        SUM(delta_gp_rand)  AS delta_gp_rand,
        NULL::numeric       AS delta_gp_pct,
        NULL::numeric       AS target_gp,
        2 AS sort_order
    FROM with_baseline
    GROUP BY bucket
),
basket_row AS (
    SELECT
        NULL::text      AS store_code,
        NULL::integer   AS merch_group_nr,
        'BASKET TOTAL'  AS label,
        NULL::text      AS bucket,
        'TOTAL'::text   AS row_type,
        SUM(sales_ex)       AS sales_ex,
        SUM(gp)             AS gp,
        CASE WHEN SUM(sales_ex) > 0
             THEN SUM(gp) / SUM(sales_ex) * 100
             ELSE 0 END     AS gp_pct,
        SUM(units)          AS units,
        SUM(baseline_gp)    AS baseline_gp,
        SUM(delta_gp_rand)  AS delta_gp_rand,
        NULL::numeric       AS delta_gp_pct,
        NULL::numeric       AS target_gp,
        3 AS sort_order
    FROM with_baseline
)
SELECT store_code, merch_group_nr, label, bucket, row_type,
       sales_ex, gp, gp_pct, units,
       baseline_gp, delta_gp_rand, delta_gp_pct, target_gp
FROM (
    SELECT * FROM detail_rows
    UNION ALL
    SELECT * FROM bucket_rows
    UNION ALL
    SELECT * FROM basket_row
) u
ORDER BY sort_order, bucket NULLS LAST, label;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_scorecard(text) TO anon, authenticated;
