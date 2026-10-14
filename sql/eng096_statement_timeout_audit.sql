-- ENG-096: audit_statement_timeout_ceilings(), one read-only function; no existing object is touched. It lists every active cron job against its caller ceiling and every function that states a statement_timeout (in body or proconfig) against the role cap.
-- FAIL = a cron job with no ceiling or a ceiling at or below its normal run; WARN also covers a job killed by its own ceiling inside the window. Function rows are INERT by construction: Postgres arms the timer when the top-level statement starts.
-- Function rows state the role cap if called by anon/authenticated; callers may differ. Baseline is recorded in BUG-LOG ENG-096.
CREATE OR REPLACE FUNCTION public.audit_statement_timeout_ceilings(
  p_window_days int DEFAULT 21,      -- trailing 21 days of cron.job_run_details
  p_headroom    numeric DEFAULT 2.0, -- ceiling = 2x the job's own max SUCCEEDED run
  p_floor_s     int DEFAULT 600)     -- floor 600 s
RETURNS TABLE (kind text, object_name text, stated_s numeric, effective_s numeric, effective_source text,
               evidence_max_ok_s numeric, severity text, verdict text, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
WITH
prm AS (SELECT p_window_days AS w, p_headroom AS h, p_floor_s AS f),
t(u, mult) AS (VALUES ('ms', 0.001::numeric), ('s', 1::numeric), ('min', 60::numeric), ('h', 3600::numeric), ('d', 86400::numeric)),
cap AS (
  SELECT min(x.sec) FILTER (WHERE x.sec > 0) AS cap_s
  FROM (SELECT (m.a)[1]::numeric * t.mult AS sec
        FROM (SELECT regexp_match(c, '^statement_timeout=(\d+)\s*(ms|s|min|h|d)?$') AS a
              FROM pg_roles r CROSS JOIN LATERAL unnest(r.rolconfig) AS c
              WHERE r.rolname IN ('anon', 'authenticated')) m
        JOIN t ON t.u = coalesce((m.a)[2], 'ms') WHERE m.a IS NOT NULL) x
),
runs AS (
  SELECT d.jobid,
         count(*) FILTER (WHERE d.status = 'succeeded') AS ok_runs,
         max(extract(epoch FROM (d.end_time - d.start_time))) FILTER (WHERE d.status = 'succeeded') AS max_ok_s,
         count(*) FILTER (WHERE d.return_message ILIKE '%due to statement timeout%') AS kills
  FROM cron.job_run_details d, prm
  WHERE d.start_time >= now() - make_interval(days => prm.w)
  GROUP BY d.jobid
),
cj AS (
  SELECT j.jobid, coalesce(j.jobname, 'jobid:' || j.jobid)::text AS jobname,
         regexp_match(split_part(j.command, '$', 1),
           '(?i)(?:^|;)\s*set\s+(?:local\s+|session\s+)?statement_timeout\s*(?:=|to)\s*''?(\d+)\s*(ms|s|min|h|d)?''?') AS m
  FROM cron.job j WHERE j.active
),
cron_rows AS (
  SELECT 'cron_job'::text AS kind, cj.jobname || ' (jobid ' || cj.jobid || ')' AS object_name,
         CASE WHEN cj.m IS NOT NULL THEN (cj.m)[1]::numeric * (SELECT t.mult FROM t WHERE t.u = coalesce((cj.m)[2], 'ms')) END AS stated_s,
         r.max_ok_s, r.ok_runs, coalesce(r.kills, 0) AS kills
  FROM cj LEFT JOIN runs r ON r.jobid = cj.jobid
),
cron_out AS (
  SELECT c.kind, c.object_name, c.stated_s, c.stated_s AS effective_s,
         'caller: pg_cron command prefix'::text AS effective_source,
         round(c.max_ok_s::numeric, 1) AS evidence_max_ok_s,
         CASE WHEN c.stated_s IS NULL THEN 'FAIL'
              WHEN c.max_ok_s IS NOT NULL AND c.stated_s <= c.max_ok_s THEN 'FAIL'
              WHEN c.kills > 0 THEN 'WARN'
              WHEN c.max_ok_s IS NULL THEN 'WARN'
              WHEN c.stated_s < greatest(prm.f, prm.h * c.max_ok_s) THEN 'WARN'
              WHEN c.stated_s > 5 * greatest(prm.f, prm.h * c.max_ok_s) THEN 'INFO' ELSE 'OK' END AS severity,
         CASE WHEN c.stated_s IS NULL THEN 'NO_CEILING'
              WHEN c.max_ok_s IS NOT NULL AND c.stated_s <= c.max_ok_s THEN 'CEILING_AT_OR_BELOW_MAX_OK_RUN'
              WHEN c.kills > 0 THEN 'CEILING_KILLED_RUN_IN_WINDOW'
              WHEN c.max_ok_s IS NULL THEN 'NO_SUCCEEDED_RUN_IN_WINDOW'
              WHEN c.stated_s < greatest(prm.f, prm.h * c.max_ok_s) THEN 'HEADROOM_UNDER_RULE'
              WHEN c.stated_s > 5 * greatest(prm.f, prm.h * c.max_ok_s) THEN 'LOOSE_VS_RULE' ELSE 'OK' END AS verdict,
         format('succeeded runs %s, statement-timeout kills %s, rule value (headroom x max succeeded run, floored) = %s s',
                coalesce(c.ok_runs, 0), c.kills,
                CASE WHEN c.max_ok_s IS NULL THEN 'n/a' ELSE greatest(prm.f, ceil(prm.h * c.max_ok_s / 60) * 60)::text END) AS detail
  FROM cron_rows c, prm
),
fn AS (
  SELECT p.oid, p.oid::regprocedure::text AS sig,
         regexp_match(p.prosrc, '(?:^|[^a-z_])set\s+(?:local\s+)?statement_timeout\s*(?:=|to)\s*''?(\d+)\s*(ms|s|min|h|d)?', 'i') AS bs,
         regexp_match(p.prosrc, 'set_config\(\s*''statement_timeout''\s*,\s*''(\d+)\s*(ms|s|min|h|d)?''', 'i') AS bc,
         (SELECT regexp_match(c, '^statement_timeout=(\d+)\s*(ms|s|min|h|d)?$')
            FROM unnest(coalesce(p.proconfig, '{}'::text[])) c WHERE c LIKE 'statement_timeout=%' LIMIT 1) AS pc,
         (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')) AS req_callable
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prokind IN ('f', 'p')
    AND (p.prosrc ~* '(^|[^a-z_])set\s+(local\s+)?statement_timeout\s*(=|to)'
         OR p.prosrc ~* 'set_config\(\s*''statement_timeout'''
         OR p.proconfig::text ILIKE '%statement_timeout=%')
),
fs AS (
  SELECT fn.*, CASE WHEN fn.bs IS NOT NULL OR fn.bc IS NOT NULL THEN 'function_inbody' ELSE 'function_proconfig' END AS kind,
         (coalesce(fn.bs, fn.bc, fn.pc))[1]::numeric
           * (SELECT t.mult FROM t WHERE t.u = coalesce((coalesce(fn.bs, fn.bc, fn.pc))[2], 'ms')) AS stated_s
  FROM fn
),
fn_out AS (
  SELECT s.kind, s.sig AS object_name, s.stated_s,
         CASE WHEN s.req_callable THEN cap.cap_s END AS effective_s,
         CASE WHEN s.req_callable THEN 'role cap if called by anon/authenticated (pg_roles); callers may differ'
              ELSE 'caller-armed (cron prefix or session); not derivable from the catalog' END AS effective_source,
         NULL::numeric AS evidence_max_ok_s,
         CASE WHEN s.req_callable AND (s.stated_s = 0 OR s.stated_s > cap.cap_s) THEN 'WARN' ELSE 'INFO' END AS severity,
         CASE WHEN s.req_callable AND (s.stated_s = 0 OR s.stated_s > cap.cap_s) THEN 'INERT_CLAIMS_MORE_THAN_ROLE_CAP'
              WHEN s.req_callable AND s.stated_s < cap.cap_s THEN 'INERT_CLAIMS_LESS_THAN_ROLE_CAP'
              WHEN s.req_callable THEN 'INERT_EQUALS_ROLE_CAP' ELSE 'INERT_CALLER_ARMS' END AS verdict,
         CASE WHEN s.kind = 'function_inbody'
              THEN 'in-body SET / set_config changes the GUC after the statement timer was armed; it bounds nothing in this call (ENG-096)'
              ELSE 'function-level SET changes the GUC after the caller armed the timer; measured 2026-10-14 in direct sessions: proconfig 15s did not shorten an armed 25s or 40s timer. PostgREST path unmeasured (ENG-096)' END AS detail
  FROM fs s CROSS JOIN cap
)
SELECT kind, object_name, stated_s, effective_s, effective_source, evidence_max_ok_s, severity, verdict, detail FROM (
  SELECT * FROM cron_out UNION ALL SELECT * FROM fn_out ) z
ORDER BY CASE severity WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END, kind, object_name;
$fn$;
-- Supabase default ACLs grant EXECUTE on new public functions to anon/authenticated; this one reads cron.* so close it:
REVOKE ALL ON FUNCTION public.audit_statement_timeout_ceilings(int, numeric, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.audit_statement_timeout_ceilings(int, numeric, int) TO service_role;
COMMENT ON FUNCTION public.audit_statement_timeout_ceilings(int, numeric, int) IS 'ENG-096. GRADE: DERIVED. Every active pg_cron job against its caller ceiling (2x max SUCCEEDED run, floor 600 s, 21 d, all three parameters) and every function that states a statement_timeout in body or proconfig against the role cap they would get if called by anon or authenticated. FAIL = a job with no ceiling or a ceiling at or below a normal run. Function rows are INERT by construction (Postgres arms the timer at top-level statement start).';
