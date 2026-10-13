-- =============================================================================
-- ENG-241 -- COUNT COMPLIANCE READS THE APP'S OWN LOG (SB-CC-STOCKTAKE-001 v1.2 section 7, item 5)
--
-- "Daily lists generated in the app against lists finalised on time, read from the app's own
-- log." The toolkit's count compliance board used to read the Composer's issued lists
-- (rpc_forge_compliance_summary, forge_count_run). The Composer is retired, so the board reads
-- the app's cycles through this one function.
--
-- ON TIME: a DAILY list is on time when it is finalised inside count_window_days (forge_config,
-- the key the count law already uses, ENGINE-CANON-COUNT-LAW 15.1) of its generation date,
-- store-local. One row per (store, generation day). The row keeps the column names the board
-- already reads (issue_date, runs, lines_issued, lines_counted, verdict) so the board needs one
-- source swap, not a rewrite.
--
-- VERDICT per (store, day), DAILY lists only, cancelled lists out:
--   MISSED       a list is still open after its window
--   IN WINDOW    a list is still open and inside its window
--   CLOSED LATE  every list is finalised but at least one after its window
--   ADHERED      every list finalised inside its window
--
-- ROLLBACK: DROP FUNCTION public.rpc_stocktake_compliance(date, date); the board's source swap
-- in public/toolkit.html is reverted by git.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_stocktake_compliance(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 120 THEN
    RAISE EXCEPTION 'give a date range of at most 120 days';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'store_code', q.store_code, 'issue_date', q.issue_date, 'runs', q.runs,
      'lines_issued', q.lines_issued, 'lines_counted', q.lines_counted,
      'compliance_pct', CASE WHEN q.lines_issued > 0 THEN ROUND(100.0 * q.lines_counted / q.lines_issued) END,
      'finalised_on_time', q.on_time, 'closed_late', q.closed_late, 'still_open', q.open_in + q.open_late,
      'verdict', CASE WHEN q.open_late > 0 THEN 'MISSED'
                      WHEN q.open_in > 0 THEN 'IN WINDOW'
                      WHEN q.closed_late > 0 THEN 'CLOSED LATE'
                      ELSE 'ADHERED' END)
      ORDER BY q.store_code, q.issue_date), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT c.store_code, c.generated_on AS issue_date,
           COUNT(*)::int AS runs,
           SUM(c.line_count)::int AS lines_issued,
           SUM((SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.count_qty IS NOT NULL))::int AS lines_counted,
           COUNT(*) FILTER (WHERE c.status = 'FINALISED'
                              AND (c.finalised_at AT TIME ZONE s.timezone)::date <= c.generated_on + w.win)::int AS on_time,
           COUNT(*) FILTER (WHERE c.status = 'FINALISED'
                              AND (c.finalised_at AT TIME ZONE s.timezone)::date > c.generated_on + w.win)::int AS closed_late,
           COUNT(*) FILTER (WHERE c.status IN ('PENDING_CAPTURE', 'CAPTURING')
                              AND store_local_today(c.store_code) <= c.generated_on + w.win)::int AS open_in,
           COUNT(*) FILTER (WHERE c.status IN ('PENDING_CAPTURE', 'CAPTURING')
                              AND store_local_today(c.store_code) > c.generated_on + w.win)::int AS open_late
    FROM stocktake_cycle c
    JOIN stores s ON s.store_code = c.store_code
    CROSS JOIN LATERAL (SELECT COALESCE(stocktake_cfg('count_window_days', c.store_code), 2)::int AS win) w
    WHERE c.list_type = 'DAILY' AND c.status <> 'CANCELLED'
      AND c.generated_on BETWEEN p_from AND p_to
    GROUP BY c.store_code, c.generated_on
  ) q;
  RETURN v_out;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_stocktake_compliance(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_stocktake_compliance(date, date) TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_stocktake_compliance(date, date) IS 'GRADE: CALCULATED. Count compliance from the stocktake app''s own cycles: per store and generation day, DAILY lists generated, lines issued and captured, lists finalised inside count_window_days, and the verdict (ADHERED, IN WINDOW, CLOSED LATE, MISSED). Replaces the Composer-fed board source (SB-CC-STOCKTAKE-001 section 7 item 5).';

NOTIFY pgrst, 'reload schema';
