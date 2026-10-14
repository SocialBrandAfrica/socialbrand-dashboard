-- =============================================================================
-- BLOOM-035 / ENG-202 -- THE CONSOLIDATED DESK FOR THE CATCH-ALL ACCOUNTS (PM ruling 14-10-2026: "ENG-202 goes in after 1b";
-- Pieter RULING 2026-09-10 20:03, ORDERING-CANON A2 case 4; ruling A3 of 13-10: ALGEMEEN, VARIOUS SINGLES and LOCAL GENERAL are catch-all accounts).
--
--   WHAT IT IS NOW. Item 1 gave every real supplier a desk, so the only lines left without one are those received against a catch-all account.
--   13 products at the time of writing: 7 at 10116 (ALGEMEEN, supplier 1516, 38 products received in 182 days) and 6 at 80175 (LOCAL GENERAL SUPPLIER,
--   supplier 2250, 33 products received). The desk is a DIRECT route (a bloom_route_config row whose direct_supplier_nrs are the store's catch-all
--   accounts), so every DIRECT code path serves it unchanged: the pool is the accounts' active links, the verdict ranks overlaps by receipt (A1),
--   the recipe, the cache and the readers take the route as a parameter.
--
--   ITS OWN LEDGER ROW (ENG-202 point 4, "never pooled into DIRECT", ENG-176 route grain). The ledger route DIRECT_CATCHALL is carved out of the pooled
--   DIRECT row in the five places that map a route to a ledger route (needs, landed, in transit, the recipe, the delivery budget, the budget context,
--   the scenario overview), so the pooled DIRECT need of the six brand desks does not move. R22: its fingerprint is read before and after.
--
--   refresh_catchall_desk(store) creates the route row and the calendar row and runs nightly in cron job 54. The delivery days are the weekdays the
--   accounts received on (the modal-share rule of the DC fresh desk, VERIFY), NOT a derived cadence: a first version used rpc_derive_supplier_cadence and
--   returned Tuesday at 10116 and Wednesday at 80175 at 27.5% and 20.0% confidence, while the accounts receive on every weekday (13 to 20 receipt days of
--   26 weeks for each of Monday to Friday). It was replaced the same afternoon (migration bloom035_eng202_catchall_desk_v2, function body only).
--   The placement fact stops PARKing a catch-all line once the store has the desk.
--
--   Each patched function is pinned on its live md5 (14-10-2026 after bloom035_1b_dc_fresh_phase0 and the sales-budget skip), every replacement asserts
--   its anchor count. REVERSE: swap the from/to of each replacement, drop refresh_catchall_desk, delete the DIRECT_CATCHALL rows of bloom_route_config
--   and supplier_calendar, restore job 54.
-- =============================================================================

