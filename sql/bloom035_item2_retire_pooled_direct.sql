-- =============================================================================
-- BLOOM-035 item 2 follow-up. PM 14-10-2026 16:13, handover section 29 item 4: "Retire the pooled DIRECT rows and refresh_order_budget_ledger() with a date. Don't delete."
--
--   WHY: since item 2 (applied 14-10 15:12 SAST) every DIRECT desk reads and writes its OWN ledger route. refresh_order_budget_ledger_needs no longer writes the
--   pooled route_key = 'DIRECT' (its rows keep the values of the last run, 119 weekly rows at 5 stores, last written 14-10 12:5x UTC) and nothing reads it
--   (rpc_bloom_budget_context, rpc_bloom_delivery_budget, rpc_bloom_stored_overview and the recipe follow the desk's route). refresh_order_budget_ledger() (no
--   argument) is called by no function and no cron job (read from pg_proc and cron.job 14-10 15:5x SAST). It writes a pooled 'DIRECT' row from a different
--   source (sales_incl_vat). Its sales_actual leg stopped on 2026-07-11 (19 rows, newest period 2026-07-11). Its landed leg was retired 2026-08-16.
--
--   WHAT: R28 retirement, nothing deleted. The function keeps its body and gets a comment that carries retired_on and superseded_by (its older comment is kept
--   behind it). The 119 pooled rows keep every number and get a marker at the front of source_note. Reverse: remove the marker text, the comment is plain text.
--   retired_on 2026-10-14. superseded_by: refresh_order_budget_ledger_needs(text) and the per-desk ledger routes (BUG-LOG ENG-237, ENG-176 closed by item 2).
-- =============================================================================

SET lock_timeout = '5s';

DO $mig$
DECLARE
  v_old text; v_new text; v_pooled int; v_marked int;
BEGIN
  SELECT obj_description('public.refresh_order_budget_ledger()'::regprocedure, 'pg_proc') INTO v_old;
  IF v_old IS NOT NULL AND v_old LIKE 'RETIRED (R28, retired_on 2026-10-14%' THEN
    RAISE NOTICE 'function comment already carries the 2026-10-14 retirement, left as it is';
  ELSE
    v_new := 'RETIRED (R28, retired_on 2026-10-14, superseded_by refresh_order_budget_ledger_needs(text) and the per-desk ledger routes, BLOOM-035 item 2, PM 14-10-2026 16:13 handover section 29). '
          || 'Not deleted. It is called by no function and no cron job. It writes a pooled route_key DIRECT row from sales_incl_vat, which nothing reads since item 2 gave every DIRECT desk its own ledger route. '
          || 'Its sales_actual leg stopped 2026-07-11. Do not re-enable it: two writers on one ledger is the defect these retirements close. EARLIER COMMENT: ' || COALESCE(v_old, '(none)');
    EXECUTE format('COMMENT ON FUNCTION public.refresh_order_budget_ledger() IS %L', v_new);
  END IF;

  SELECT count(*) INTO v_pooled FROM public.order_budget_ledger WHERE route_key = 'DIRECT';
  UPDATE public.order_budget_ledger
     SET source_note = 'RETIRED 2026-10-14 (BLOOM-035 item 2, PM 16:13): pooled DIRECT row, last written 2026-10-14 12:5x UTC, read by nothing, superseded by the per-desk routes DIRECT_<desk>. Not deleted, every number below is as last written. | ' || COALESCE(source_note, '')
   WHERE route_key = 'DIRECT' AND COALESCE(source_note, '') NOT LIKE 'RETIRED 2026-10-14%';
  SELECT count(*) INTO v_marked FROM public.order_budget_ledger WHERE route_key = 'DIRECT' AND source_note LIKE 'RETIRED 2026-10-14%';
  IF v_marked <> v_pooled THEN RAISE EXCEPTION 'marked % of % pooled DIRECT rows', v_marked, v_pooled; END IF;
  RAISE NOTICE 'pooled DIRECT rows retired: %', v_marked;
END
$mig$;
