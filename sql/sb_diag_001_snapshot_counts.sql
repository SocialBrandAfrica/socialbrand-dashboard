-- sb_diag_001_snapshot_counts.sql
-- Run ONCE in the Supabase SQL editor.
-- Creates fn_diag_snapshot_counts used by diagnose_data.py (Section 3) and diagnose.html.
-- Safe to re-run (CREATE OR REPLACE).
--
-- SECURITY DEFINER: runs as the function owner (service role) so the publishable
-- (anon) key can call it from the browser diagnostic tool without a separate secret key.

CREATE OR REPLACE FUNCTION fn_diag_snapshot_counts(
    p_from       date,
    p_to         date,
    p_store_code text DEFAULT NULL
)
RETURNS TABLE (
    store_code    text,
    snapshot_date date,
    row_count     bigint,
    has_movement  bigint,
    total_sales   numeric,
    zero_soh      bigint
)
LANGUAGE sql
SECURITY DEFINER
SET statement_timeout = '55s'
AS $$
    SELECT
        store_code,
        snapshot_date,
        COUNT(*)                                        AS row_count,
        COUNT(*) FILTER (WHERE today_qty <> 0)         AS has_movement,
        SUM(today_sales)                               AS total_sales,
        COUNT(*) FILTER (WHERE soh <= 0 OR soh IS NULL) AS zero_soh
    FROM daily_snapshots
    WHERE snapshot_date BETWEEN p_from AND p_to
      AND (p_store_code IS NULL OR store_code = p_store_code)
    GROUP BY store_code, snapshot_date
    ORDER BY store_code, snapshot_date;
$$;

SELECT pg_notify('pgrst', 'reload schema');
