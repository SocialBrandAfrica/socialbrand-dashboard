CREATE OR REPLACE FUNCTION public.rpc_bloom_order_cached(p_store_code text, p_route text, p_delivery_date date DEFAULT NULL::date, p_next_delivery date DEFAULT NULL::date, p_preset text DEFAULT NULL::text, p_fit_to_budget boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH want AS (
    SELECT COALESCE(p_delivery_date, (SELECT nd.delivery_date  FROM public.rpc_bloom_next_deliveries(p_store_code,p_route) nd LIMIT 1)) AS del,
           COALESCE(p_next_delivery, (SELECT nd.following_date FROM public.rpc_bloom_next_deliveries(p_store_code,p_route) nd LIMIT 1)) AS nxt
  ), hdr AS (
    SELECT c.cache_id, c.generated_at, c.line_count, c.delivery_date, c.next_delivery
    FROM public.bloom_order_cache c, want w
    WHERE c.store_code=p_store_code AND c.route_key=p_route
      AND c.delivery_date=w.del AND c.next_delivery=w.nxt
      AND c.preset=COALESCE(p_preset,'standard') AND c.fit_to_budget=p_fit_to_budget
    ORDER BY c.generated_at DESC LIMIT 1
  ), avail AS (
    -- what IS cached on this desk, so a miss can name the alternatives rather
    -- than leaving the buyer to guess (R21 SS5, the exclusion carries its reason)
    SELECT c.delivery_date, c.next_delivery, c.preset, c.fit_to_budget,
           c.line_count, c.generated_at
    FROM public.bloom_order_cache c
    WHERE c.store_code=p_store_code AND c.route_key=p_route
      AND c.delivery_date >= CURRENT_DATE - 1
    ORDER BY c.delivery_date, c.preset, c.fit_to_budget
    LIMIT 12
  )
  SELECT jsonb_build_object(
    'found',        (SELECT count(*) FROM hdr) > 0,
    'status',       CASE WHEN (SELECT count(*) FROM hdr) > 0 THEN 'HIT' ELSE 'MISS' END,
    'generated_at', (SELECT generated_at FROM hdr),
    'delivery_date',(SELECT delivery_date FROM hdr),
    'next_delivery',(SELECT next_delivery FROM hdr),
    -- ENG-102: the covered rows are withheld from this payload until a surface
    -- can render them, so the count names the population actually served.
    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),
    'covered_withheld', (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                          WHERE l.line_kind = 'covered'),
    -- R22: the array length is reported beside the header's own count, so a
    -- mismatch between what was cached and what was served is visible, not silent.
    'served',       (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                     WHERE l.line_kind IS DISTINCT FROM 'covered'),
    'lines',        COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
                              FROM public.bloom_order_cache_line l
                              JOIN hdr ON hdr.cache_id=l.cache_id
                             WHERE l.line_kind IS DISTINCT FROM 'covered'), '[]'::jsonb),
    -- ENG-097 miss payload
    'requested',    (SELECT jsonb_build_object(
                       'store_code', p_store_code, 'route', p_route,
                       'delivery_date', w.del, 'next_delivery', w.nxt,
                       'preset', COALESCE(p_preset,'standard'),
                       'fit_to_budget', p_fit_to_budget) FROM want w),
    'available',    COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM avail a), '[]'::jsonb),
    'message',      CASE WHEN (SELECT count(*) FROM hdr) > 0 THEN NULL
                    ELSE (SELECT format(
                      'No cached order for %s on %s %s for delivery %s to %s. %s',
                      COALESCE(p_preset,'standard'), p_store_code, p_route,
                      w.del::text, w.nxt::text,
                      COALESCE(
                        (SELECT 'Cached on this desk: '||string_agg(DISTINCT a.delivery_date::text||' to '||a.next_delivery::text, ', ')||'.'
                           FROM avail a),
                        'Nothing is cached on this desk yet. The nightly rebuild runs 01:30 SAST.'))
                      FROM want w) END
  );
$function$
