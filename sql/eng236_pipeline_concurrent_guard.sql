-- =============================================================================
-- ENG-236 THE FIX (CC, 14-10-2026, PM ruling 2 of 14-10 09:0x). The nightly pipeline is ONE transaction and every
-- plain REFRESH MATERIALIZED VIEW in it held an AccessExclusive lock to the very end, so every reader of a chain
-- matview waited the whole run and any reader that held one matview while it waited for another deadlocked it
-- (13-10-2026: the 20:15 run died of a 90-minute block, the rerun deadlocked twice, the third rerun ran 2 h and hit
-- its statement limit in the last step). LOCK TABLE refuses materialized views, so the locks cannot be taken up
-- front. WHAT CHANGES:
--   1. refresh_l2_pipeline: the six chain matviews AND the two mv_ views become REFRESH ... CONCURRENTLY
--      (all eight have a unique index with no WHERE, checked 14-10-2026). It takes an ExclusiveLock, which readers
--      do not conflict with, so no reader is ever blocked or deadlocked. Eight, not the ruled six: mv_kpi_by_date
--      is the Pulse dashboard's own table and would otherwise block it for the last stage of every run.
--      Tested on l2_kpi_daily and l2_ranging_tier inside a rolled-back transaction: 10.6 s and 32.3 s.
--   2. The guard: guard_pipeline_orphans() cancels read-only mgmt-api queries older than
--      forge_config pipeline_guard_max_query_minutes (10, SEED, UNDERIVED) WHILE the pipeline runs, and logs each
--      in pipeline_guard_log. Cron every 5 minutes (set outside this file).
--   Body change is an ASSERTED REPLACE on the live definition. The same replacements are applied to
--   sql/create_refresh_l2_pipeline.sql (hash-equal to live before this change, md5 c62e64a7).
-- ROLLBACK: restore refresh_l2_pipeline from git (sql/create_refresh_l2_pipeline.sql before this commit), unschedule
-- the guard, drop guard_pipeline_orphans and pipeline_guard_log, retire the config key.
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('pipeline_guard_max_query_minutes', '*', 10, 'DEMO_CALIBRATION', DATE '2026-10-14',
  'SEED, UNDERIVED. ENG-236: while refresh_l2_pipeline runs, a read-only mgmt-api query older than this many minutes is cancelled by guard_pipeline_orphans (a connector client that stops does not stop its query, so an analysis query outlives the person who ran it). Chosen, not derived: the longest legitimate analysis read seen on 13-10-2026 was under 5 minutes. Derivation owed.')
ON CONFLICT (config_key, store_format) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.pipeline_guard_log (
  log_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at               timestamptz NOT NULL DEFAULT now(),
  pid              integer     NOT NULL,
  application_name text,
  age_seconds      integer,
  limit_minutes    numeric,
  query_head       text
);
ALTER TABLE public.pipeline_guard_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pipeline_guard_log FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.pipeline_guard_log TO service_role;
COMMENT ON TABLE public.pipeline_guard_log IS 'GRADE: RAW. ENG-236. One row per query guard_pipeline_orphans cancelled while the nightly pipeline ran: who (application), how old, and the first 200 characters of its text. Append only.';

CREATE OR REPLACE FUNCTION public.guard_pipeline_orphans()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_min     numeric;
  v_running boolean;
  v_n       integer := 0;
  r         record;
