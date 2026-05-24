-- =============================================================================
-- fix_push_log_schema_cache.sql
--
-- One-time fix: reload PostgREST schema cache after ALTER TABLE in step5.
-- The ALTER TABLE in sb_sch_001_step5_push_log_migration.sql added snapshot_date,
-- rows_expected, tac_filename, duration_seconds but omitted pg_notify. PostgREST
-- cached the old schema and silently dropped those columns from PATCH bodies,
-- causing push_log.snapshot_date and tac_filename to remain NULL.
--
-- Run ONCE in the Supabase SQL Editor. Safe to run again (idempotent).
-- =============================================================================

SELECT pg_notify('pgrst', 'reload schema');

-- Verify the columns are now visible to PostgREST
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'push_log'
ORDER  BY ordinal_position;
-- Expected: snapshot_date (date), rows_expected (integer),
--           tac_filename (text), duration_seconds (integer) all present
