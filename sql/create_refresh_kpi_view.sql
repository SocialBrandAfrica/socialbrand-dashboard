-- =============================================================================
-- create_refresh_kpi_view.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for refresh_kpi_view.
-- Supersedes fix_refresh_kpi_view.sql + the copy embedded in mv_sparkline_14d.sql
-- (sediment). Extracted verbatim from LIVE 2026-06-17. Refreshes mv_kpi_by_date
-- with statement_timeout disabled. SCHEDULE: pg_cron 'nightly-kpi-refresh' 18:30 UTC.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.refresh_kpi_view()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  PERFORM set_config('statement_timeout', '0', true);
  REFRESH MATERIALIZED VIEW public.mv_kpi_by_date;
END;
$function$;

-- Fresh-deploy schedule. Commented to avoid altering the live pg_cron job on apply.
-- SELECT cron.schedule('nightly-kpi-refresh', '30 18 * * *', $$SELECT refresh_kpi_view();$$);
