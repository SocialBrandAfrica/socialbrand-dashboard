-- Clean up orphaned RUNNING push_log entries from test runs during encoding fix
-- Run once in the Supabase SQL editor. Safe to re-run (idempotent).

UPDATE push_log
SET
    status        = 'FAILED',
    completed_at  = now(),
    error_message = 'Marked FAILED by cleanup - orphaned RUNNING entry from encoding test runs on 2026-05-17'
WHERE store_code   = '10116'
  AND status       = 'RUNNING'
  AND completed_at IS NULL;

-- Verify
SELECT push_id, table_name, push_type, started_at, status
FROM push_log
WHERE store_code = '10116'
ORDER BY started_at DESC
LIMIT 20;
