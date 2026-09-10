-- create_forge_integrity_history.sql
--
-- public.forge_integrity_history -- the nightly snapshot of the Forge integrity
-- instruments, the history behind the week-on-week Progress view (canon §15 addendum,
-- 2026-07-10). Created live 2026-07-10 (migration forge_integrity_history_and_trend,
-- 20260710123437) and backfilled to 2026-07-01. No create file followed, so a rebuild
-- from this repo did not produce it. That is BUG-LOG ENG-175 half (a), and this file
-- closes it.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog on 2026-09-10
-- (pg_attribute, pg_attrdef, pg_constraint, pg_index, pg_policy, relacl,
-- obj_description). Before commit it was gated against live: the same DDL built into
-- pg_temp returned identical column, constraint and index signatures, and the COMMENT
-- body below hashes to the live comment. Re-applying this file to the live database
-- is a no-op.
--
-- ROWS ARE NOT CARRIED: this is history the writer appends nightly, never seed data.
-- Live at capture: 2,732 rows, 516,096 bytes.
--
-- WRITER: snapshot_forge_integrity(), pg_cron job 24 `forge-integrity-snapshot`,
--   30 21 * * * UTC = 23:30 SAST.
-- READERS: rpc_forge_integrity_trend and rpc_forge_integrity_history
--   (sql/eng178_rpc_forge_integrity_history.sql). Verified at source on 2026-09-10.
--
-- ACCESS, live: RLS ENABLED with ZERO policies, so anon and authenticated read ZERO
-- rows directly although their grant reads SELECT. That is BUG-LOG ENG-163: a pack that
-- read this table with the publishable key reported "history max 08-11" while the data
-- ran to date. Read it through the two SECURITY DEFINER readers above, never directly.
-- The `m` (MAINTAIN) privilege on anon and authenticated comes from the platform's
-- default privileges and is reproduced, not granted, here. Live ACL at capture:
--   {postgres=arwdDxtm/postgres,anon=rm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}

CREATE TABLE IF NOT EXISTS public.forge_integrity_history (
  store_code   text        NOT NULL,
  as_of_date   date        NOT NULL,
  instrument   text        NOT NULL,
  value_num    numeric,
  pool_num     numeric,
  captured_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT forge_integrity_history_pkey PRIMARY KEY (store_code, as_of_date, instrument)
);

COMMENT ON TABLE public.forge_integrity_history IS $c$GRADE: CALCULATED. Nightly snapshot of the Forge integrity instrument values.$c$;

ALTER TABLE public.forge_integrity_history ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.forge_integrity_history FROM anon, authenticated;
GRANT SELECT ON public.forge_integrity_history TO anon, authenticated;
