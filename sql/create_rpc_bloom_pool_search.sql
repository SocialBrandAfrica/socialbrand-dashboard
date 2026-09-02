-- =============================================================================
-- create_rpc_bloom_pool_search.sql
-- SB-CC-BLOOM-029 item 8(a) -- search the POOL, not the sheet.
-- =============================================================================
-- WHY THIS EXISTS. Pieter, 01-09-2026: he hunted four products on the order
-- screen and found none of them. Measured (brief F10): at 10116 DC_AMBIENT the
-- pool is 12,869 lines and the sheet is 1,688 (1,131 ordered + 557 hidden), so
-- 11,181 pool lines are UNREACHABLE from the screen. The engine is right to
-- leave most of them off an order. It is not right that the buyer cannot LOOK
-- one up.
--
-- The search therefore runs over `l2_population_verdict` -- the pool -- and
-- NEVER over `bloom_order_cache_line` -- the sheet. Searching the sheet would
-- reproduce the defect it exists to cure (brief F10, explicit).
--
-- SIGNATURE
--   rpc_bloom_pool_search(p_store_code text, p_route text, p_query text,
--                         p_limit int DEFAULT 50) RETURNS jsonb
--
-- RETURNS jsonb, NEVER SETOF (ENG-093). A SETOF reader crossing 1,000 rows is
-- silently truncated by PostgREST at 206 Partial Content, and this one is
-- explicitly capped and reports its own cap, so a short read cannot pass as a
-- complete one. `matched` vs `returned` is the tripwire.
--
-- THREE MATCH BASES, and each row says which one answered (R29):
--   'product_code'  exact, the code typed straight in
--   'ean'           exact, via l2_ean_resolved (the native-first resolved
--                   identity, never product_catalog -- R25 section 2)
--   'description'   case-insensitive substring
--
-- SUBSTRING CONTAINMENT, NOT ILIKE, AND THAT IS DELIBERATE. A buyer typing a
-- product name containing % or _ would, under ILIKE, silently change the pattern
-- and return the wrong set with no error. `position(lower(q) in lower(d)) > 0`
-- has no metacharacters, so what the buyer typed is what is matched.
--
-- R21 SECTION 5 -- AN EXCLUSION IS EARNED AND SURFACED. A product that exists at
-- this store but sits on a DIFFERENT route is NOT returned in `results`, and it
-- is NOT silently dropped either: it comes back in `out_of_scope` with the route
-- that does carry it, so the buyer is told "that line is on another desk"
-- instead of being shown an empty box. That is the brief's own R22 condition.
--
-- ON THE SHEET OR NOT. Each hit reports whether the desk's most recent cached
-- sheet already carries it. `on_sheet` means SERVED to the screen; a line the
-- cache holds as line_kind='covered' reports on_sheet=false WITH
-- cache_line_kind='covered', because rpc_bloom_order_cached withholds covered
-- rows from the payload (ENG-102) -- so "not on your sheet, and here is why"
-- is the honest answer rather than a flat no.
--
-- Read routine: anon + authenticated EXECUTE, matching rpc_bloom_order_cached.
-- SECURITY DEFINER for the same reason rpc_bloom_hidden_demand carries it --
-- the facts it reads are not reachable as the caller.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_pool_search(
  p_store_code text,
  p_route      text,
  p_query      text,
  p_limit      int DEFAULT 50
)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH q AS (
    SELECT btrim(COALESCE(p_query, ''))          AS raw,
           lower(btrim(COALESCE(p_query, '')))   AS lq,
           GREATEST(1, LEAST(COALESCE(p_limit, 50), 200)) AS lim
  ),
  sheet AS (
    -- the desk's most recent cached sheet, whatever preset/fit the buyer last
    -- had built; membership is reported against that build and its stamp is
    -- returned so the answer names the artefact it was read from (R22)
    SELECT c.cache_id, c.generated_at, c.delivery_date, c.preset, c.fit_to_budget
    FROM public.bloom_order_cache c
    WHERE c.store_code = p_store_code AND c.route_key = p_route
    ORDER BY c.generated_at DESC
    LIMIT 1
  ),
  hit AS (
    SELECT v.*,
           e.ean,
           CASE
             WHEN q.raw <> '' AND v.product_code::text = q.raw THEN 'product_code'
             WHEN q.raw <> '' AND e.ean = q.raw                THEN 'ean'
             ELSE 'description'
           END AS match_basis,
           CASE
             WHEN q.raw <> '' AND v.product_code::text = q.raw THEN 0
             WHEN q.raw <> '' AND e.ean = q.raw                THEN 0
             WHEN q.lq  <> '' AND position(q.lq in lower(v.description)) = 1 THEN 1
             ELSE 2
           END AS rank_band
    FROM public.l2_population_verdict v
    CROSS JOIN q
    LEFT JOIN public.l2_ean_resolved e
           ON e.store_code = v.store_code AND e.product_code = v.product_code
    WHERE v.store_code = p_store_code
      AND v.route_key  = p_route
      AND char_length(q.raw) >= 2
      AND (
            v.product_code::text = q.raw
         OR e.ean                = q.raw
         OR position(q.lq in lower(COALESCE(v.description,''))) > 0
          )
  ),
  ranked AS (
    SELECT h.*, row_number() OVER (
             ORDER BY h.rank_band,
                      h.rate_published_56d DESC NULLS LAST,
                      h.product_code
           ) AS rn
    FROM hit h
  ),
  picked AS (
    SELECT r.* FROM ranked r, q WHERE r.rn <= q.lim
  ),
  results AS (
    SELECT jsonb_agg(jsonb_build_object(
             'product_code',        p.product_code,
             'description',         p.description,
             'dept_name',           p.dept_name,
             'ean',                 p.ean,
             'tier',                p.tier,
             'kvi_band',            p.kvi_band,
             'range_state',         p.range_state,
             'passes_life_gate',    p.passes_life_gate,
             'population_state',    p.population_state,
             'state_reason',        p.state_reason,
             'flag_hidden_seller',  p.flag_hidden_seller,
             'soh',                 p.soh,
             'soh_date',            p.soh_date,
             'rate_published_56d',  p.rate_published_56d,
             'chosen_pack_size',    p.chosen_pack_size,
             'chosen_pack_cost',    p.chosen_pack_cost,
             'chosen_is_zero_cost', p.chosen_is_zero_cost,
             'match_basis',         p.match_basis,
             -- Membership in the desk's latest cached sheet.
             -- `l.cache_id IS NOT NULL` is load-bearing: a product with NO cache
             -- row leaves line_kind NULL, and `NULL IS DISTINCT FROM 'covered'`
             -- is TRUE, so the obvious test reports every unmatched product as
             -- already on the sheet. Caught on the first live run -- 5 of 6 KOO
             -- lines at 80175 read on_sheet=true with no cache row behind them.
             'on_sheet',            (l.cache_id IS NOT NULL
                                     AND COALESCE(l.line_kind, '') <> 'covered'),
             'cache_line_kind',     l.line_kind,
             'cache_suggested_packs', l.suggested_packs
           ) ORDER BY p.rn) AS j
    FROM picked p
    LEFT JOIN sheet s ON true
    LEFT JOIN public.bloom_order_cache_line l
           ON l.cache_id = s.cache_id AND l.product_code = p.product_code
  ),
  oos AS (
    -- exists at this store, but not on THIS desk. Named, never silently dropped.
    SELECT jsonb_agg(jsonb_build_object(
             'product_code', x.product_code,
             'description',  x.description,
             'on_route',     x.route_key,
             'reason',       'Carried on the ' || x.route_key ||
                             ' desk at this store, not on ' || p_route || '.'
           ) ORDER BY x.product_code) AS j
    FROM (
      SELECT DISTINCT v.product_code, v.description, v.route_key
      FROM public.l2_population_verdict v
      CROSS JOIN q
      LEFT JOIN public.l2_ean_resolved e
             ON e.store_code = v.store_code AND e.product_code = v.product_code
      WHERE v.store_code = p_store_code
        AND v.route_key IS DISTINCT FROM p_route
        AND char_length(q.raw) >= 2
        AND (
              v.product_code::text = q.raw
           OR e.ean                = q.raw
           OR position(q.lq in lower(COALESCE(v.description,''))) > 0
            )
      LIMIT 10
    ) x
  )
  SELECT jsonb_build_object(
    'store_code', p_store_code,
    'route',      p_route,
    'query',      (SELECT raw FROM q),
    'limit',      (SELECT lim FROM q),
    -- R22 tripwire: matched is the full population, returned is what came back.
    'matched',    (SELECT count(*) FROM hit),
    'returned',   (SELECT count(*) FROM picked),
    'truncated',  (SELECT count(*) FROM hit) > (SELECT count(*) FROM picked),
    'sheet',      (SELECT to_jsonb(s) FROM sheet s),
    'results',    COALESCE((SELECT j FROM results), '[]'::jsonb),
    'out_of_scope', COALESCE((SELECT j FROM oos), '[]'::jsonb),
    'message',    CASE
                    WHEN char_length((SELECT raw FROM q)) < 2
                      THEN 'Type at least two characters.'
                    WHEN (SELECT count(*) FROM hit) = 0
                     AND (SELECT count(*) FROM oos WHERE j IS NOT NULL) > 0
                      THEN 'Nothing on this desk. See out_of_scope for the desk that carries it.'
                    WHEN (SELECT count(*) FROM hit) = 0
                      THEN 'No line on this desk matches that code, barcode or description.'
                    ELSE NULL
                  END
  );
$function$;

COMMENT ON FUNCTION public.rpc_bloom_pool_search(text, text, text, int) IS
'GRADE: CALCULATED. SB-CC-BLOOM-029 item 8(a). Searches the DESK POOL (l2_population_verdict), never the cached sheet -- the sheet reaches ~13 per cent of the pool (brief F10) and searching it would reproduce the defect. Matches on product_code, resolved EAN (l2_ean_resolved) or description substring; each row says which basis answered (R29) and whether the desk''s latest cached sheet already carries it. A hit on another route comes back in out_of_scope with the desk that carries it, never silently dropped (R21 section 5). jsonb not SETOF (ENG-093), capped, and reports matched vs returned so a short read cannot pass as a complete one.';

-- Grants stated explicitly in the create file (R30 addendum). Read routine.
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_pool_search(text, text, text, int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_pool_search(text, text, text, int) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
