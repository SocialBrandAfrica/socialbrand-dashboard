-- ENG-146 part 2 (PM rulings 14-10 section 15 point 3): retention 455 days (Pieter 14:00 "we keep 5 qurters everywhere"),
-- partition-and-drop (no row-by-row DELETE), last-known SOH of every product kept as its own fact before any drop.
-- Supersedes the purge_l2_soh_daily body in eng146_purge_l2_soh_daily_control.sql: the live path now REFUSES.
-- Dry-run after apply: status SUCCESS (oldest snapshot 2026-06-11 is inside the window; cutoff 2025-07-15), 0 rows droppable.
-- First day droppable: newest snapshot reaching 2027-09-09. The partition conversion of l2_soh_daily (dependents l2_stock_position,
-- mv_kpi_by_date, mv_sparkline_14d, v_l2_soh_effective; exclusion-adjacent) must land before then: owed, not built here.
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES ('l2_soh_daily_retention_days','*',455,'DEMO_CALIBRATION',DATE '2026-10-14',
 'RULED by Pieter 14-10-2026 14:00 ("we keep 5 qurters everywhere"); signed Pieter 14-10-2026. 5 quarters = 455 days (R6 arithmetic: a 91-day window plus last year 364). First day droppable: when the newest snapshot reaches 2027-09-09 (oldest snapshot today is 2026-06-11). Drop is by partition, never row DELETE; l2_soh_last_known must be current first.')
ON CONFLICT (config_key, store_format) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.l2_soh_last_known (
  client_id          text NOT NULL,
  store_code         text NOT NULL,
  product_code       bigint NOT NULL,
  last_snapshot_date date NOT NULL,
  soh                numeric,
  computed_at        timestamptz NOT NULL DEFAULT now(),
  source             text NOT NULL DEFAULT 'l2_soh_daily (latest snapshot row per product)',
  PRIMARY KEY (client_id, store_code, product_code)
);
CREATE INDEX IF NOT EXISTS l2_soh_last_known_store_date ON public.l2_soh_last_known (store_code, last_snapshot_date);
ALTER TABLE public.l2_soh_last_known ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.l2_soh_last_known FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.l2_soh_last_known TO service_role;
COMMENT ON TABLE public.l2_soh_last_known IS 'GRADE: DERIVED. ENG-146. The last-known stock on hand of every (store, product) that has ever been in l2_soh_daily, kept as its own fact so dropping old snapshot partitions never loses it (PM 14-10 s15 pt3, facts rule). Written by refresh_l2_soh_last_known().';

CREATE OR REPLACE FUNCTION public.refresh_l2_soh_last_known(p_full boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $fn$
DECLARE v_n bigint := 0; v_rows bigint; v_status text := 'SUCCESS'; v_err text; v_res jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('refresh_l2_soh_last_known')) THEN
    RETURN jsonb_build_object('status','SKIPPED','reason','another run holds the lock');
  END IF;
  BEGIN
    IF p_full THEN
      INSERT INTO public.l2_soh_last_known (client_id, store_code, product_code, last_snapshot_date, soh)
      SELECT DISTINCT ON (d.client_id, d.store_code, d.product_code) d.client_id, d.store_code, d.product_code, d.snapshot_date, d.soh
        FROM public.l2_soh_daily d
       ORDER BY d.client_id, d.store_code, d.product_code, d.snapshot_date DESC
      ON CONFLICT (client_id, store_code, product_code) DO UPDATE
        SET last_snapshot_date = EXCLUDED.last_snapshot_date, soh = EXCLUDED.soh, computed_at = now()
        WHERE EXCLUDED.last_snapshot_date >= public.l2_soh_last_known.last_snapshot_date;
    ELSE
      INSERT INTO public.l2_soh_last_known (client_id, store_code, product_code, last_snapshot_date, soh)
      WITH m AS (
        SELECT s.store_code, COALESCE(max(k.last_snapshot_date), DATE '1900-01-01') AS mx
          FROM public.stores s LEFT JOIN public.l2_soh_last_known k ON k.store_code = s.store_code
         WHERE s.is_active GROUP BY s.store_code)
      SELECT DISTINCT ON (d.client_id, d.store_code, d.product_code) d.client_id, d.store_code, d.product_code, d.snapshot_date, d.soh
        FROM public.l2_soh_daily d JOIN m ON m.store_code = d.store_code
       WHERE d.snapshot_date > m.mx
       ORDER BY d.client_id, d.store_code, d.product_code, d.snapshot_date DESC
      ON CONFLICT (client_id, store_code, product_code) DO UPDATE
        SET last_snapshot_date = EXCLUDED.last_snapshot_date, soh = EXCLUDED.soh, computed_at = now()
        WHERE EXCLUDED.last_snapshot_date >= public.l2_soh_last_known.last_snapshot_date;
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    v_status := 'FAILED'; v_err := SQLERRM;
  END;
  SELECT count(*) INTO v_rows FROM public.l2_soh_last_known;
  INSERT INTO public.push_log (store_code, push_type, table_name, status, error_message, rows_pushed, started_at, completed_at, script_version)
  SELECT s.store_code, 'retention', 'l2_soh_last_known', v_status, v_err, v_n, now(), now(), 'last_known_v1'
    FROM public.stores s WHERE s.is_active;
  v_res := jsonb_build_object('status',v_status,'full',p_full,'upserted',v_n,'table_rows',v_rows,'error',v_err);
  RETURN v_res;
END $fn$;
REVOKE ALL ON FUNCTION public.refresh_l2_soh_last_known(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_soh_last_known(boolean) TO service_role;
COMMENT ON FUNCTION public.refresh_l2_soh_last_known(boolean) IS 'ENG-146. Keeps l2_soh_last_known current; logs push_type retention / table_name l2_soh_last_known (FAILED on error, so a failed run is not a green cron row). Nightly cron l2-soh-last-known at 01:30 UTC; the first run on the empty table is the full seed.';

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
      v_msg := 'LIVE DELETE REFUSED: retention is ruled as partition-and-drop (PM 14-10), never row-by-row DELETE; nothing deleted. Window ' || v_keep || ' days; table spans ' || v_oldest || ' to ' || v_newest;
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
COMMENT ON FUNCTION public.purge_l2_soh_daily(boolean,integer) IS 'GRADE: CONTROL. ENG-146 v2 (14-10-2026). Retention check for l2_soh_daily: window 455 days from forge_config (Pieter 14-10). Counts what a partition drop would remove; the live path REFUSES (partition-and-drop is ruled, row DELETE is not). FAILED while the table holds anything older than the window. Logs push_type retention / table_name l2_soh_daily_retention.';

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='l2-soh-last-known') THEN
    PERFORM cron.schedule('l2-soh-last-known','30 1 * * *', $c$SET statement_timeout = '3600s'; SELECT public.refresh_l2_soh_last_known(false);$c$);
  END IF;
END $do$;