CREATE FUNCTION pg_temp.rp(p_def text, p_from text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: anchor [%] found % time(s), expected %', p_what, left(p_from, 70), n, p_expect;
  END IF;
  RETURN replace(p_def, p_from, p_to);
END $f$;

CREATE FUNCTION pg_temp.rx(p_def text, p_pat text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM regexp_matches(p_def, p_pat, 'g');
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: pattern [%] found % time(s), expected %', p_what, left(p_pat, 70), n, p_expect;
  END IF;
  RETURN regexp_replace(p_def, p_pat, p_to, 'g');
END $f$;

SET lock_timeout = '5s';

-- Re-synced from the live definition 2026-10-14 (after bloom035_1b_dc_fresh_phase0, ENG-204).
CREATE OR REPLACE FUNCTION public.refresh_catchall_desk(p_store_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_store    text;
  v_wm       date;
  v_win      int;
  v_share    numeric;
  v_key      constant text := 'DIRECT_CATCHALL';
  v_nrs      bigint[];
  v_recv     int;
  v_prod     int;
  v_dows     int[];
  v_note     text;
  v_new      boolean;
  v_out      jsonb := '[]'::jsonb;
BEGIN
  SELECT fc.value_num::int INTO v_win FROM forge_config fc
   WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_win IS NULL THEN RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing'; END IF;
  SELECT fc.value_num INTO v_share FROM forge_config fc
   WHERE fc.config_key = 'desk_dow_min_modal_share' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_share IS NULL THEN RAISE EXCEPTION 'forge_config desk_dow_min_modal_share is missing'; END IF;

  FOR v_store IN SELECT s.store_code FROM stores s WHERE s.is_active AND (p_store_code IS NULL OR s.store_code = p_store_code) ORDER BY 1 LOOP
    SELECT max(movement_date) INTO v_wm FROM sigma_movements WHERE store_code = v_store;

    -- the store's catch-all accounts, matched by name exactly as refresh_supplier_desks and the placement fact match them
    SELECT array_agg(DISTINCT sm.supplier_nr ORDER BY sm.supplier_nr) INTO v_nrs
      FROM sigma_supplier_master sm
      JOIN bloom_catchall_account ca ON upper(btrim(sm.name)) = ca.account_name OR upper(btrim(sm.name)) LIKE ca.account_name || ' %'
     WHERE sm.store_code = v_store;

    SELECT count(*)::int, count(DISTINCT m.product_code)::int INTO v_recv, v_prod
      FROM sigma_movements m
     WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
       AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm
       AND m.supplier_nr = ANY (COALESCE(v_nrs, ARRAY[]::bigint[]));

    IF v_nrs IS NULL OR v_recv = 0 THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'status', 'no_catchall_receipts', 'accounts', v_nrs, 'watermark', v_wm));
      CONTINUE;
    END IF;

    v_note := format('DERIVED FROM RECEIPTS (BLOOM-035 ENG-202, ruling of 10-09 and A3 of 13-10). The consolidated desk of the catch-all accounts %s: %s receipt line(s) for %s product(s) in the %s days to %s. A catch-all account is not a supplier, so the lines are not grouped by supplier. Own ledger row (route grain, never pooled into DIRECT). Receipt-proven, never typed.',
                     v_nrs::text, v_recv, v_prod, v_win, v_wm);
    INSERT INTO bloom_route_config
      (store_code, route_key, merch_group_nrs, excluded_supplier_types, status, scope, effective_from, notes,
       direct_supplier_nrs, direct_cycle_weeks, direct_min_order_value)
    VALUES (v_store, v_key, NULL, ARRAY['Z'], 'RULED', 'GENERAL', CURRENT_DATE, v_note, v_nrs, 1, NULL)
    ON CONFLICT (store_code, route_key) DO UPDATE
      SET direct_supplier_nrs = EXCLUDED.direct_supplier_nrs, notes = EXCLUDED.notes, updated_at = now();

    -- A catch-all account has no cadence: local suppliers deliver against it on any weekday (measured 14-10: Monday to Friday, 13 to 20 receipt days each
    -- of 26 weeks at 10116 and 80175, so the cadence function's modal weekday reads 27.5% and 20.0% confidence, below dow_confidence_min 60). The delivery
    -- days are the weekdays whose receipt days reach desk_dow_min_modal_share of the modal weekday's, the rule of the DC fresh desk, and the note says VERIFY.
    SELECT array_agg(u.dw ORDER BY u.dw)::int[] INTO v_dows
      FROM (SELECT t.dw, t.days, max(t.days) OVER () AS mx
              FROM (SELECT EXTRACT(ISODOW FROM m.movement_date)::int AS dw, count(DISTINCT m.movement_date)::int AS days
                      FROM sigma_movements m
                     WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
                       AND m.supplier_nr = ANY (v_nrs) AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm
                     GROUP BY 1) t) u
     WHERE u.days >= v_share * u.mx;

    v_new := NOT EXISTS (SELECT 1 FROM supplier_calendar sc WHERE sc.store_code = v_store AND sc.route_key = v_key);
    INSERT INTO supplier_calendar
      (store_code, route_key, delivery_dows, scope, effective_from, source_note, order_cutoff_days, promo_buyin_lead_days, cycle_weeks, cycle_anchor_week_start,
       display_label, desk_sort)
    VALUES (v_store, v_key, v_dows::smallint[], 'GENERAL', CURRENT_DATE,
            format('VERIFY, derived from receipts (BLOOM-035 ENG-202). A catch-all account has no cadence: the delivery weekdays %s are the weekdays whose receipt days in the %s days to %s reach %s of the modal weekday''s (forge_config desk_dow_min_modal_share, SEED UNDERIVED). Cycle weekly, doubt resolves weekly (ORDERING-CANON A5). Cutoff: the general rule, minimum 2 days.',
                   v_dows::text, v_win, v_wm, v_share),
            2, 7, 1, NULL, 'Catch-all accounts', 2000)
    ON CONFLICT (store_code, route_key) DO UPDATE
      SET delivery_dows = EXCLUDED.delivery_dows,
          source_note = EXCLUDED.source_note
                        || COALESCE(CASE WHEN position(' | cutoff derived' IN supplier_calendar.source_note) > 0
                                         THEN substring(supplier_calendar.source_note FROM position(' | cutoff derived' IN supplier_calendar.source_note)) END, ''),
          updated_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'status', 'ok', 'accounts', v_nrs,
              'receipt_lines', v_recv, 'products_received', v_prod, 'delivery_dows', v_dows, 'calendar_created', v_new, 'watermark', v_wm));
  END LOOP;
  RETURN jsonb_build_object('stores', v_out);
