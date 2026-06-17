-- =============================================================================
-- create_push_log.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for push_log.
-- No prior committed CREATE (sb_sch_001_step5_push_log_migration.sql was a
-- migration, not a create). Rebuilt from LIVE 2026-06-17 via catalog introspection.
-- IF NOT EXISTS => safe no-op against live. Written by the push script + extractor.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.push_log (
  push_id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id uuid,
  store_code text NOT NULL,
  push_type text NOT NULL,
  table_name text NOT NULL,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  rows_pushed integer DEFAULT 0,
  rows_failed integer DEFAULT 0,
  status text,
  error_message text,
  script_version text,
  snapshot_date date,
  rows_expected integer,
  tac_filename text,
  duration_seconds integer,
  CONSTRAINT push_log_pkey PRIMARY KEY (push_id)
);
