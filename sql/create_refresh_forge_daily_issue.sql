-- =============================================================================
-- create_refresh_forge_daily_issue.sql
-- SB-CC-TOOLKIT-002 item 1 -- the morning auto-issue of the daily count list.
-- Applied 2026-08-13 (Pieter explicit go). Byte-faithful to migrations
-- forge_daily_count_volume_fixed + forge_daily_auto_issue +
-- forge_no_force_count_on_weekend_or_dc_day (canon s13 rule 3).
-- =============================================================================
-- THE ROUTINE. Every trading morning the platform issues the day's count list
-- per store at a fixed volume (200 SPAR / 70 TOPS), ranked by ordering impact
-- (rpc_forge_count_list), logged as a run. Nobody in the store picks the lines.
-- A same-store-same-day dedupe guard closes the 08-07 double-issue defect.
--
-- NON-COUNT DAY RULE (Pieter 2026-08-13): a count is NEVER FORCED on a Saturday,
-- a Sunday, or the store's DC ambient delivery day (the store is busy receiving).
-- Config-driven via supplier_calendar.delivery_dows for the store's DC route
-- (DC_AMBIENT at a SPAR, DC_TOPS at a TOPS) -- portable, no hardcoded store days
-- (R25/R28). The manual Composer / pre-order / ad-hoc counts are UNAFFECTED.
-- isodow 6=Sat, 7=Sun; DC dows are Mon-Sat so isodow and dow coincide.
--
-- SCOPE: fixed volumes and DC dows are DEMO_CALIBRATION (store #6 sets its own);
-- the issue mechanism, dedupe and weekend/DC skip are GENERAL.
-- =============================================================================

-- 1. Fixed daily volume config (replaces the self-sizing budget in rpc_forge_count_list)
INSERT INTO forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
  ('daily_count_volume','SPAR', 200, 'DEMO_CALIBRATION', CURRENT_DATE, 'SB-CC-TOOLKIT-002 item 1 -- fixed daily count list volume per SPAR store (Pieter 2026-08-12). Replaces self-sizing budget.'),
  ('daily_count_volume','TOPS',  70, 'DEMO_CALIBRATION', CURRENT_DATE, 'SB-CC-TOOLKIT-002 item 1 -- fixed daily count list volume per TOPS store, 70 max (Pieter 2026-08-12).')
ON CONFLICT DO NOTHING;

-- 2. The auto-issue function. SECURITY DEFINER (writes the run + frozen lines as
--    owner; sigma_movements/l2_* are RLS-locked). source='forge', issued_by='system'.
CREATE OR REPLACE FUNCTION public.refresh_forge_daily_issue()
 RETURNS TABLE(out_store text, out_run uuid, out_lines integer, out_skipped boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v record;
  v_run uuid;
  v_n int;
  v_vol int;
  v_pool int;
  v_today  date := (now() AT TIME ZONE 'Africa/Johannesburg')::date;
  v_isodow int  := extract(isodow FROM (now() AT TIME ZONE 'Africa/Johannesburg'))::int;
  v_dc_dows int[];
BEGIN
  FOR v IN SELECT s.store_code AS sc, s.store_type AS fmt FROM stores s WHERE s.is_active ORDER BY s.store_code LOOP
    -- NON-COUNT DAY RULE: Sat, Sun, or this store's DC ambient delivery day
    SELECT sc.delivery_dows::int[] INTO v_dc_dows FROM supplier_calendar sc
      WHERE sc.store_code = v.sc AND sc.route_key LIKE 'DC%'
      ORDER BY sc.effective_from DESC LIMIT 1;
    IF v_isodow IN (6,7) OR (v_dc_dows IS NOT NULL AND v_isodow = ANY(v_dc_dows)) THEN
      out_store := v.sc; out_run := NULL; out_lines := 0; out_skipped := true; RETURN NEXT; CONTINUE;
    END IF;
    -- DEDUPE: one daily list per store per SAST day
    IF EXISTS (SELECT 1 FROM forge_count_run r
               WHERE r.store_code = v.sc AND r.mode = 'daily'
                 AND (r.issued_at AT TIME ZONE 'Africa/Johannesburg')::date = v_today) THEN
      out_store := v.sc; out_run := NULL; out_lines := 0; out_skipped := true; RETURN NEXT; CONTINUE;
    END IF;
    SELECT f.value_num::int INTO v_vol FROM forge_config f
      WHERE f.config_key='daily_count_volume' AND f.retired_on IS NULL AND f.store_format IN (v.fmt,'*')
      ORDER BY f.store_format DESC LIMIT 1;
    SELECT count(*) INTO v_pool FROM l2_stock_position sp
      JOIN sigma_articles a ON a.store_code=sp.store_code AND a.product_code=sp.product_code
      WHERE sp.store_code=v.sc AND sp.class='NORMAL' AND sp.soh<>0;
    v_run := gen_random_uuid();
    INSERT INTO forge_count_run(run_id, client_id, store_code, issued_at, issued_by, source, mode, params, seed, line_count, pool_size, daily_budget, notes)
    VALUES (v_run, 'socialbrand', v.sc, now(), 'system', 'forge', 'daily', '{"auto":true}'::jsonb, '0.42', 0, v_pool, v_vol,
            'auto-issued by refresh_forge_daily_issue (SB-CC-TOOLKIT-002 item 1)');
    INSERT INTO forge_count_run_line(run_id, store_code, product_code, stratum, description, soh_at_issue, capital_at_issue, last_counted_at_issue)
    SELECT v_run, cl.store_code, cl.product_code, cl.stratum_label, cl.description, cl.soh, cl.capital_value, cl.last_counted
    FROM rpc_forge_count_list(ARRAY[v.sc], 'daily') cl;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE forge_count_run SET line_count = v_n WHERE run_id = v_run;
    out_store := v.sc; out_run := v_run; out_lines := v_n; out_skipped := false; RETURN NEXT;
  END LOOP;
END $function$;

REVOKE EXECUTE ON FUNCTION public.refresh_forge_daily_issue() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_forge_daily_issue() TO service_role;

-- 3. Schedule helper the compliance board reads so non-count days (weekend / DC
--    delivery) show honestly, never as a compliance failure. Returns each active
--    store's DC route + delivery day-of-week set (isodow); the frontend adds Sat/Sun.
CREATE OR REPLACE FUNCTION public.rpc_forge_count_schedule()
 RETURNS TABLE(store_code text, dc_route text, dc_dows int[])
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT s.store_code,
    (SELECT sc.route_key FROM supplier_calendar sc WHERE sc.store_code=s.store_code AND sc.route_key LIKE 'DC%' ORDER BY sc.effective_from DESC LIMIT 1),
    (SELECT sc.delivery_dows::int[] FROM supplier_calendar sc WHERE sc.store_code=s.store_code AND sc.route_key LIKE 'DC%' ORDER BY sc.effective_from DESC LIMIT 1)
  FROM stores s WHERE s.is_active ORDER BY s.store_code;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_forge_count_schedule() TO anon, authenticated;

-- 4. Morning cron: 04:30 UTC = 06:30 SAST, before trading, after the nightly refresh.
--    (Re-running cron.schedule with the same name updates the schedule in place.)
SELECT cron.schedule('forge-daily-issue', '30 4 * * *', $cron$SELECT public.refresh_forge_daily_issue();$cron$);
