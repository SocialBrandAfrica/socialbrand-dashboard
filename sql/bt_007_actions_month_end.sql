-- =============================================================================
-- bt_007_actions_month_end.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 7 (Instrument 5)
-- bt_actions table + rpc_bt_month_end(p_month text)
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run after bt_006_tail_prune.sql
-- R22: basket GP and per-bucket deltas match Instrument 1 for the same month
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Table: bt_actions
-- Manual log of DC deals, gap-line trials, markdowns.
-- Each row is a traceable SKU-level savings claim for the month-end export.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bt_actions (
    id              bigserial       NOT NULL,
    logged_at       date            NOT NULL DEFAULT CURRENT_DATE,
    store_code      text            NOT NULL,
    merch_group_nr  integer,
    product_code    bigint,
    sku_description text,
    action_type     text            NOT NULL,
    saving_rand     numeric(14,4),
    notes           text,
    CONSTRAINT bt_actions_pk PRIMARY KEY (id)
);


-- ---------------------------------------------------------------------------
-- RPC: rpc_bt_month_end(p_month text)
-- Assembles instruments 1-4 + bt_actions into one JSONB payload.
-- Designed for the one-page export; CD will render from this.
-- VOLATILE: plpgsql with side-effect calls to other VOLATILE RPCs.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_bt_month_end(text);

CREATE OR REPLACE FUNCTION public.rpc_bt_month_end(p_month text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
    v_month_start date := (p_month || '-01')::date;
    v_month_end   date := (DATE_TRUNC('month', v_month_start)
                           + interval '1 month - 1 day')::date;
    v_result      jsonb;
BEGIN
    SELECT jsonb_build_object(
        'month',      p_month,
        'scorecard',  (
            SELECT jsonb_agg(row_to_json(s))
            FROM public.rpc_bt_scorecard(p_month) s
        ),
        'buying', jsonb_build_object(
            'delareyville', (
                SELECT jsonb_agg(row_to_json(b))
                FROM public.rpc_bt_buying('10116', v_month_start, v_month_end) b
            ),
            'roosville', (
                SELECT jsonb_agg(row_to_json(b))
                FROM public.rpc_bt_buying('80175', v_month_start, v_month_end) b
            )
        ),
        'tail_totals', (
            SELECT jsonb_build_object(
                'dead_91d_count',  COUNT(*)     FILTER (WHERE flag = 'DEAD_91D'),
                'vslow_91d_count', COUNT(*)     FILTER (WHERE flag = 'VSLOW_91D'),
                'dead_91d_cash',   SUM(soh_cash) FILTER (WHERE flag = 'DEAD_91D'),
                'total_tail_cash', SUM(soh_cash)
            )
            FROM public.l2_bt_tail
            WHERE flag IS NOT NULL
        ),
        'actions', (
            SELECT jsonb_agg(row_to_json(a))
            FROM public.bt_actions a
            WHERE DATE_TRUNC('month', a.logged_at::timestamp) = v_month_start::timestamp
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bt_month_end(text) TO anon, authenticated;
