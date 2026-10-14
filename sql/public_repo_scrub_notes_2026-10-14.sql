-- Public-repo scrub (14-10-2026): the sql/ files of this branch now carry technical notes and BUG-LOG ids only. This migration makes the private database match: forge_config notes, object comments and two function bodies are re-stated with the same neutral text. No logic changes.

UPDATE public.forge_config SET notes = 'AUD-012. Days back from store-local today in which an interior l2_soh_daily hole turns the nightly feed check red. 56 days; derivation in BUG-LOG AUD-012; older holes stay on v_l2_soh_gap_worklist. Retired value: 14 (scope DEMO_CALIBRATION, set by aud012_a_l2_soh_gap_detect).' WHERE config_key = 'l2_soh_gap_lookback_days' AND store_format = '*' AND retired_on IS NULL;

UPDATE public.forge_config SET notes = 'ENG-146. Retention 455 days = a 91-day window plus last year 364; derivation in BUG-LOG ENG-146. First day droppable: when the newest snapshot reaches 2027-09-09 (oldest snapshot today is 2026-06-11). Drop is by partition, never row DELETE; l2_soh_last_known must be current first.' WHERE config_key = 'l2_soh_daily_retention_days' AND store_format = '*' AND retired_on IS NULL;

UPDATE public.forge_config SET notes = 'ENG-039. Interim; value and basis are recorded in BUG-LOG ENG-039.' WHERE config_key = 'creditor_terms_days_dc' AND store_format = '*' AND retired_on IS NULL;

UPDATE public.forge_config SET notes = 'ENG-039. Interim; value and basis are recorded in BUG-LOG ENG-039.' WHERE config_key = 'creditor_terms_days_dropship' AND store_format = '*' AND retired_on IS NULL;

UPDATE public.forge_config SET notes = 'ENG-039. Interim; value and basis are recorded in BUG-LOG ENG-039.' WHERE config_key = 'creditor_statement_close_dow' AND store_format = '*' AND retired_on IS NULL;

UPDATE public.forge_config SET notes = 'ENG-039. First invoice date from which a derived due date applies; basis recorded in BUG-LOG ENG-039. Older invoices read UNDATED and are not back-filled.' WHERE config_key = 'creditor_terms_valid_from_yyyymmdd' AND store_format = '*' AND retired_on IS NULL;

COMMENT ON FUNCTION public.creditor_derived_due_date(date,text,integer) IS 'GRADE: DERIVED. ENG-039. Interim statement-rule due date from the forge_config terms keys for the supplier type and group. NULL when the account terms are unknown, the invoice is undated, or the invoice date is before creditor_terms_valid_from_yyyymmdd (UNDATED, never back-filled). Not DAYS OVERDUE: L1 has no paid flag.';

COMMENT ON VIEW public.v_creditor_ageing IS 'SB-CC-DEBT-001 deliverable 2 + ENG-039 (14-10-2026). Creditor ageing per (store, supplier, bucket) carrying the l2_creditor_stock_match verdict through. AGES ON invoice_date (fallback grv_date): this is TIME SINCE BILLED, never DAYS OVERDUE (L1 has no paid flag; do not relabel). Derived due dates (earliest/latest_derived_due_date) are interim and statement-rule based, apply only to the supplier type and group combinations that have configured terms and only from the first date with statement evidence (forge_config creditor_terms_valid_from_yyyymmdd); older invoices of those combinations read UNDATED (headers_due_undated), never back-filled. OPEN_ORDER headers excluded.';

COMMENT ON TABLE public.sales_extract_check IS 'GRADE: DERIVED. INF-004. The 06:00 SAST check: for every active store, every completed sale_date of the last 28 whose verdict is not OK, plus the latest completed date whatever its verdict, from v_sales_extract_completeness. Authenticated read.';

comment on view public.v_l2_movement_channel is 'GRADE: VERDICT. ENG-109/ENG-108. Superset of l2_movements_typed: S/L = TRANSFER_IN, S/M = TRANSFER_OUT, the rest unchanged. cost_value_money is NULL on the transfer legs because their cost_value is case-priced against single qty (BUG-LOG ENG-108): units are sound, the rand is not; cost_basis names why. ACL: authenticated + service_role only. Always filter store_code + movement_type/process (+date) to use idx_sigma_moves_type. S/L is uppercase L, S/l is a different channel. The matview l2_movements_typed still types these rows ADJUSTMENT until the planned rebuild.';

COMMENT ON TABLE public.l2_soh_last_known IS 'GRADE: DERIVED. ENG-146. The last-known stock on hand of every (store, product) that has ever been in l2_soh_daily, kept as its own fact so dropping old snapshot partitions never loses it (BUG-LOG ENG-146). Written by refresh_l2_soh_last_known().';

COMMENT ON TABLE public.l2_soh_daily IS
 'GRADE: RAW. Sigma DBStAr daily stock-on-hand snapshots, appended untouched. Named l2 by history, it is an L1 mirror.
Daily SOH history from DBStAr snapshots. One row per article per store per day. Written by the extractor (Invoke-SnapshotSohDaily). Append-only (ON CONFLICT DO NOTHING) except the retention trim by purge_l2_soh_daily(). sigma_lifecycle holds current state; this table holds the history for capital tied, days cover, and SOH trend. Retention: forge_config l2_soh_daily_retention_days via purge_l2_soh_daily(), cron l2-soh-daily-retention. [Retired sentence "13-month retention." was never implemented; replaced 14-10-2026, ENG-146.]';

