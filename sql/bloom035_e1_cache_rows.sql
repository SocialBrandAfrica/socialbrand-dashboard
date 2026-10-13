-- =============================================================================
-- BLOOM-035 E1, part 2 -- THE SHEET CARRIES THE ROWS. refresh_bloom_order_cache appends the 'unordered'
-- rows of l2_received_placement (STEP 3b), and rpc_bloom_order_cached withholds them from the served
-- payload until the desk can render them (the ENG-102 precedent for 'covered' rows).
-- Both functions are patched by an ASSERTED REPLACE on the live definition (each anchor must occur exactly
-- once or the whole migration raises), so nothing else in either body can move. Sources of record: the
-- live bodies; the rollback copies are sql/_archive/refresh_bloom_order_cache_pre_e1.sql and
-- sql/_archive/rpc_bloom_order_cached_pre_e1.sql.
-- =============================================================================

DO $mig$
DECLARE
  def text;
  n int;
BEGIN
  -- ---------------------------------------------------------------- refresh_bloom_order_cache
  def := pg_get_functiondef('public.refresh_bloom_order_cache(text, text, date, date, text, boolean, text)'::regprocedure);

  -- 1. two variables
  n := (length(def) - length(replace(def, $a$  v_bm_anchor date; v_bm_weekly numeric;
BEGIN$a$, ''))) / length($a$  v_bm_anchor date; v_bm_weekly numeric;
BEGIN$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'anchor 1 found % times', n; END IF;
  def := replace(def, $a$  v_bm_anchor date; v_bm_weekly numeric;
BEGIN$a$, $b$  v_bm_anchor date; v_bm_weekly numeric;
  v_unord int := 0; v_max_line2 int;
BEGIN$b$);

  -- 2. STEP 3b, before the timing line that closes the build
  n := (length(def) - length(replace(def, $a$  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;$a$, ''))) / length($a$  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'anchor 2 found % times', n; END IF;
  def := replace(def, $a$  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;$a$, $b$  -- STEP 3b, BLOOM-035 E1 (R7, PM ruling E1 of 13-10-2026, R32). Every product the LATEST GRV supplier of THIS
  -- desk delivered in the receipt window is on this sheet: as an order row, a covered row, a hidden seller,
  -- or HERE as an 'unordered' row with its reason (l2_received_placement, stocked nightly). Appended AFTER
  -- the recipe and after STEP 3, so no quantity moves and a hidden seller keeps its identity. The reader
  -- withholds these rows until the desk can show them (rpc_bloom_order_cached).
  SELECT COALESCE(MAX(line_no),0) INTO v_max_line2
    FROM public.bloom_order_cache_line WHERE cache_id = v_cache_id;

  INSERT INTO public.bloom_order_cache_line
    (cache_id, line_no, store_code, product_code, ean, description, dept_name, route,
     kvi_band, tier, range_state, soh, need_units, normal_packs, geared_packs, suggested_packs, value,
     count_first, story, generated_at, line_kind, withheld_correction, hidden_reason, placement_code)
  SELECT v_cache_id, v_max_line2 + row_number() OVER (ORDER BY rp.reason_code, rp.product_code),
         rp.store_code, rp.product_code,
         COALESCE(k.export_key, lpad(rp.store_code, 5, '0') || lpad(rp.product_code::text, 8, '0')),
         sp.description, sp.dept_name, p_route,
         pv.kvi_band, COALESCE(pv.tier, sp.tier), pv.range_state, COALESCE(pv.soh, sp.soh),
         0, 0, 0, 0, 0,
         false, rp.reason, v_gen, 'unordered', false, rp.reason, rp.reason_code
    FROM public.l2_received_placement rp
    LEFT JOIN public.l2_stock_position sp ON sp.store_code = rp.store_code AND sp.product_code = rp.product_code
    LEFT JOIN public.l2_population_verdict pv ON pv.store_code = rp.store_code AND pv.product_code = rp.product_code
    LEFT JOIN public.l2_export_key k ON k.store_code = rp.store_code AND k.product_code = rp.product_code
   WHERE rp.store_code = p_store_code AND rp.desk_route_key = p_route AND rp.state = 'DESK'
     AND NOT EXISTS (SELECT 1 FROM public.bloom_order_cache_line x
                      WHERE x.cache_id = v_cache_id AND x.product_code = rp.product_code);
  GET DIAGNOSTICS v_unord = ROW_COUNT;

  v_ms := (extract(epoch from (clock_timestamp()-v_t0))*1000)::int;$b$);

  -- 3. the header counts
  n := (length(def) - length(replace(def, $a$     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)$a$, ''))) / length($a$     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'anchor 3 found % times', n; END IF;
  def := replace(def, $a$     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)$a$, $b$     SET line_count         = v_n + v_appended + v_unord,
         unordered_line_count = v_unord,
         ordered_line_count = v_n - (SELECT count(*)$b$);

  -- 4. the return value
  n := (length(def) - length(replace(def, $a$                            'hidden_appended',v_appended,$a$, ''))) / length($a$                            'hidden_appended',v_appended,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'anchor 4 found % times', n; END IF;
  def := replace(def, $a$                            'hidden_appended',v_appended,$a$, $b$                            'hidden_appended',v_appended,
                            'unordered_appended',v_unord,$b$);
  def := replace(def, $a$                            'lines',v_n + v_appended,$a$, $b$                            'lines',v_n + v_appended + v_unord,$b$);
  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_bloom_order_cached
  def := pg_get_functiondef('public.rpc_bloom_order_cached(text, text, date, date, text, boolean)'::regprocedure);

  -- the two served filters (served count and the lines array): withhold covered AND unordered
  n := (length(def) - length(replace(def, $a$l.line_kind IS DISTINCT FROM 'covered'$a$, ''))) / length($a$l.line_kind IS DISTINCT FROM 'covered'$a$);
  IF n <> 2 THEN RAISE EXCEPTION 'reader anchor 1 found % times, expected 2', n; END IF;
  def := replace(def, $a$l.line_kind IS DISTINCT FROM 'covered'$a$, $b$COALESCE(l.line_kind, '') NOT IN ('covered', 'unordered')$b$);

  -- the header count names the population served
  n := (length(def) - length(replace(def, $a$    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),$a$, ''))) / length($a$    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'reader anchor 2 found % times', n; END IF;
  def := replace(def, $a$    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),$a$, $b$    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind IN ('covered', 'unordered')),
    -- BLOOM-035 E1: the stored sheet carries a row for every received product of this desk. The rows that are
    -- not orders are withheld here until the desk can group them, and the count names what was withheld.
    'unordered_withheld', (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                            WHERE l.line_kind = 'unordered'),$b$);
  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
