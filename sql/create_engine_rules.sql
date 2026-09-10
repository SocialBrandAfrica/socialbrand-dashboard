-- create_engine_rules.sql
--
-- public.engine_rules -- THE RULE REGISTRY. RULE-BOOK R28 §4 named it on 2026-06-17.
-- PM built and seeded it live on 2026-08-30 (migration create_engine_rules_registry,
-- 20260830165013). No create file followed, so a rebuild from this repo did not
-- produce it. That is BUG-LOG ENG-175 half (a), and this file closes it.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog on 2026-09-10
-- (pg_attribute, pg_attrdef, pg_constraint, pg_index, pg_policy, relacl,
-- obj_description). Before commit it was gated against live: the same DDL built into
-- pg_temp returned identical column, constraint and index signatures, and the COMMENT
-- body below hashes to the live comment. Re-applying this file to the live database
-- is a no-op.
--
-- ROWS ARE NOT CARRIED, on purpose. A rule's STATE is sovereign in this live table
-- (SQL-CONVENTIONS, "three homes, one fact") and is rendered to SB-REF-RULES.md
-- (SB-INDEX-027). A seed copy here would be a second home for state that goes stale
-- the first time a rule retires (CANON-DOCTRINE §0g write-forward rule). Live at
-- capture: 23 rows, 32,768 bytes. How a fresh deploy seeds the registry is a PM
-- decision, named here and not guessed.
--
-- ENG-175 HALF (b) CLOSED 2026-09-10. The live COMMENT opened with the grade
-- STRUCTURED, which is not one of the five rungs in ENGINE-CANON-LAYERS §L2 (RAW /
-- CALCULATED / VERDICT / PREDICTED / RECOMMENDED). PM ruled RAW: a registry the seats
-- write, with no computation in it, whose provenance is the seat and the date. CC
-- re-stamped it live by migration eng175b_engine_rules_grade_raw, and the COMMENT
-- below is that re-stamped text. The retired first line, kept for lineage (R28):
--   "GRADE: STRUCTURED. The governance registry specified in RULE-BOOK R28 §4 ..."
--
-- READERS, verified at source on 2026-09-10: NO function, view or cron job in public
-- references this table. Its only reader is the SB-REF-RULES generator, outside the
-- database.
--
-- ACCESS, live: RLS ENABLED with ZERO policies. anon and authenticated hold a SELECT
-- grant yet read ZERO rows through PostgREST (the ENG-068 / ENG-163 shape). A surface
-- that must read it needs a SECURITY DEFINER reader. The `m` (MAINTAIN) privilege on
-- anon and authenticated comes from the platform's default privileges and is
-- reproduced, not granted, here. Live ACL at capture:
--   {postgres=arwdDxtm/postgres,anon=rm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}

CREATE TABLE IF NOT EXISTS public.engine_rules (
  client_id        text        NOT NULL DEFAULT 'socialbrand'::text,
  rule_id          text        NOT NULL,
  name             text        NOT NULL,
  canon_home       text        NOT NULL,
  section          text,
  effective_from   date        NOT NULL,
  retired_on       date,
  superseded_by    text,
  scope            text        NOT NULL,
  evidence_class   text        NOT NULL,
  evidence_n       text,
  base_rate        text,
  enactment        text        NOT NULL,
  enacting_object  text,
  owner            text,
  review_date      date,
  status           text        NOT NULL DEFAULT 'LIVE'::text,
  statement        text        NOT NULL,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engine_rules_pkey PRIMARY KEY (client_id, rule_id),
  CONSTRAINT engine_rules_scope_check CHECK (scope = ANY (ARRAY['GENERAL'::text, 'DEMO_CALIBRATION'::text])),
  CONSTRAINT engine_rules_evidence_class_check CHECK (evidence_class = ANY (ARRAY['DEDUCTIVE'::text, 'CONTROLLED'::text, 'SINGLE-OBSERVATION'::text, 'RULING'::text, 'UNSTAMPED'::text])),
  CONSTRAINT engine_rules_enactment_check CHECK (enactment = ANY (ARRAY['WIRED'::text, 'PARKED'::text, 'PROSE'::text, 'UNSTAMPED'::text])),
  CONSTRAINT engine_rules_status_check CHECK (status = ANY (ARRAY['LIVE'::text, 'CANDIDATE'::text, 'RETIRED'::text, 'SUPERSEDED'::text, 'FALSIFIED'::text]))
);

COMMENT ON TABLE public.engine_rules IS $c$GRADE: RAW. The governance registry specified in RULE-BOOK R28 §4 on 2026-06-17 and unbuilt for 74 days. One row per rule; canon documents RENDER from this rather than accreting prose. Seeded 2026-08-30 from RULE-BOOK by PM. Answers four questions no document could: what is live, what nothing enacts, what went stale, what replaced what. Governs R28 (lineage), FILE-GOVERNANCE §0i (enactment), R34 (count standing). Re-stamped 2026-09-10 from the off-ladder grade STRUCTURED on PM's ruling (BUG-LOG ENG-175 half (b)): a registry the seats write, with no computation in it, whose provenance is the seat and the date.$c$;

ALTER TABLE public.engine_rules ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.engine_rules FROM anon, authenticated;
GRANT SELECT ON public.engine_rules TO anon, authenticated;
