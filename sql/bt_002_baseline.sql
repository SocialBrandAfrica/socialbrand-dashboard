-- =============================================================================
-- bt_002_baseline.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 2
-- l2_bt_baseline: frozen monthly average (Mar-May 2026) per (store, merch_group)
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_001_scope.sql
-- R22: basket GP for May 2026 = R76,515 within rounding (3-month avg checked)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_bt_baseline (
    store_code      text            NOT NULL,
    merch_group_nr  integer         NOT NULL,
    sales_ex        numeric(14,4)   NOT NULL,
    gp              numeric(14,4)   NOT NULL,
    gp_pct          numeric(8,4)    NOT NULL,
    units           numeric(14,4)   NOT NULL,
    window_from     date            NOT NULL DEFAULT '2026-03-01',
    window_to       date            NOT NULL DEFAULT '2026-05-31',
    months_in_avg   smallint        NOT NULL DEFAULT 3,
    written_at      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT l2_bt_baseline_pk PRIMARY KEY (store_code, merch_group_nr)
);

-- Populate or refresh: monthly average over the locked 3-month baseline window.
-- One row per month is summed, then averaged across the 3 months.
-- Sales source: sigma_sales period_kind='T' AND txn_kind=1 (DBUMBA ledger, R25).
-- GP = sales_incl_vat - vat_value - cost_value (ex-VAT, R2).
-- Scope restricted via l2_bt_scope join -- no hard-coded merch_group list (brief).

INSERT INTO public.l2_bt_baseline (store_code, merch_group_nr, sales_ex, gp, gp_pct, units)
SELECT
    sc.store_code,
    sc.merch_group_nr,
    AVG(mo.sales_ex)    AS sales_ex,
    AVG(mo.gp)          AS gp,
    CASE WHEN AVG(mo.sales_ex) > 0
         THEN AVG(mo.gp) / AVG(mo.sales_ex) * 100
         ELSE 0 END     AS gp_pct,
    AVG(mo.units)       AS units
FROM public.l2_bt_scope sc
JOIN (
    SELECT
        ss.store_code,
        sa.merch_group_nr,
        DATE_TRUNC('month', ss.sale_date)::date         AS month_start,
        SUM(ss.sales_incl_vat - ss.vat_value)           AS sales_ex,
        SUM(ss.sales_incl_vat - ss.vat_value
            - ss.cost_value)                            AS gp,
        SUM(ss.qty)                                     AS units
    FROM public.sigma_sales ss
    JOIN public.sigma_articles sa
        ON  sa.store_code    = ss.store_code
        AND sa.product_code  = ss.product_code
    WHERE ss.period_kind = 'T'
      AND ss.txn_kind    = 1
      AND ss.sale_date  >= '2026-03-01'
      AND ss.sale_date  <= '2026-05-31'
    GROUP BY ss.store_code, sa.merch_group_nr,
             DATE_TRUNC('month', ss.sale_date)
) mo ON mo.store_code = sc.store_code AND mo.merch_group_nr = sc.merch_group_nr
GROUP BY sc.store_code, sc.merch_group_nr
ON CONFLICT (store_code, merch_group_nr) DO UPDATE SET
    sales_ex   = EXCLUDED.sales_ex,
    gp         = EXCLUDED.gp,
    gp_pct     = EXCLUDED.gp_pct,
    units      = EXCLUDED.units,
    written_at = now();
