-- AUD-012 step A (PM 14-10 section 36/38: go ahead; no ruling). Names every interior hole in l2_soh_daily and makes the nightly feed check see the recent ones.
-- Step B (a ledger-derived OVERLAY, never rows inside the RAW l2_soh_daily; base from v_l2_soh_effective; logging under its own table_name) is NOT built: it needs the PM ruling restated in the BUG-LOG AUD-012 addendum.
-- Before (14-10 ~19:5x SAST): 19 store-days missing between each store's first and newest snapshot (80579: 16, 21355: 3), all real trading days; the nightly check read only max(snapshot_date).
-- After step A: the same 19 sit on v_l2_soh_gap_worklist (MISSING, store_traded true on all 19); count unchanged by design. 
-- DECLARED: on the first run after apply, store 21355 turns FAILED for 2026-10-11 (3 days old, inside the 14-day window) and stays FAILED until the window passes it (about 10-26) or the hole is filled. The other 18 holes are older than 14 days and stay on the worklist only.
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES ('l2_soh_gap_lookback_days','*',14,'DEMO_CALIBRATION',CURRENT_DATE,'AUD-012. Days back from store-local today in which an interior l2_soh_daily hole turns the nightly feed check red. Older holes stay on v_l2_soh_gap_worklist. Invented threshold: PM to sign.')
ON CONFLICT (config_key, store_format) DO NOTHING;

CREATE OR REPLACE VIEW public.v_l2_soh_gap_worklist AS
WITH span AS (
  SELECT s.store_code,
    (SELECT d.snapshot_date FROM public.l2_soh_daily d WHERE d.store_code=s.store_code ORDER BY d.snapshot_date ASC  LIMIT 1) AS first_d,
    (SELECT d.snapshot_date FROM public.l2_soh_daily d WHERE d.store_code=s.store_code ORDER BY d.snapshot_date DESC LIMIT 1) AS last_d
  FROM public.stores s WHERE s.is_active),
days AS (SELECT sp.store_code, g::date AS snapshot_date FROM span sp CROSS JOIN LATERAL generate_series(sp.first_d, sp.last_d, interval '1 day') g),
gap AS (
  SELECT d.store_code, d.snapshot_date, 'MISSING'::text AS status
    FROM days d LEFT JOIN LATERAL (SELECT 1 AS present FROM public.l2_soh_daily x WHERE x.store_code=d.store_code AND x.snapshot_date=d.snapshot_date LIMIT 1) p ON true
   WHERE p.present IS NULL)
SELECT g.store_code, g.snapshot_date AS missing_date, g.status, COALESCE(mv.n,0) AS movement_rows, sa.sales_incl_vat,
       (COALESCE(mv.n,0) > 0 OR COALESCE(sa.sales_incl_vat,0) > 0) AS store_traded
  FROM gap g
  LEFT JOIN LATERAL (SELECT count(*) AS n FROM public.sigma_movements m WHERE m.store_code=g.store_code AND m.movement_date=g.snapshot_date) mv ON true
  LEFT JOIN LATERAL (SELECT round(sum(ss.sales_incl_vat),2) AS sales_incl_vat FROM public.sigma_sales ss WHERE ss.store_code=g.store_code AND ss.sale_date=g.snapshot_date AND ss.period_kind='T' AND ss.txn_kind=1) sa ON true;
REVOKE ALL ON public.v_l2_soh_gap_worklist FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_l2_soh_gap_worklist TO service_role;
COMMENT ON VIEW public.v_l2_soh_gap_worklist IS 'GRADE: CALCULATED. AUD-012. The named worklist of every interior l2_soh_daily hole (MISSING: a store-date between a store''s first and newest snapshot with no rows) with the ledger and sales evidence that the store traded. Probe form: filter on (store_code, snapshot_date); never min/max over the whole 47M-row table.';

CREATE OR REPLACE FUNCTION public.check_l1_feed_freshness()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_store     text;
  v_expected  date;
  v_sales_max date;
  v_mv_max    date;
  v_soh_max   date;
  v_problems  text;
  v_status    text;
  v_summary   jsonb := '{}'::jsonb;
  v_gaps      text;
  v_lookback  int;
BEGIN
  SELECT fc.value_num::int INTO v_lookback FROM forge_config fc
   WHERE fc.config_key = 'l2_soh_gap_lookback_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  FOR v_store IN SELECT s.store_code FROM stores s WHERE s.is_active ORDER BY s.store_code
  LOOP
    SELECT (now() AT TIME ZONE COALESCE(c.time_zone, 'Africa/Johannesburg'))::date
      INTO v_expected
      FROM (SELECT 1) one
      LEFT JOIN store_extract_config c
             ON c.store_code = v_store AND c.is_active;

    SELECT MAX(sale_date) INTO v_sales_max FROM sigma_sales
      WHERE store_code = v_store AND period_kind='T' AND txn_kind=1;
    SELECT MAX(movement_date) INTO v_mv_max FROM sigma_movements WHERE store_code = v_store;
    SELECT MAX(snapshot_date) INTO v_soh_max FROM l2_soh_daily WHERE store_code = v_store;

    v_problems := '';
    IF v_sales_max IS NULL OR v_sales_max < v_expected THEN
      v_problems := v_problems || format('sigma_sales stale: last %s, expected %s; ',
                       COALESCE(v_sales_max::text,'never'), v_expected);
    END IF;
    IF v_mv_max IS NULL OR v_mv_max < v_expected THEN
      v_problems := v_problems || format('sigma_movements stale: last %s, expected %s; ',
                       COALESCE(v_mv_max::text,'never'), v_expected);
    END IF;
    IF v_soh_max IS NULL OR v_soh_max < v_expected THEN
      v_problems := v_problems || format('l2_soh_daily stale: last %s, expected %s; ',
                       COALESCE(v_soh_max::text,'never'), v_expected);
    END IF;

    -- AUD-012: an interior hole inside the lookback window turns the check red, loudly
    IF v_lookback IS NULL THEN
      v_problems := v_problems || 'l2_soh_gap_lookback_days unsigned; ';
    ELSE
      SELECT string_agg(w.missing_date::text, ', ' ORDER BY w.missing_date) INTO v_gaps
        FROM v_l2_soh_gap_worklist w
       WHERE w.store_code = v_store AND w.status = 'MISSING' AND w.missing_date >= v_expected - v_lookback;
      IF v_gaps IS NOT NULL THEN
        v_problems := v_problems || format('l2_soh_daily interior gap: %s; ', v_gaps);
      END IF;
    END IF;

    v_status := CASE WHEN v_problems = '' THEN 'SUCCESS' ELSE 'FAILED' END;

    INSERT INTO push_log (store_code, push_type, table_name, status,
                          error_message, started_at, completed_at, script_version)
    VALUES (v_store, 'feed_check', 'l1_feeds', v_status,
            NULLIF(v_problems, ''), now(), now(), 'feed_check_v3');

    v_summary := v_summary || jsonb_build_object(v_store, COALESCE(NULLIF(v_problems,''), 'fresh'));
  END LOOP;

  RETURN v_summary;
END;
$function$;