CREATE OR REPLACE FUNCTION public.purge_l2_soh_daily(p_dry_run boolean DEFAULT true, p_max_days integer DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_keep integer; v_newest date; v_oldest date; v_cutoff date; v_day date;
  v_days integer := 0; v_store_newest date; v_n bigint; v_by_store jsonb := '{}'::jsonb;
  v_status text; v_msg text; v_err boolean := false; r record;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('purge_l2_soh_daily')) THEN
    RETURN jsonb_build_object('status','SKIPPED','reason','another run holds the lock');
  END IF;
  p_max_days := LEAST(GREATEST(COALESCE(p_max_days,7),1),62);
  BEGIN
    SELECT fc.value_num::integer INTO v_keep FROM public.forge_config fc
     WHERE fc.config_key='l2_soh_daily_retention_days' AND fc.store_format='*' AND fc.retired_on IS NULL;
    SELECT max(x.n), min(x.o) INTO v_newest, v_oldest FROM (
      SELECT (SELECT d.snapshot_date FROM public.l2_soh_daily d WHERE d.store_code=s.store_code ORDER BY d.snapshot_date DESC LIMIT 1) AS n,
             (SELECT d.snapshot_date FROM public.l2_soh_daily d WHERE d.store_code=s.store_code ORDER BY d.snapshot_date ASC  LIMIT 1) AS o
        FROM public.stores s WHERE s.is_active) x;
    IF v_keep IS NULL OR v_keep < 1 THEN
      v_status := 'FAILED';
      v_msg := format('UNSIGNED: forge_config l2_soh_daily_retention_days is absent; nothing deleted; table spans %s to %s (%s days)', v_oldest, v_newest, v_newest - v_oldest + 1);
    ELSIF NOT p_dry_run THEN
      v_status := 'FAILED';
      v_msg := 'LIVE DELETE REFUSED: retention is partition-and-drop only (BUG-LOG ENG-146), never row-by-row DELETE; nothing deleted. Window ' || v_keep || ' days; table spans ' || v_oldest || ' to ' || v_newest;
    ELSE
      v_cutoff := v_newest - v_keep;
      v_day := v_oldest;
      WHILE v_day < v_cutoff AND v_days < p_max_days LOOP
        FOR r IN SELECT s.store_code FROM public.stores s WHERE s.is_active ORDER BY 1 LOOP
          SELECT d.snapshot_date INTO v_store_newest FROM public.l2_soh_daily d WHERE d.store_code=r.store_code ORDER BY d.snapshot_date DESC LIMIT 1;
          CONTINUE WHEN v_store_newest IS NULL OR v_day >= v_store_newest;
          SELECT count(*) INTO v_n FROM public.l2_soh_daily d WHERE d.store_code=r.store_code AND d.snapshot_date=v_day;
          v_by_store := jsonb_set(v_by_store, ARRAY[r.store_code], to_jsonb(COALESCE((v_by_store->>r.store_code)::bigint,0)+v_n));
        END LOOP;
        v_day := v_day + 1; v_days := v_days + 1;
      END LOOP;
      v_status := CASE WHEN v_oldest < v_cutoff THEN 'FAILED' ELSE 'SUCCESS' END;
      v_msg := CASE WHEN v_status='FAILED' THEN format('DRY-RUN, nothing deleted: oldest snapshot %s is older than cutoff %s (keep %s days); would drop %s', v_oldest, v_cutoff, v_keep, v_by_store::text) END;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_status := 'FAILED'; v_msg := 'ERROR: ' || SQLERRM; v_err := true;
  END;
  INSERT INTO public.push_log (store_code, push_type, table_name, status, error_message, rows_pushed, started_at, completed_at, script_version)
  SELECT s.store_code, 'retention', 'l2_soh_daily_retention', v_status, v_msg, 0, now(), now(), 'retention_v2'
    FROM public.stores s WHERE s.is_active;
  RETURN jsonb_build_object('status',v_status,'dry_run',p_dry_run,'keep_days',v_keep,'newest',v_newest,'oldest',v_oldest,'cutoff',v_cutoff,'by_store',v_by_store,'message',v_msg);
END $fn$;
REVOKE ALL ON FUNCTION public.purge_l2_soh_daily(boolean,integer) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.purge_l2_soh_daily(boolean,integer) IS 'GRADE: CONTROL. ENG-146 v2 (14-10-2026). Retention check for l2_soh_daily: window 455 days from forge_config. Counts what a partition drop would remove; the live path REFUSES (partition-and-drop only, row DELETE is not allowed). FAILED while the table holds anything older than the window. Logs push_type retention / table_name l2_soh_daily_retention.';

CREATE OR REPLACE FUNCTION public.cleanup_push_log()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
  SELECT 1;  -- ENG-263: delete switched off; retired body: DELETE FROM push_log WHERE completed_at < NOW() - INTERVAL '30 days'; push_log is kept permanently.
$function$;
REVOKE EXECUTE ON FUNCTION public.cleanup_push_log() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.cleanup_push_log() IS 'RETIRED 14-10-2026 (ENG-263). The 30-day push_log delete is switched off; the function now does nothing. Nothing called it (0 cron jobs, 0 functions, 0 scripts). Successor: none; push_log is kept permanently.';