END
$function$;

REVOKE EXECUTE ON FUNCTION public.refresh_catchall_desk(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_catchall_desk(text) TO service_role;
COMMENT ON FUNCTION public.refresh_catchall_desk(text) IS 'GRADE: RECOMMENDED. BLOOM-035 ENG-202. The consolidated desk of the catch-all accounts: one DIRECT_CATCHALL route per store whose catch-all accounts received in the receipt window, derived from the receipts (never typed), with its own ledger row. Idempotent, nightly (cron job 54). Internal, service_role only.';

DO $mig$
DECLARE
  pin record;
  def text;
  v_live text;
BEGIN
  FOR pin IN SELECT * FROM (VALUES
    ('refresh_l2_received_placement',     '2afb153d721b9f4f95b0908860ec2a82'),
    ('refresh_order_budget_ledger_needs', '6246e600ac4ff39ed6ad2a110cb4e00e'),
    ('rpc_bloom_budget_context',          'ba2cf6fb99383e7a4d54382c5a860196'),
    ('rpc_bloom_delivery_budget',         '7bd5011fc0b728ac565a77304b2681f0'),
    ('rpc_bloom_order_recipe',            '51c7bed45d5a9b50760ea7755c12b22f'),
    ('rpc_bloom_scenario_overview',       '182fd2f73d9d8f975f1b5a8a73c89c10')
  ) v(fn, md5pin) LOOP
    SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = pin.fn;
    IF v_live IS DISTINCT FROM pin.md5pin THEN
      RAISE EXCEPTION 'pin failed for %: live md5 % is not the pinned %', pin.fn, v_live, pin.md5pin;
    END IF;
  END LOOP;

  -- 1. the placement fact: a catch-all line is PARKED only while the store has no catch-all desk
  def := pg_get_functiondef('public.refresh_l2_received_placement(text)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN f.catchall THEN 'PARKED'$a$, $b$WHEN f.catchall AND f.desk IS NULL THEN 'PARKED'$b$, 1, 'placement state');
  def := pg_temp.rp(def, $a$WHEN f.catchall THEN 'CATCH_ALL_ACCOUNT'$a$, $b$WHEN f.catchall AND f.desk IS NULL THEN 'CATCH_ALL_ACCOUNT'$b$, 1, 'placement reason code');
  def := pg_temp.rp(def, $a$WHEN f.catchall THEN format('Booked against the catch-all account %s. It has no supplier desk. It waits for the store consolidated desk (ENG-202, not built).', f.nm)$a$,
                         $b$WHEN f.catchall AND f.desk IS NULL THEN format('Booked against the catch-all account %s. It has no supplier desk and the store has no catch-all desk (no receipt against the catch-all accounts in the window).', f.nm)$b$, 1, 'placement reason text');
  EXECUTE def;

  -- 2. the ledger needs: DIRECT_CATCHALL is its own ledger route, carved out of the pooled DIRECT row, landed and in transit
  def := pg_get_functiondef('public.refresh_order_budget_ledger_needs(text)'::regprocedure);
  def := pg_temp.rx(def, $a$(WHEN sb\.route_key = 'DIRECT_BEER'\s+THEN 'DIRECT_BEER')$a$,
                         $b$WHEN sb.route_key = 'DIRECT_CATCHALL' THEN 'DIRECT_CATCHALL'
                \1$b$, 1, 'needs ledger route');
  def := pg_temp.rp(def, $a$AND route_key <> 'DIRECT_BEER'),$a$,
                         $b$AND route_key NOT IN ('DIRECT_BEER', 'DIRECT_CATCHALL')),
  catchall AS (
    SELECT unnest(direct_supplier_nrs) AS supplier_nr FROM bloom_route_config
     WHERE store_code=p_store AND route_key='DIRECT_CATCHALL'),$b$, 1, 'needs direct cte');
  def := pg_temp.rp(def, $a$WHEN m.supplier_nr IN (SELECT supplier_nr FROM direct) THEN 'DIRECT'$a$,
                         $b$WHEN m.supplier_nr IN (SELECT supplier_nr FROM catchall) THEN 'DIRECT_CATCHALL'
             WHEN m.supplier_nr IN (SELECT supplier_nr FROM direct) THEN 'DIRECT'$b$, 1, 'needs landed');
  def := pg_temp.rp(def, $a$WHEN o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$a$,
                         $b$WHEN o.route_keys[1] = 'DIRECT_CATCHALL'         THEN 'DIRECT_CATCHALL'
             WHEN o.route_keys[1] LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'$b$, 1, 'needs transit');
  EXECUTE def;

  -- 3. the recipe: the ledger route of the desk
  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'$a$,
                         $b$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
    WHEN p_route = 'DIRECT_CATCHALL' THEN 'DIRECT_CATCHALL'$b$, 1, 'recipe ledger route');
  EXECUTE def;

  -- 4. the budget context
  def := pg_get_functiondef('public.rpc_bloom_budget_context(text, text, date)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_desk = 'DC_FRESH' THEN 'DC_FRESH'$a$,
                         $b$WHEN p_desk = 'DC_FRESH' THEN 'DC_FRESH'
             WHEN p_desk = 'DIRECT_CATCHALL' THEN 'DIRECT_CATCHALL'$b$, 1, 'budget_context ledger route');
  EXECUTE def;

  -- 5. the delivery budget
  def := pg_get_functiondef('public.rpc_bloom_delivery_budget(text, text, date)'::regprocedure);
  def := pg_temp.rx(def, $a$(WHEN p_route = 'DIRECT_BEER'\s+THEN 'DIRECT_BEER')$a$,
                         $b$WHEN p_route = 'DIRECT_CATCHALL' THEN 'DIRECT_CATCHALL'
                  \1$b$, 1, 'delivery_budget route');
  def := pg_temp.rp(def, $a$AND rc.route_key <> 'DIRECT_BEER') ) )) );$a$,
                         $b$AND rc.route_key NOT IN ('DIRECT_BEER', 'DIRECT_CATCHALL'))
                    OR (v_route='DIRECT_CATCHALL' AND rc.route_key='DIRECT_CATCHALL') ) )) );$b$, 1, 'delivery_budget landed');
  def := pg_temp.rp(def, $a$AND o.route_keys[1] <> 'DIRECT_BEER') );$a$,
                         $b$AND o.route_keys[1] NOT IN ('DIRECT_BEER', 'DIRECT_CATCHALL'))
       OR (v_route='DIRECT_CATCHALL' AND o.route_keys[1]='DIRECT_CATCHALL') );$b$, 1, 'delivery_budget transit');
  EXECUTE def;

  -- 6. the scenario overview
  def := pg_get_functiondef('public.rpc_bloom_scenario_overview(text, date, date, text, numeric, text[], boolean)'::regprocedure);
  def := pg_temp.rp(def, $a$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'$a$,
                         $b$WHEN p_route = 'DC_FRESH' THEN 'DC_FRESH'
        WHEN p_route = 'DIRECT_CATCHALL' THEN 'DIRECT_CATCHALL'$b$, 1, 'scenario ledger route');
  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
