-- ENG-146 phase 1: the retention control for l2_soh_daily. It deletes nothing on apply. purge_l2_soh_daily() logs push_type 'retention' / table_name 'l2_soh_daily_retention' per store; rpc_diag_push_log excludes push_type 'retention'.
-- Before (14-10 00:53 SAST): no routine purged the table, no cron job named it, ~47.3m rows (estimate), 10.4 GB, 2026-06-11..2026-10-13.
-- Superseded in part by eng146_retention_455_last_known_soh.sql (window from forge_config, live delete refused). Details in BUG-LOG ENG-146.
CREATE OR REPLACE FUNCTION public.purge_l2_soh_daily(p_dry_run boolean DEFAULT true, p_max_days integer DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_keep integer; v_newest date; v_oldest date; v_oldest_after date; v_cutoff date; v_day date;
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
    ELSE
      v_cutoff := v_newest - v_keep;
      v_day := v_oldest;
      WHILE v_day < v_cutoff AND v_days < p_max_days LOOP
        FOR r IN SELECT s.store_code FROM public.stores s WHERE s.is_active ORDER BY 1 LOOP
          SELECT d.snapshot_date INTO v_store_newest FROM public.l2_soh_daily d WHERE d.store_code=r.store_code ORDER BY d.snapshot_date DESC LIMIT 1;
          CONTINUE WHEN v_store_newest IS NULL OR v_day >= v_store_newest;
          IF p_dry_run THEN
            SELECT count(*) INTO v_n FROM public.l2_soh_daily d WHERE d.store_code=r.store_code AND d.snapshot_date=v_day;
          ELSE
            DELETE FROM public.l2_soh_daily d WHERE d.store_code=r.store_code AND d.snapshot_date=v_day;
            GET DIAGNOSTICS v_n = ROW_COUNT;
          END IF;
          v_by_store := jsonb_set(v_by_store, ARRAY[r.store_code], to_jsonb(COALESCE((v_by_store->>r.store_code)::bigint,0)+v_n));
        END LOOP;
        v_day := v_day + 1; v_days := v_days + 1;
      END LOOP;
      SELECT min(x.o) INTO v_oldest_after FROM (SELECT (SELECT d.snapshot_date FROM public.l2_soh_daily d WHERE d.store_code=s.store_code ORDER BY d.snapshot_date ASC LIMIT 1) AS o FROM public.stores s WHERE s.is_active) x;
      v_status := CASE WHEN v_oldest_after < v_cutoff THEN 'FAILED' ELSE 'SUCCESS' END;
      v_msg := CASE WHEN v_status='FAILED' THEN format('%s: oldest snapshot %s is older than cutoff %s (keep %s days); %s',
                 CASE WHEN p_dry_run THEN 'DRY-RUN, nothing deleted' ELSE 'BEHIND, rerun' END, v_oldest_after, v_cutoff, v_keep, v_by_store::text) END;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_status := 'FAILED'; v_msg := 'ERROR: ' || SQLERRM; v_err := true;
  END;
  INSERT INTO public.push_log (store_code, push_type, table_name, status, error_message, rows_pushed, started_at, completed_at, script_version)
  SELECT s.store_code, 'retention', 'l2_soh_daily_retention', v_status, v_msg,
         CASE WHEN p_dry_run OR v_err THEN 0 ELSE COALESCE((v_by_store->>s.store_code)::integer,0) END, now(), now(), 'retention_v1'
    FROM public.stores s WHERE s.is_active;
  RETURN jsonb_build_object('status',v_status,'dry_run',p_dry_run,'keep_days',v_keep,'newest',v_newest,'oldest_before',v_oldest,
                            'oldest_after',v_oldest_after,'cutoff',v_cutoff,'by_store',v_by_store,'message',v_msg);
END $fn$;
REVOKE ALL ON FUNCTION public.purge_l2_soh_daily(boolean,integer) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.purge_l2_soh_daily(boolean,integer) IS 'GRADE: CONTROL. ENG-146. Retention for l2_soh_daily. Window read from forge_config l2_soh_daily_retention_days, never typed here. Refuses to delete while unsigned. Reports FAILED whenever the oldest snapshot is older than the cutoff, in dry-run or live. Logs push_type retention / table_name l2_soh_daily_retention.';

CREATE OR REPLACE FUNCTION public.rpc_diag_push_log(p_from timestamp with time zone, p_limit integer DEFAULT 2000)
RETURNS TABLE(store_code text, snapshot_date date, tac_filename text, status text, rows_pushed integer, started_at timestamp with time zone)
LANGUAGE sql SECURITY DEFINER SET statement_timeout TO '15s'
AS $f$
    SELECT store_code, snapshot_date, tac_filename, status, rows_pushed, started_at
    FROM push_log
    WHERE started_at >= p_from AND push_type IS DISTINCT FROM 'retention'
    ORDER BY started_at DESC
    LIMIT p_limit;
$f$;

COMMENT ON TABLE public.l2_soh_daily IS
 'GRADE: RAW. Sigma DBStAr daily stock-on-hand snapshots, appended untouched. Named l2 by history, it is an L1 mirror.
Daily SOH history from DBStAr snapshots. One row per article per store per day. Written by the extractor (Invoke-SnapshotSohDaily). Append-only (ON CONFLICT DO NOTHING) except the retention trim by purge_l2_soh_daily(). sigma_lifecycle holds current state; this table holds the history for capital tied, days cover, and SOH trend. Retention: forge_config l2_soh_daily_retention_days via purge_l2_soh_daily(), cron l2-soh-daily-retention. [Retired sentence "13-month retention." was never implemented; replaced 14-10-2026, ENG-146.]';

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='l2-soh-daily-retention') THEN
    PERFORM cron.schedule('l2-soh-daily-retention','0 2 * * *',
      $c$SET statement_timeout = '3600s'; SELECT public.purge_l2_soh_daily(true, 7);$c$);
  END IF;
END $do$;