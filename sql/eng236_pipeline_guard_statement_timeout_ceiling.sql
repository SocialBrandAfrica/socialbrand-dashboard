-- ENG-236 / ENG-096 (platform lane 14-10-2026, PM s15 pt8). pipeline-guard (cron jobid 57, every 5 minutes)
-- carried no statement_timeout prefix: audit_statement_timeout_ceilings() read it as FAIL NO_CEILING.
-- Ceiling 600 s = the canon floor (its longest succeeded run is 1.2 s).
SELECT cron.alter_job(57, command := $c$SET statement_timeout = '600s'; SELECT public.guard_pipeline_orphans();$c$);