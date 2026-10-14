-- =============================================================================
-- eng170_bt_provenance_columns.sql   (migrations eng170_bt_provenance_columns, then
--                                     eng170_bt_provenance_columns_l2_bt_tail)
-- ENG-170 (dashboard lane, PM ruling 14-10-2026 09:0x): the four Bonnie Tyler precompute tables carry no provenance.
-- refresh_bt_precompute() is the 12th leg of refresh_l2_pipeline (pg_cron job 15, 20:15 UTC) and swallows each leg's
-- error as a warning, and the whole chain is one transaction, so a failed night leaves the page a day old with nothing
-- on the rows to say so. computed_at and engine_version let any reader (and the page, later) say when a row was written.
--
-- HOW: ADD the column nullable first, then SET DEFAULT afterwards. ADD COLUMN ... DEFAULT now() would stamp every
-- existing row as fresh, which is exactly the lie this row exists to remove; old rows stay NULL = "written before the
-- column existed". Each refresh function TRUNCATEs and re-INSERTs with an EXPLICIT column list (checked 14-10-2026),
-- so the next nightly run stamps every row through the defaults with no change to the functions.
-- Applied: three tables 14-10-2026 about 10:1x; l2_bt_tail 11:4x (the Bloom cache job held an AccessShareLock on it
-- until then; SET LOCAL lock_timeout = 5s on both). Idempotent.
-- READ-BACK OWED: after the 20:15 UTC (22:15 SAST) run, every row of the four tables has computed_at not null.
-- Rollback: ALTER TABLE public.<t> DROP COLUMN computed_at, DROP COLUMN engine_version;  (nothing reads them yet)
-- =============================================================================
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.l2_bt_monthly       ADD COLUMN IF NOT EXISTS computed_at timestamptz;
ALTER TABLE public.l2_bt_monthly       ADD COLUMN IF NOT EXISTS engine_version text;
ALTER TABLE public.l2_bt_buying_weekly ADD COLUMN IF NOT EXISTS computed_at timestamptz;
ALTER TABLE public.l2_bt_buying_weekly ADD COLUMN IF NOT EXISTS engine_version text;
ALTER TABLE public.l2_bt_heroes        ADD COLUMN IF NOT EXISTS computed_at timestamptz;
ALTER TABLE public.l2_bt_heroes        ADD COLUMN IF NOT EXISTS engine_version text;
ALTER TABLE public.l2_bt_tail          ADD COLUMN IF NOT EXISTS computed_at timestamptz;
ALTER TABLE public.l2_bt_tail          ADD COLUMN IF NOT EXISTS engine_version text;

ALTER TABLE public.l2_bt_monthly       ALTER COLUMN computed_at SET DEFAULT now();
ALTER TABLE public.l2_bt_monthly       ALTER COLUMN engine_version SET DEFAULT 'BT-PRECOMPUTE-v1';
ALTER TABLE public.l2_bt_buying_weekly ALTER COLUMN computed_at SET DEFAULT now();
ALTER TABLE public.l2_bt_buying_weekly ALTER COLUMN engine_version SET DEFAULT 'BT-PRECOMPUTE-v1';
ALTER TABLE public.l2_bt_heroes        ALTER COLUMN computed_at SET DEFAULT now();
ALTER TABLE public.l2_bt_heroes        ALTER COLUMN engine_version SET DEFAULT 'BT-PRECOMPUTE-v1';
ALTER TABLE public.l2_bt_tail          ALTER COLUMN computed_at SET DEFAULT now();
ALTER TABLE public.l2_bt_tail          ALTER COLUMN engine_version SET DEFAULT 'BT-PRECOMPUTE-v1';

COMMENT ON COLUMN public.l2_bt_tail.computed_at IS 'ENG-170 (dashboard lane, 14-10-2026): when this row was written by refresh_bt_precompute(); NULL = written before the column existed.';
COMMENT ON COLUMN public.l2_bt_tail.engine_version IS 'ENG-170 (dashboard lane, 14-10-2026): the precompute version that wrote the row; NULL = written before the column existed.';
