-- =============================================================================
-- create_store_extract_config.sql
-- SB-CC-EXTRACT-002 -- declarative per-store extract timing (config, not code).
-- =============================================================================
-- One row per store. The extractor reads its own row at startup and decides WHEN
-- to pull from these declarative facts -- it carries no clock time and no store
-- name in code (R25 config-only store template, R26 main road). A new customer is
-- onboarded by INSERTing rows here, with zero runner change.
--
-- FIELDS (all declarative, no logic):
--   time_zone          IANA tz the store's clock runs on (windows judged in it).
--   trading_close      local time the store stops trading.
--   eod_window_start   local time the runner may START polling for readiness
--                      (pre-EOD: before close so a clean pull lands even if the
--                      later EOD lock holds). The scheduled task fires at this.
--   eod_window_end     local time by which a normal EOD is expected complete.
--   ready_poll_minutes how often to re-check readiness while waiting on the lock.
--   hard_cutoff        local time to STOP retrying for the night and raise a loud
--                      fail if a traded day has not landed (v1 = 23:30, clears the
--                      ~20:00-22:00 dw220sdb EOD lock with room).
--
-- Readiness itself is judged from authentic server state at poll time (EOD done +
-- dw220sdb reachable), never from a guess (R25). These are only the WINDOW bounds.
--
-- Rule 19: DROP + clean CREATE. anon/authenticated SELECT (extractor reads via
-- service_role; dashboard governance line reads via anon).
-- =============================================================================

DROP TABLE IF EXISTS public.store_extract_config CASCADE;

CREATE TABLE public.store_extract_config (
    client_id          text NOT NULL DEFAULT 'socialbrand',
    store_code         text NOT NULL,
    time_zone          text NOT NULL DEFAULT 'Africa/Johannesburg',
    trading_close      time NOT NULL,
    eod_window_start   time NOT NULL,
    eod_window_end     time NOT NULL,
    ready_poll_minutes int  NOT NULL DEFAULT 10,
    hard_cutoff        time NOT NULL DEFAULT '23:30',
    is_active          boolean NOT NULL DEFAULT true,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT store_extract_config_pk PRIMARY KEY (client_id, store_code)
);

GRANT SELECT ON public.store_extract_config TO anon, authenticated;

-- Seed the 5 DFM stores. Identical declarative defaults today (all close 19:00,
-- pre-EOD poll from 18:40, hard cutoff 23:30) -- per-store tunable without code.
-- A store with different hours is just a different row; the runner is unchanged.
INSERT INTO public.store_extract_config
    (store_code, time_zone, trading_close, eod_window_start, eod_window_end, ready_poll_minutes, hard_cutoff)
VALUES
    ('10116', 'Africa/Johannesburg', '19:00', '18:40', '22:00', 10, '23:30'),
    ('21355', 'Africa/Johannesburg', '19:00', '18:40', '22:00', 10, '23:30'),
    ('80175', 'Africa/Johannesburg', '19:00', '18:40', '22:00', 10, '23:30'),
    ('80176', 'Africa/Johannesburg', '19:00', '18:40', '22:00', 10, '23:30'),
    ('80579', 'Africa/Johannesburg', '19:00', '18:40', '22:00', 10, '23:30')
ON CONFLICT (client_id, store_code) DO UPDATE SET
    time_zone          = EXCLUDED.time_zone,
    trading_close      = EXCLUDED.trading_close,
    eod_window_start   = EXCLUDED.eod_window_start,
    eod_window_end     = EXCLUDED.eod_window_end,
    ready_poll_minutes = EXCLUDED.ready_poll_minutes,
    hard_cutoff        = EXCLUDED.hard_cutoff,
    is_active          = true,
    updated_at         = now();
