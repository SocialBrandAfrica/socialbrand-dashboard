-- ENG-262 (platform lane 14-10-2026, PM section 34 point 3 / section 18 point 5): the dashboard's head reads carried an own 15 s limit under a measured cold first read of 19.6 s (rpc_top20_totals, 5 stores x 15 dates; 0.45 s warm). ENG-096 rule: measured cold maximum x 1.5 = 30 s (also the anon/authenticated role cap).
-- ALTER FUNCTION changes only the limit; bodies, grants and the other proconfig entries are untouched.
ALTER FUNCTION public.rpc_top20_totals(text[],text[],text,text,text[]) SET statement_timeout = '30s';
ALTER FUNCTION public.rpc_ean_labels(text[],text[],text[],text,text) SET statement_timeout = '30s';
ALTER FUNCTION public.rpc_report_rows(text[],text[]) SET statement_timeout = '30s';
ALTER FUNCTION public.rpc_layer_freshness() SET statement_timeout = '30s';
ALTER FUNCTION public.rpc_push_status() SET statement_timeout = '30s';
ALTER FUNCTION public.rpc_push_available_dates() SET statement_timeout = '30s';

-- The warm read: one pass over the dashboard's head reads for yesterday and every active store, timed and logged (push_type warm).
-- Run it after every heavy job (section 18 point 5) and daily at 04:50 UTC (06:50 SAST), before the dashboard's working hours.
CREATE OR REPLACE FUNCTION public.warm_dashboard_head_reads()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_stores text[]; v_date text; v_t timestamptz; v_sc text; v_res jsonb := '[]'::jsonb;
  v_name text; v_err text; v_ms numeric;
BEGIN
  SELECT array_agg(s.store_code ORDER BY s.store_code) INTO v_stores FROM public.stores s WHERE s.is_active;
  v_date := to_char((now() AT TIME ZONE 'Africa/Johannesburg')::date - 1, 'YYYY-MM-DD');
  FOREACH v_name IN ARRAY ARRAY['rpc_report_rows','rpc_top20_totals','rpc_dept_summary','rpc_kpi_stock_by_date','rpc_layer_freshness','rpc_push_status','rpc_push_available_dates'] LOOP
    v_t := clock_timestamp(); v_err := NULL;
    BEGIN
      IF v_name = 'rpc_report_rows' THEN PERFORM public.rpc_report_rows(v_stores, ARRAY[v_date]);
      ELSIF v_name = 'rpc_top20_totals' THEN PERFORM public.rpc_top20_totals(v_stores, ARRAY[v_date], NULL, NULL, NULL);
      ELSIF v_name = 'rpc_dept_summary' THEN
        FOREACH v_sc IN ARRAY v_stores LOOP PERFORM public.rpc_dept_summary(ARRAY[v_sc], ARRAY[v_date], NULL, NULL); END LOOP;
      ELSIF v_name = 'rpc_kpi_stock_by_date' THEN PERFORM public.rpc_kpi_stock_by_date(v_stores, ARRAY[v_date]);
      ELSIF v_name = 'rpc_layer_freshness' THEN PERFORM * FROM public.rpc_layer_freshness();
      ELSIF v_name = 'rpc_push_status' THEN PERFORM * FROM public.rpc_push_status();
      ELSIF v_name = 'rpc_push_available_dates' THEN PERFORM * FROM public.rpc_push_available_dates();
      END IF;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    v_ms := round(extract(epoch FROM clock_timestamp() - v_t) * 1000);
    v_res := v_res || jsonb_build_array(jsonb_build_object('read', v_name, 'ms', v_ms, 'error', v_err));
    INSERT INTO public.push_log (store_code, push_type, table_name, status, error_message, rows_pushed, started_at, completed_at, script_version, duration_seconds)
    SELECT s.store_code, 'warm', v_name, CASE WHEN v_err IS NULL THEN 'SUCCESS' ELSE 'FAILED' END, v_err, 0, v_t, clock_timestamp(), 'warm_v1', round(v_ms / 1000)
      FROM public.stores s WHERE s.is_active;
  END LOOP;
  RETURN jsonb_build_object('date', v_date, 'stores', v_stores, 'reads', v_res);
END $fn$;
REVOKE ALL ON FUNCTION public.warm_dashboard_head_reads() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.warm_dashboard_head_reads() TO service_role;
COMMENT ON FUNCTION public.warm_dashboard_head_reads() IS 'ENG-262. Warms the dashboard head reads (report rows, Top 20 totals, department summary per store, stock KPIs, freshness, push status, available dates) for yesterday and all active stores, times each, logs push_type warm. Call after every heavy job; cron warm-dashboard-head-reads 04:50 UTC.';

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='warm-dashboard-head-reads') THEN
    PERFORM cron.schedule('warm-dashboard-head-reads','50 4 * * *', $c$SET statement_timeout = '900s'; SELECT public.warm_dashboard_head_reads();$c$);
  END IF;
END $do$;