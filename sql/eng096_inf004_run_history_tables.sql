-- ENG-096 (R33 sign-off, PM 14-10): every audit run writes its result, so the next baseline is read, not remembered (facts rule).
-- INF-004 (PM 14-10 s33): the 06:00 check writes its result to a table the toolkit shows.
-- Final form after migration inf004_sales_check_own_push_type: the check logs push_type 'sales_check', NOT 'feed_check'
-- (rpc_layer_freshness reads the latest feed_check row per store and would have lost the l1_feeds reading).
CREATE TABLE IF NOT EXISTS public.audit_statement_timeout_history (
  run_id        bigint GENERATED ALWAYS AS IDENTITY,
  computed_at   timestamptz NOT NULL DEFAULT now(),
  source        text NOT NULL DEFAULT 'audit_statement_timeout_ceilings()',
  kind          text NOT NULL,
  object_name   text NOT NULL,
  stated_s      numeric,
  effective_s   numeric,
  evidence_max_ok_s numeric,
  severity      text NOT NULL,
  verdict       text NOT NULL,
  detail        text,
  run_stamp     timestamptz NOT NULL,
  PRIMARY KEY (run_id)
);
CREATE INDEX IF NOT EXISTS audit_statement_timeout_history_run ON public.audit_statement_timeout_history (run_stamp DESC, severity);
ALTER TABLE public.audit_statement_timeout_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.audit_statement_timeout_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.audit_statement_timeout_history TO service_role;
COMMENT ON TABLE public.audit_statement_timeout_history IS 'GRADE: DERIVED. ENG-096. One row per object per run of audit_statement_timeout_ceilings(); written by record_statement_timeout_audit() nightly (cron audit-statement-timeouts) and on demand. run_stamp groups a run.';

CREATE OR REPLACE FUNCTION public.record_statement_timeout_audit()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE v_stamp timestamptz := now(); v_n int; v_by jsonb;
BEGIN
  INSERT INTO public.audit_statement_timeout_history (kind, object_name, stated_s, effective_s, evidence_max_ok_s, severity, verdict, detail, run_stamp)
  SELECT a.kind, a.object_name, a.stated_s, a.effective_s, a.evidence_max_ok_s, a.severity, a.verdict, a.detail, v_stamp
    FROM public.audit_statement_timeout_ceilings() a;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  SELECT coalesce(jsonb_object_agg(severity, c), '{}'::jsonb) INTO v_by
    FROM (SELECT severity, count(*) c FROM public.audit_statement_timeout_history WHERE run_stamp = v_stamp GROUP BY 1) s;
  RETURN jsonb_build_object('run_stamp', v_stamp, 'rows', v_n, 'by_severity', v_by);
END $fn$;
REVOKE ALL ON FUNCTION public.record_statement_timeout_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_statement_timeout_audit() TO service_role;
COMMENT ON FUNCTION public.record_statement_timeout_audit() IS 'ENG-096. Writes one audit_statement_timeout_history row per object for this run and returns the severity counts. FAIL > 0 is a defect.';

CREATE TABLE IF NOT EXISTS public.sales_extract_check (
  check_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  computed_at   timestamptz NOT NULL DEFAULT now(),
  source        text NOT NULL DEFAULT 'v_sales_extract_completeness',
  client_id     text,
  store_code    text NOT NULL,
  sale_date     date NOT NULL,
  lines         bigint,
  baseline_lines numeric,
  pct_of_baseline numeric,
  verdict       text NOT NULL,
  run_stamp     timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS sales_extract_check_run ON public.sales_extract_check (run_stamp DESC, store_code, sale_date);
ALTER TABLE public.sales_extract_check ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sales_extract_check_read ON public.sales_extract_check;
CREATE POLICY sales_extract_check_read ON public.sales_extract_check FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.sales_extract_check FROM PUBLIC, anon;
GRANT SELECT ON public.sales_extract_check TO authenticated;
GRANT SELECT ON public.sales_extract_check TO service_role;
COMMENT ON TABLE public.sales_extract_check IS 'GRADE: DERIVED. INF-004. The 06:00 SAST check: for every active store, every completed sale_date of the last 28 whose verdict is not OK, plus the latest completed date whatever its verdict, from v_sales_extract_completeness. Authenticated read (R30).';

CREATE OR REPLACE FUNCTION public.record_sales_extract_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE v_stamp timestamptz := now(); v_n int; v_bad int;
BEGIN
  INSERT INTO public.sales_extract_check (client_id, store_code, sale_date, lines, baseline_lines, pct_of_baseline, verdict, run_stamp)
  SELECT c.client_id, c.store_code, c.sale_date, c.lines, c.baseline_lines, c.pct_of_baseline, c.verdict, v_stamp
    FROM public.v_sales_extract_completeness c
   WHERE c.verdict IN ('SHORT','MISSING')
      OR c.sale_date = (SELECT max(x.sale_date) FROM public.v_sales_extract_completeness x WHERE x.store_code = c.store_code);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  SELECT count(*) INTO v_bad FROM public.sales_extract_check WHERE run_stamp = v_stamp AND verdict IN ('SHORT','MISSING');
  INSERT INTO public.push_log (store_code, push_type, table_name, status, error_message, rows_pushed, started_at, completed_at, script_version)
  SELECT s.store_code, 'sales_check', 'sales_extract_check', CASE WHEN v_bad = 0 THEN 'SUCCESS' ELSE 'FAILED' END,
         CASE WHEN v_bad = 0 THEN NULL ELSE format('%s short or missing sales day(s) in the last 28: see sales_extract_check run %s', v_bad, v_stamp) END,
         v_n, v_stamp, now(), 'inf004_check_v1'
    FROM public.stores s WHERE s.is_active;
  RETURN jsonb_build_object('run_stamp', v_stamp, 'rows', v_n, 'short_or_missing', v_bad);
END $fn$;
REVOKE ALL ON FUNCTION public.record_sales_extract_check() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_sales_extract_check() TO service_role;
COMMENT ON FUNCTION public.record_sales_extract_check() IS 'INF-004. 06:00 SAST check (cron sales-extract-check, 04:00 UTC): writes sales_extract_check and one push_log row per active store with push_type sales_check (NOT feed_check: rpc_layer_freshness reads the latest feed_check per store).';

CREATE OR REPLACE VIEW public.v_sales_extract_check_latest AS
SELECT c.* FROM public.sales_extract_check c
 WHERE c.run_stamp = (SELECT max(run_stamp) FROM public.sales_extract_check);
GRANT SELECT ON public.v_sales_extract_check_latest TO authenticated, service_role;
REVOKE ALL ON public.v_sales_extract_check_latest FROM anon;
COMMENT ON VIEW public.v_sales_extract_check_latest IS 'INF-004. The latest run of the 06:00 sales-extract check; the toolkit reads this. Authenticated only.';

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='audit-statement-timeouts') THEN
    PERFORM cron.schedule('audit-statement-timeouts','5 3 * * *', $c$SET statement_timeout = '600s'; SELECT public.record_statement_timeout_audit();$c$);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sales-extract-check') THEN
    PERFORM cron.schedule('sales-extract-check','0 4 * * *', $c$SET statement_timeout = '600s'; SELECT public.record_sales_extract_check();$c$);
  END IF;
END $do$;
-- one-off at apply time: DELETE FROM public.push_log WHERE push_type = 'feed_check' AND script_version = 'inf004_check_v1';  (5 test rows written under the wrong push_type, removed the same hour)