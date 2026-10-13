CREATE OR REPLACE FUNCTION public.refresh_bloom_order_cache(p_store_code text, p_route text, p_delivery_date date DEFAULT NULL::date, p_next_delivery date DEFAULT NULL::date, p_preset text DEFAULT NULL::text, p_fit_to_budget boolean DEFAULT false, p_source text DEFAULT 'nightly'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_del date; v_next date; v_cache_id bigint;
  v_t0 timestamptz; v_ms int; v_n int; v_md5 text; v_gen timestamptz;
  v_flagged int; v_appended int; v_max_line int;
  v_bm_anchor date; v_bm_weekly numeric;
BEGIN
  SET LOCAL statement_timeout = '300s';

  IF p_delivery_date IS NULL OR p_next_delivery IS NULL THEN
    SELECT nd.delivery_date, nd.following_date INTO v_del, v_next
    FROM public.rpc_bloom_next_deliveries(p_store_code, p_route, public.store_local_today(p_store_code)) nd LIMIT 1;  -- ENG-117: explicit store-local anchor, never inherited from the session
  END IF;
  v_del  := COALESCE(p_delivery_date, v_del);
  v_next := COALESCE(p_next_delivery, v_next);

  IF v_del IS NULL OR v_next IS NULL THEN
    RETURN jsonb_build_object('status','no_calendar_dates','store',p_store_code,'route',p_route);
  END IF;

  SELECT md5(pg_get_functiondef(p.oid)) INTO v_md5
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_bloom_order_recipe';

  DELETE FROM public.bloom_order_cache
   WHERE store_code=p_store_code AND route_key=p_route
     AND delivery_date=v_del AND next_delivery=v_next
     AND preset=COALESCE(p_preset,'standard') AND fit_to_budget=p_fit_to_budget;

  v_gen := clock_timestamp();
  INSERT INTO public.bloom_order_cache
    (store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget,
     engine_md5, source, generated_at)
  VALUES (p_store_code, p_route, v_del, v_next, COALESCE(p_preset,'standard'), p_fit_to_budget,
          v_md5, p_source, v_gen)
  RETURNING cache_id INTO v_cache_id;

  -- STEP 1, UNCHANGED. The recipe's own rows, positionally. Not one byte of the
  -- recipe is touched and no quantity moves anywhere below this line.
  v_t0 := clock_timestamp();
  INSERT INTO public.bloom_order_cache_line
  SELECT v_cache_id,
         row_number() OVER (ORDER BY r.rhythm_adjusted_demand DESC NULLS LAST, r.product_code),
         r.*, v_gen
  FROM public.rpc_bloom_order_recipe(
         p_store_code, v_del, v_next, NULL, p_preset, NULL, p_fit_to_budget,
         NULL, NULL, NULL, NULL, p_route) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- STEP 2, SB-CC-BLOOM-026 5(b2). A hidden line ALREADY ON THE SHEET is flagged
  -- IN PLACE, never appended a second time. Measured before building: 19 of the
  -- 396 hidden lines at 80175 DC_AMBIENT are already cache rows, so a naive
  -- append would show the buyer the same product twice.
  UPDATE public.bloom_order_cache_line l
     SET withheld_correction     = true,
         hidden_reason           = v.state_reason,
         hidden_rate_engine_read = v.rate_raw_56d,
         hidden_rate_corrected   = v.rate_corrected_56d,
         hidden_rate_guard       = v.rate_guard_56d,
         hidden_window_days      = 56,
         hidden_days_removed     = v.days_removed_56d,
         hidden_observable_days  = v.observable_days,
         hidden_observable_share = v.observable_share
    FROM public.l2_population_verdict v
   WHERE l.cache_id = v_cache_id
     AND v.store_code = p_store_code AND v.route_key = p_route
     AND v.flag_hidden_seller
     AND v.product_code = l.product_code;
  GET DIAGNOSTICS v_flagged = ROW_COUNT;

  -- STEP 3. The rest become NEW rows at ZERO quantity, pinned above by line_kind.
  -- rhythm_adjusted_demand carries the rate the ORDER READ so the sheet's own
  -- sort stays apples-to-apples; what the corrector measured rides its own
  -- column beside it, which is the whole point of the row (R28 SS5 on the surface).
  SELECT COALESCE(MAX(line_no),0) INTO v_max_line
    FROM public.bloom_order_cache_line WHERE cache_id = v_cache_id;

  INSERT INTO public.bloom_order_cache_line
    (cache_id, line_no, store_code, product_code, ean, description, dept_name, route,
     kvi_band, tier, range_state, rhythm_adjusted_demand, soh, pack_size, pack_cost,
     need_units, normal_packs, geared_packs, suggested_packs, value,
     promo_active, promo_nr, promo_start, promo_end, promo_suffix, promo_naming_gap, count_first, story, generated_at,
     line_kind, withheld_correction, hidden_reason, hidden_rate_engine_read, hidden_rate_corrected,
     hidden_rate_guard, hidden_window_days, hidden_days_removed,
     hidden_observable_days, hidden_observable_share)
  SELECT v_cache_id,
         v_max_line + row_number() OVER (ORDER BY v.rate_corrected_56d DESC NULLS LAST, v.product_code),
         v.store_code, v.product_code, b.ean::text, v.description, v.dept_name, p_route,
         v.kvi_band, v.tier, v.range_state, v.rate_raw_56d, v.soh,
         v.chosen_pack_size, v.chosen_pack_cost,
         0, 0, 0, 0, 0,
         (pm.promo_nr IS NOT NULL), pm.promo_nr, pm.start_date, pm.end_date, pm.promo_suffix, (pm.promo_nr IS NOT NULL AND pm.promo_suffix IS NULL), false, v.state_reason, v_gen,
         'hidden', true, v.state_reason, v.rate_raw_56d, v.rate_corrected_56d,
         v.rate_guard_56d, 56, v.days_removed_56d,
         v.observable_days, v.observable_share
  FROM public.l2_population_verdict v
  LEFT JOIN public.rpc_bloom_promo_for_delivery(p_store_code, p_route, v_del) pm ON pm.product_code = v.product_code LEFT JOIN public.v_ean_bridge b
         ON b.store_code = v.store_code AND b.product_code = v.product_code
  WHERE v.store_code = p_store_code AND v.route_key = p_route
    AND v.flag_hidden_seller
    AND NOT EXISTS (SELECT 1 FROM public.bloom_order_cache_line x
                     WHERE x.cache_id = v_cache_id AND x.product_code = v.product_code);
  GET DIAGNOSTICS v_appended = ROW_COUNT;

  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;

  -- ENG-106 leg (b) / SSD6.1 clause 2: freeze the benchmark AND its anchor onto
  -- the artefact. The ONE HOME computes it; this never re-derives the basis.
  SELECT b.anchor_date, b.weekly_cost_demand INTO v_bm_anchor, v_bm_weekly
  FROM public.rpc_bloom_route_benchmark(p_store_code, p_route, NULL) b;

  UPDATE public.bloom_order_cache_line
     SET line_kind = 'covered'
   WHERE cache_id = v_cache_id
     AND line_kind = 'ordered'
     AND coalesce(suggested_packs, 0) = 0
     AND range_state IN ('CORE', 'HERO')
     AND soh <= min_band
     -- A line kept for its OWN reason keeps that identity. Tagging a
     -- count-first or minimum-presence line 'covered' would let the label say
     -- "no action" about a line that needs one (ENG-123: a display value must
     -- name its own population).
     AND NOT (coalesce(count_first,false) OR coalesce(keep_or_delist,false)
              OR coalesce(pack_forced_review,false) OR coalesce(min_presence_forced,false))
     -- ENG-102 correction: a withheld-correction line is a HIDDEN SELLER and keeps
     -- that identity. Before ENG-102 it was appended as line_kind='hidden' and the
     -- buyer saw it flagged DROPPED. The covered tag must never claim it.
     AND NOT coalesce(withheld_correction, false);

  UPDATE public.bloom_order_cache
     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)
                                       FROM public.bloom_order_cache_line
                                      WHERE cache_id = v_cache_id
                                        AND line_kind = 'covered'),
         hidden_line_count  = v_flagged + v_appended,
         generation_ms      = v_ms,
         benchmark_anchor_date   = v_bm_anchor,
         benchmark_weekly_demand = v_bm_weekly
   WHERE cache_id=v_cache_id;

  RETURN jsonb_build_object('status','ok','cache_id',v_cache_id,
                            'lines',v_n + v_appended,
                            'ordered_lines',v_n,
                            'hidden_flagged_in_place',v_flagged,
                            'hidden_appended',v_appended,
                            'generation_ms',v_ms,'delivery',v_del,'next_delivery',v_next,
                            'engine_md5',v_md5);
END $function$
