-- =============================================================================
-- bt_005_heroes_availability.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 5 (Instrument 2)
-- bt_out_events table + l2_bt_heroes view + rpc_bt_availability()
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_004_buying.sql
-- R22: heroes match named lines in plan (Sunflower, Brown Sugar, Wabona,
--      Colgate Dental Cream, Dove White, Grandpa Powder, Softsoft 2ply)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Table: bt_out_events
-- Logs OUT-status events so repeat offenders surface over time.
-- rpc_bt_availability() writes here; ON CONFLICT DO NOTHING = idempotent.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bt_out_events (
    id              bigserial   NOT NULL,
    store_code      text        NOT NULL,
    product_code    bigint      NOT NULL,
    merch_group_nr  integer     NOT NULL,
    logged_date     date        NOT NULL DEFAULT CURRENT_DATE,
    soh             numeric,
    CONSTRAINT bt_out_events_pk PRIMARY KEY (id),
    CONSTRAINT bt_out_events_uq UNIQUE (store_code, product_code, logged_date)
);

CREATE INDEX IF NOT EXISTS idx_bt_out_store_prod
    ON public.bt_out_events (store_code, product_code, logged_date DESC);


-- ---------------------------------------------------------------------------
-- View: l2_bt_heroes
-- Top 5 by trailing-91-day GP per (store, merch_group).
-- Refreshed nightly via refresh_l2_pipeline (Pieter adds the REFRESH call there).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.l2_bt_heroes AS
WITH trailing_91 AS (
    SELECT
        sc.store_code,
        sc.merch_group_nr,
        sc.label,
        sc.bucket,
        ss.product_code,
        MAX(sa.description)                                             AS description,
        SUM(ss.sales_incl_vat - ss.vat_value - ss.cost_value)          AS gp_91d,
        SUM(ss.qty)                                                     AS units_91d,
        ROW_NUMBER() OVER (
            PARTITION BY sc.store_code, sc.merch_group_nr
            ORDER BY SUM(ss.sales_incl_vat - ss.vat_value
                         - ss.cost_value) DESC
        ) AS rn
    FROM public.l2_bt_scope sc
    JOIN public.sigma_sales ss ON ss.store_code = sc.store_code
    JOIN public.sigma_articles sa
        ON  sa.store_code     = ss.store_code
        AND sa.product_code   = ss.product_code
        AND sa.merch_group_nr = sc.merch_group_nr
    WHERE ss.period_kind = 'T'
      AND ss.txn_kind    = 1
      AND ss.sale_date  >= CURRENT_DATE - 91
    GROUP BY sc.store_code, sc.merch_group_nr, sc.label, sc.bucket,
             ss.product_code
)
SELECT store_code, merch_group_nr, label, bucket,
       product_code, description, gp_91d, units_91d, rn
FROM trailing_91
WHERE rn <= 5;


-- ---------------------------------------------------------------------------
-- RPC: rpc_bt_availability()
-- Per hero: SOH (latest l2_soh_daily), 28d daily rate, days_cover, status.
-- Pure read path -- OUT event logging moved to rpc_bt_log_out_events() below.
-- VOLATILE: mandated for all BT RPCs (SB-CC-BT-001).
-- SB-CC-BT-FIX-001: removed INSERT from read RPC (OUT param shadowed column).
-- ---------------------------------------------------------------------------
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
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
    v_today date := CURRENT_DATE;
BEGIN
    -- Return availability for all heroes
    RETURN QUERY
    WITH soh_current AS (
        SELECT DISTINCT ON (sd.store_code, sd.product_code)
            sd.store_code,
            sd.product_code,
            sd.soh
        FROM public.l2_soh_daily sd
        JOIN public.l2_bt_heroes h
            ON  h.store_code   = sd.store_code
            AND h.product_code = sd.product_code
        ORDER BY sd.store_code, sd.product_code, sd.snapshot_date DESC
    ),
    rate_28d AS (
        SELECT
            ss.store_code,
            ss.product_code,
            SUM(ss.qty) / 28.0  AS daily_rate
        FROM public.sigma_sales ss
        JOIN public.l2_bt_heroes h
            ON  h.store_code   = ss.store_code
            AND h.product_code = ss.product_code
        WHERE ss.period_kind = 'T'
          AND ss.txn_kind    = 1
          AND ss.sale_date  >= v_today - 28
        GROUP BY ss.store_code, ss.product_code
    )
    SELECT
        h.store_code,
        h.merch_group_nr,
        h.label,
        h.bucket,
        h.product_code,
        h.description,
        COALESCE(sc.soh, 0)                                             AS soh,
        COALESCE(r.daily_rate, 0)                                       AS daily_rate,
        CASE WHEN COALESCE(r.daily_rate, 0) > 0
             THEN COALESCE(sc.soh, 0) / r.daily_rate
             ELSE NULL END                                              AS days_cover,
        CASE
            WHEN COALESCE(sc.soh, 0) <= 0                              THEN 'OUT'
            WHEN COALESCE(sc.soh, 0)
                 / NULLIF(COALESCE(r.daily_rate, 0), 0) < 7            THEN 'SHORT'
            ELSE 'OK'
        END                                                             AS status
    FROM public.l2_bt_heroes h
    LEFT JOIN soh_current sc
        ON  sc.store_code   = h.store_code
        AND sc.product_code = h.product_code
    LEFT JOIN rate_28d r
        ON  r.store_code    = h.store_code
        AND r.product_code  = h.product_code
    ORDER BY h.store_code, h.merch_group_nr, h.rn;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_availability() TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- FUNCTION: rpc_bt_log_out_events()
-- Logs today's OUT-status heroes to bt_out_events.
-- Call from the nightly refresh job (refresh_l2_pipeline) instead of from
-- the read RPC -- keeps the read path clean (SB-CC-BT-FIX-001).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_bt_log_out_events()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
    v_today date := CURRENT_DATE;
BEGIN
    INSERT INTO public.bt_out_events
        (store_code, product_code, merch_group_nr, logged_date, soh)
    SELECT
        h.store_code,
        h.product_code,
        h.merch_group_nr,
        v_today,
        COALESCE(ls.soh, 0)
    FROM public.l2_bt_heroes h
    LEFT JOIN LATERAL (
        SELECT sd.soh
        FROM public.l2_soh_daily sd
        WHERE sd.store_code   = h.store_code
          AND sd.product_code = h.product_code
        ORDER BY sd.snapshot_date DESC
        LIMIT 1
    ) ls ON true
    WHERE COALESCE(ls.soh, 0) <= 0
    ON CONFLICT (store_code, product_code, logged_date) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_log_out_events() TO anon, authenticated;