BEGIN
  SELECT fc.value_num INTO v_min FROM forge_config fc
   WHERE fc.config_key = 'pipeline_guard_max_query_minutes' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_min IS NULL THEN
    RAISE EXCEPTION 'forge_config pipeline_guard_max_query_minutes is missing';
  END IF;

  SELECT EXISTS (SELECT 1 FROM pg_stat_activity a
                  WHERE a.state = 'active' AND a.application_name = 'pg_cron' AND a.pid <> pg_backend_pid()
                    AND a.query ILIKE '%refresh_l2_pipeline()%') INTO v_running;
  IF NOT v_running THEN
    RETURN jsonb_build_object('pipeline_running', false, 'limit_minutes', v_min, 'cancelled', 0);
  END IF;

  FOR r IN
    SELECT a.pid, a.application_name, EXTRACT(EPOCH FROM (now() - a.query_start))::int AS age_s, left(a.query, 200) AS q
      FROM pg_stat_activity a
     WHERE a.datname = current_database() AND a.state = 'active' AND a.backend_type = 'client backend'
       AND a.application_name = 'mgmt-api' AND a.pid <> pg_backend_pid()
       AND now() - a.query_start > make_interval(secs => v_min * 60)
       AND a.query !~* '\m(insert|update|delete|create|drop|alter|truncate|grant|revoke|refresh|vacuum|copy|call|do|merge)\M'
  LOOP
    IF pg_cancel_backend(r.pid) THEN
      v_n := v_n + 1;
      INSERT INTO pipeline_guard_log (pid, application_name, age_seconds, limit_minutes, query_head)
      VALUES (r.pid, r.application_name, r.age_s, v_min, r.q);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('pipeline_running', true, 'limit_minutes', v_min, 'cancelled', v_n);
END
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_pipeline_orphans() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_pipeline_orphans() TO service_role;
COMMENT ON FUNCTION public.guard_pipeline_orphans() IS 'GRADE: RECOMMENDED. ENG-236. While refresh_l2_pipeline runs, cancels mgmt-api queries that are read-only by their text and older than forge_config pipeline_guard_max_query_minutes, and logs each. Run by pg_cron every 5 minutes. Internal, service_role only.';

DO $mig$
DECLARE
  def text;
  n int;
BEGIN
  def := pg_get_functiondef('public.refresh_l2_pipeline()'::regprocedure);
  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_movements_typed;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_movements_typed;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 1 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_movements_typed;$a$, $b$  -- ENG-236 (14-10-2026): CONCURRENTLY, so no reader of a chain matview is ever blocked or deadlocked by this one
  -- long transaction (13-10-2026: two deadlocks and a 90-minute block). Each of these has a unique index.
  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_movements_typed;$b$);

  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_rate_of_sale;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_rate_of_sale;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 2 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_rate_of_sale;$a$, $b$  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_rate_of_sale;$b$);

  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_item_classification;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_item_classification;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 3 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_item_classification;$a$, $b$  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_item_classification;$b$);

  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_ranging_tier;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_ranging_tier;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 4 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_ranging_tier;$a$, $b$  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_ranging_tier;$b$);

  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_stock_position;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_stock_position;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 5 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_stock_position;$a$, $b$  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_stock_position;$b$);

  n := (length(def) - length(replace(def, $a$  REFRESH MATERIALIZED VIEW l2_kpi_daily;$a$, ''))) / length($a$  REFRESH MATERIALIZED VIEW l2_kpi_daily;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 6 found % times', n; END IF;
  def := replace(def, $a$  REFRESH MATERIALIZED VIEW l2_kpi_daily;$a$, $b$  REFRESH MATERIALIZED VIEW CONCURRENTLY l2_kpi_daily;$b$);

  n := (length(def) - length(replace(def, $a$    REFRESH MATERIALIZED VIEW mv_kpi_by_date;$a$, ''))) / length($a$    REFRESH MATERIALIZED VIEW mv_kpi_by_date;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 7 found % times', n; END IF;
  def := replace(def, $a$    REFRESH MATERIALIZED VIEW mv_kpi_by_date;$a$, $b$    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_kpi_by_date;$b$);

  n := (length(def) - length(replace(def, $a$    REFRESH MATERIALIZED VIEW mv_rate_of_sale;$a$, ''))) / length($a$    REFRESH MATERIALIZED VIEW mv_rate_of_sale;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pipeline anchor 8 found % times', n; END IF;
  def := replace(def, $a$    REFRESH MATERIALIZED VIEW mv_rate_of_sale;$a$, $b$    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_rate_of_sale;$b$);

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
