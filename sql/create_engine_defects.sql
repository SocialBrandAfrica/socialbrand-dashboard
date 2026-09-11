-- create_engine_defects.sql
--
-- public.engine_defects -- THE DEFECT REGISTER'S DATABASE MIRROR. BUG-LOG.md is SOVEREIGN
-- for a defect id (FILE-GOVERNANCE 0d v2.23). This table mirrors it and decides nothing.
-- PM created and hand-loaded it on 2026-08-31 (118 rows). No create file followed, so a
-- rebuild from this repo did not produce it: the ENG-175 half (a) class, a further instance.
--
-- CHANGED 2026-09-11 (CC, migration engine_defects_loader, 20260911070054), on Pieter's
-- word ("The database copy of the defect list is missing the 14 defects the defect book
-- now shows"):
--   1. status_check gains UNSTAMPED, the state the defect book reports for a section-born
--      defect with no token (ENG-172 at the time). The table holds it rather than
--      guessing a status.
--   2. source_md5 is new: the md5 of the BUG-LOG.md each row was loaded from.
--   3. The COMMENT states the loader and the staleness test. The 2026-08-31 text
--      ("DATED SNAPSHOT, NOT A LIVE MIRROR ... OWED: a loader that refreshes this table
--      from the token, or this table is dropped") is retired_on 2026-09-11 (R28).
--
-- LOADER: Engine/register/engine_defects_load.py in the Daisy tree. It parses BUG-LOG.md
-- with defects_book.parse, the parser that renders SB-REF-DEFECTS.md, and writes one
-- full-refresh transaction with a count assertion (Engine/register/engine_defects_load.sql).
-- ROWS ARE NOT CARRIED HERE: BUG-LOG.md is the source and the loader is the only writer.
--
-- STALENESS TEST: md5 of BUG-LOG.md against SELECT DISTINCT source_md5 FROM engine_defects.
--
-- READERS, verified at source 2026-09-11: NO function, view or cron job in public
-- references this table.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog on 2026-09-11 (pg_attribute,
-- pg_attrdef, pg_constraint, relacl, obj_description) and gated against live before
-- commit. It is idempotent: re-applying it leaves the live table as it is.
--
-- ACCESS, live: RLS ENABLED with ZERO policies, so authenticated holds SELECT and reads
-- ZERO rows through PostgREST (the ENG-068 shape). anon holds nothing. The `m`
-- (MAINTAIN) privilege on authenticated comes from the platform's default privileges and
-- is reproduced, not granted, here. Live ACL at capture:
--   {postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}

CREATE TABLE IF NOT EXISTS public.engine_defects (
  defect_id    text        NOT NULL,
  occurrence   smallint    NOT NULL DEFAULT 1,
  found_date   date,
  fixed_date   date,
  severity     text,
  status       text        NOT NULL,
  contested    boolean     NOT NULL DEFAULT false,
  status_head  text,
  section      text,
  source_file  text        NOT NULL DEFAULT 'BUG-LOG.md'::text,
  loaded_at    timestamptz NOT NULL DEFAULT now(),
  source_md5   text,
  CONSTRAINT engine_defects_pkey PRIMARY KEY (defect_id, occurrence),
  CONSTRAINT engine_defects_status_check CHECK (status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text, 'CLOSED'::text, 'UNSTAMPED'::text]))
);

-- A database built before 2026-09-11 carries the three-value check and no source_md5.
ALTER TABLE public.engine_defects ADD COLUMN IF NOT EXISTS source_md5 text;
ALTER TABLE public.engine_defects DROP CONSTRAINT IF EXISTS engine_defects_status_check;
ALTER TABLE public.engine_defects ADD CONSTRAINT engine_defects_status_check
  CHECK (status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text, 'CLOSED'::text, 'UNSTAMPED'::text]));

COMMENT ON TABLE public.engine_defects IS $c$GRADE: VERDICT. A MIRROR of BUG-LOG.md, refreshed by a loader and never hand-edited. BUG-LOG.md is SOVEREIGN for a defect id (FILE-GOVERNANCE 0d v2.23) and this table decides nothing. LOADER: Engine/register/engine_defects_load.py in the Daisy tree reads BUG-LOG.md with defects_book.parse, the same parser that renders SB-REF-DEFECTS.md, and writes one full-refresh transaction with a row-count assertion (Engine/register/engine_defects_load.sql). STALENESS TEST: md5 of BUG-LOG.md against SELECT DISTINCT source_md5 FROM engine_defects. A different hash means BUG-LOG moved after the last load. status is the token that opens the row: OPEN, PARTIAL or CLOSED, and UNSTAMPED where a section-born defect carries no token, which is a register defect reported as found and never guessed. The refresh is a seat step, not a schedule, because the database cannot read the file: CC runs it whenever BUG-LOG moves and at every handover. R28: the 2026-08-31 comment (DATED SNAPSHOT, NOT A LIVE MIRROR, no refresh mechanism) is retired_on 2026-09-11, superseded_by this comment and the loader.$c$;
COMMENT ON COLUMN public.engine_defects.source_md5 IS $c$md5 of the BUG-LOG.md this row was loaded from. One value per load. Compare it with the file to know whether the table is current.$c$;
COMMENT ON COLUMN public.engine_defects.contested IS $c$The 2026-08-31 seeding flag: the status token was set by a PM ruling against the row's own text or Fixed date. Carried forward by (defect_id, occurrence) on every load and never set by the loader. A row born after 2026-08-31 reads false.$c$;
COMMENT ON COLUMN public.engine_defects.status IS $c$The status token that opens the BUG-LOG row: OPEN, PARTIAL or CLOSED. UNSTAMPED is a section-born defect with no token, a register defect for the row's owner to stamp.$c$;

ALTER TABLE public.engine_defects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.engine_defects FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.engine_defects FROM authenticated;
GRANT SELECT ON public.engine_defects TO authenticated;
