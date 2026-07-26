-- =============================================================================
-- create_l2_link_codes_queue.sql
-- IDENTITY PHASE 2 (CANON SS17, SS8.12 #5) -- THE LINK_CODES CANDIDATE QUEUE.
-- Applied 2026-07-26, migrations phase2_03_l2_link_codes_queue_candidates_only
-- + phase2_04_link_codes_queue_perf_store_scoped_ctes.
-- Owner: CC. Item-12 INDEPENDENT (it PROPOSES; it resolves nothing).
-- =============================================================================
-- Canon SS8.12 #5 named this object in 2026-06-12 and it was never created.
-- Its absence is why ENG-020 leg 2 could not pass its own stated gate -- canon
-- requires the queue to be NON-EMPTY or leg 2 has failed silently -- which in
-- turn blocked PREDICT-001 step 3.
--
-- ⭐⭐ THE HOLD IS STRUCTURAL, NOT A PROMISE (PM ruling 2026-07-26).
--   * `status` is CHECK-constrained to exactly 'CANDIDATE'.
--   * There is no keeper column, no verdict column, no resolution column, and no
--     write path that can resolve a pair.
--   * PROVEN at build: an UPDATE to status='RESOLVED' was rejected by the CHECK,
--     and all 6,698 rows remain CANDIDATE.
-- HOW a queued family/successor pair actually resolves -- through the observation
-- channel, with the database deciding on a deterministic rule -- is the item-12
-- CANDIDATE, PM's to churn (Pieter's principle: the DATABASE decides; resolving
-- it by letting a normal user amend the database is NOT ALLOWED). Widening this
-- CHECK is the deliberate act that opens that step. It cannot happen by accident.
--
-- The engine proposes with evidence and a story (R29). It decides nothing.
--
-- THREE CANDIDATE CLASSES, all deterministic and all item-12-independent:
--
-- 1. SHARED_EAN -- two products in ONE store resolving to the SAME barcode.
--    Sigma's own code is the evidence. This is the recode/successor signature,
--    verified by inspection 2026-07-26: same description, same pack_content, a
--    newer high product_code shadowing an older one (SALITOS TEQUILA 330ML
--    104225/144712, JW BLACK 200ML 135017/144937, LUCKY STAR CORNED MEAT CHILLI
--    128063/144925). WHICH code is the keeper is NOT answered here.
--
-- 2. PACK_FAMILY -- canon's parent-child rule with ALL FIVE guards: same store,
--    same merch_group_nr, same description ROOT with pack tokens stripped
--    ANYWHERE (not merely as a suffix -- the SAVANNA C/PACK 12PK and AMSTEL
--    CRATE/BOTTLE lesson), same pack_content (the content guard: 500ML vs 1LT are
--    independent SKUs, never a family), and one side carrying a pack token while
--    the other does not. The sell-price ratio rides as evidence of the multiple N.
--    Membership and N are PROPOSED; nothing is linked.
--
-- 3. ABSENT_FROM_DBREFE -- the COKE ZERO class named in CANON SS17: a product
--    that TRADES (holds stock or sold in 91d) but Sigma holds no scannable code
--    for it at all. It can never key a TLX and no decoder can invent one, so
--    canon routes it to Phase-2 LINK_CODES, never to an export. Surfaced here so
--    it stops being invisible.
--
-- LIVE AT BUILD (2026-07-26): 6,698 candidates, all CANDIDATE, 0 resolved.
--   store   total  shared_ean  pack_family  absent_from_dbrefe
--   10116   1,975          44          865               1,066
--   21355   1,138           8        1,058                  72
--   80175   1,519           2          877                 640
--   80176     982          10          879                  93
--   80579   1,084           2        1,046                  36
--
-- PERF NOTE (earned, not guessed). The first version ran >3m30s across 5 stores
-- in one transaction and was cancelled (nothing committed). Root cause, verified
-- against the catalog: the unique indexes on l2_stock_position and
-- l2_rate_of_sale both LEAD WITH client_id -- (client_id, store_code,
-- product_code) -- so joining on (store_code, product_code) alone cannot use
-- them and each lookup degraded into a scan of a 69k-row matview, repeated. Fix:
-- materialise ONE store-scoped slice of each matview into a temp table up front
-- and hash-join against that. Same candidates, seconds not minutes. This is the
-- same discipline as the documented index traps -- respect the leading column.
-- The explicit DROP of each temp table at the end is required because
-- ON COMMIT DROP does not fire between calls inside one transaction (the
-- documented l2_sales_budget collision).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_link_codes_queue (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id            text        NOT NULL DEFAULT 'socialbrand',
  store_code           text        NOT NULL,
  candidate_type       text        NOT NULL
    CHECK (candidate_type IN ('SHARED_EAN','PACK_FAMILY','ABSENT_FROM_DBREFE')),
  group_key            text        NOT NULL,          -- what binds the candidate set together
  subject_product_code bigint      NOT NULL,
  related_product_code bigint,                        -- NULL for single-subject candidates
  evidence             jsonb       NOT NULL,          -- the numbers a human would be shown
  story                text        NOT NULL,          -- R29, plain language
  confidence           numeric     CHECK (confidence BETWEEN 0 AND 1),
  status               text        NOT NULL DEFAULT 'CANDIDATE'
    CHECK (status = 'CANDIDATE'),                     -- ⭐ the structural item-12 hold
  engine_version       text        NOT NULL DEFAULT 'phase2-v1',
  detected_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.l2_link_codes_queue IS
  'Identity Phase 2 (CANON SS17, SS8.12 #5). Engine-detected family / successor / absent-identity CANDIDATES with evidence and a story. RESOLVES NOTHING: status is CHECK-locked to CANDIDATE and the table carries no keeper/verdict column. The resolution mechanism is the item-12 candidate held for PM churn (2026-07-26); widening the CHECK is the deliberate act that opens it. Feeds ENG-020 leg 2s non-empty gate.';

CREATE INDEX IF NOT EXISTS l2_link_codes_queue_store_type_idx ON public.l2_link_codes_queue (store_code, candidate_type);
CREATE INDEX IF NOT EXISTS l2_link_codes_queue_group_idx      ON public.l2_link_codes_queue (store_code, group_key);
CREATE INDEX IF NOT EXISTS l2_link_codes_queue_subject_idx    ON public.l2_link_codes_queue (store_code, subject_product_code);

ALTER TABLE public.l2_link_codes_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_link_codes_queue_read ON public.l2_link_codes_queue;
CREATE POLICY l2_link_codes_queue_read ON public.l2_link_codes_queue FOR SELECT USING (true);
GRANT SELECT ON public.l2_link_codes_queue TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_link_codes_queue(p_store text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_shared int; v_family int; v_absent int;
BEGIN
  DELETE FROM l2_link_codes_queue WHERE store_code = p_store;

  -- store-scoped slices, built once (the perf fix -- see header)
  CREATE TEMP TABLE IF NOT EXISTS _q_pos (product_code bigint PRIMARY KEY, soh numeric, capital_value numeric) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS _q_ros (product_code bigint PRIMARY KEY, daily_ros_91d numeric, last_sale_date date, sales_qty_91d numeric) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS _q_art (product_code bigint PRIMARY KEY, description text, pack_content text,
                                          merch_group_nr int, sell_price_incl_vat numeric, record_stock_qty smallint) ON COMMIT DROP;
  DELETE FROM _q_pos; DELETE FROM _q_ros; DELETE FROM _q_art;

  INSERT INTO _q_pos SELECT product_code, soh, capital_value FROM l2_stock_position WHERE store_code = p_store;
  INSERT INTO _q_ros SELECT product_code, daily_ros_91d, last_sale_date, sales_qty_91d FROM l2_rate_of_sale WHERE store_code = p_store;
  INSERT INTO _q_art SELECT product_code, description, pack_content, merch_group_nr, sell_price_incl_vat, record_stock_qty
                     FROM sigma_articles WHERE store_code = p_store;
  ANALYZE _q_pos; ANALYZE _q_ros; ANALYZE _q_art;

  -- ---------------------------------------------------------------- SHARED_EAN
  INSERT INTO l2_link_codes_queue
    (store_code, candidate_type, group_key, subject_product_code, related_product_code,
     evidence, story, confidence)
  SELECT r.store_code, 'SHARED_EAN', r.ean, r.product_code, o.product_code,
         jsonb_build_object(
           'shared_ean', r.ean, 'ean_source', r.ean_source,
           'subject', jsonb_build_object('product_code', r.product_code, 'description', a.description,
             'pack_content', a.pack_content, 'sell', a.sell_price_incl_vat,
             'record_stock_qty', a.record_stock_qty, 'soh', sp.soh,
             'last_sale_date', rs.last_sale_date, 'in_articles', r.in_articles),
           'related', jsonb_build_object('product_code', o.product_code, 'description', b.description,
             'pack_content', b.pack_content, 'sell', b.sell_price_incl_vat,
             'record_stock_qty', b.record_stock_qty, 'soh', sq.soh,
             'last_sale_date', rt.last_sale_date, 'in_articles', o.in_articles),
           'same_description', (a.description IS NOT NULL AND a.description = b.description),
           'same_pack_content', (a.pack_content IS NOT DISTINCT FROM b.pack_content)),
         format('Two codes at this store resolve to the same barcode %s: %s (%s) and %s (%s). Same barcode means Sigma holds one physical identity on two codes -- typically a recode where the newer code shadows the older. Which code is the keeper is not decided here.',
                r.ean, r.product_code, COALESCE(a.description,'absent from sigma_articles'),
                o.product_code, COALESCE(b.description,'absent from sigma_articles')),
         CASE WHEN a.description = b.description AND a.pack_content IS NOT DISTINCT FROM b.pack_content THEN 0.90
              WHEN a.description = b.description THEN 0.75 ELSE 0.50 END
  FROM l2_ean_resolved r
  JOIN l2_ean_resolved o ON o.store_code=r.store_code AND o.ean=r.ean AND o.product_code<>r.product_code
  LEFT JOIN _q_art a ON a.product_code=r.product_code
  LEFT JOIN _q_art b ON b.product_code=o.product_code
  LEFT JOIN _q_pos sp ON sp.product_code=r.product_code
  LEFT JOIN _q_pos sq ON sq.product_code=o.product_code
  LEFT JOIN _q_ros rs ON rs.product_code=r.product_code
  LEFT JOIN _q_ros rt ON rt.product_code=o.product_code
  WHERE r.store_code=p_store AND r.ean_shared AND r.ean IS NOT NULL;
  GET DIAGNOSTICS v_shared = ROW_COUNT;

  -- --------------------------------------------------------------- PACK_FAMILY
  WITH norm AS MATERIALIZED (
    SELECT a.product_code, a.description, a.pack_content, a.merch_group_nr,
           a.sell_price_incl_vat, a.record_stock_qty,
           trim(regexp_replace(regexp_replace(upper(a.description),
             '(_[0-9]+|[0-9]+\s*PK\y|C/PACK|CRATE|CASE|\yPACK\y|\yBOT\y)', ' ', 'g'),
             '\s+', ' ', 'g')) AS root,
           (upper(a.description) ~ '(_[0-9]+|[0-9]+\s*PK\y|C/PACK|CRATE|CASE|\yPACK\y)') AS has_pack_token
    FROM _q_art a
    WHERE a.description IS NOT NULL AND a.merch_group_nr IS NOT NULL AND a.pack_content IS NOT NULL
  ),
  fam AS MATERIALIZED (
    SELECT root, merch_group_nr, pack_content
    FROM norm GROUP BY root, merch_group_nr, pack_content
    HAVING count(*) > 1 AND bool_or(has_pack_token) AND bool_or(NOT has_pack_token) AND length(root) >= 6
  )
  INSERT INTO l2_link_codes_queue
    (store_code, candidate_type, group_key, subject_product_code, related_product_code,
     evidence, story, confidence)
  SELECT p_store, 'PACK_FAMILY',
         p.merch_group_nr || '|' || p.pack_content || '|' || p.root,
         p.product_code, c.product_code,
         jsonb_build_object('root', p.root, 'merch_group_nr', p.merch_group_nr, 'pack_content', p.pack_content,
           'pack_side',   jsonb_build_object('product_code', p.product_code, 'description', p.description,
                            'sell', p.sell_price_incl_vat, 'record_stock_qty', p.record_stock_qty,
                            'soh', sp.soh, 'daily_ros', rp.daily_ros_91d),
           'single_side', jsonb_build_object('product_code', c.product_code, 'description', c.description,
                            'sell', c.sell_price_incl_vat, 'record_stock_qty', c.record_stock_qty,
                            'soh', sc.soh, 'daily_ros', rc.daily_ros_91d),
           'sell_price_ratio', CASE WHEN c.sell_price_incl_vat > 0
                                    THEN round(p.sell_price_incl_vat / c.sell_price_incl_vat, 3) END),
         format('%s (%s) carries a pack token and %s (%s) does not, sharing root "%s", merch group %s and pack content %s. Price ratio %s suggests the pack multiple. Membership and the multiplier N are proposed, not confirmed.',
                p.product_code, p.description, c.product_code, c.description, p.root,
                p.merch_group_nr, p.pack_content,
                COALESCE(round(p.sell_price_incl_vat / NULLIF(c.sell_price_incl_vat,0), 2)::text,'n/a')),
         0.60
  FROM norm p
  JOIN fam f  ON f.root=p.root AND f.merch_group_nr=p.merch_group_nr AND f.pack_content=p.pack_content
  JOIN norm c ON c.root=p.root AND c.merch_group_nr=p.merch_group_nr AND c.pack_content=p.pack_content
             AND NOT c.has_pack_token
  LEFT JOIN _q_pos sp ON sp.product_code=p.product_code
  LEFT JOIN _q_pos sc ON sc.product_code=c.product_code
  LEFT JOIN _q_ros rp ON rp.product_code=p.product_code
  LEFT JOIN _q_ros rc ON rc.product_code=c.product_code
  WHERE p.has_pack_token;
  GET DIAGNOSTICS v_family = ROW_COUNT;

  -- --------------------------------------------------------- ABSENT_FROM_DBREFE
  INSERT INTO l2_link_codes_queue
    (store_code, candidate_type, group_key, subject_product_code, related_product_code,
     evidence, story, confidence)
  SELECT p_store, 'ABSENT_FROM_DBREFE',
         COALESCE(a.merch_group_nr::text,'NO_GROUP'), r.product_code, NULL,
         jsonb_build_object('description', a.description, 'pack_content', a.pack_content,
           'merch_group_nr', a.merch_group_nr, 'soh', sp.soh, 'capital_value', sp.capital_value,
           'daily_ros_91d', rs.daily_ros_91d, 'last_sale_date', rs.last_sale_date,
           'sales_qty_91d', rs.sales_qty_91d, 'ean_source', r.ean_source,
           'real_code_count', r.real_code_count),
         format('%s (%s) trades but Sigma holds no scannable code for it (ean_source %s). It cannot key a TLX and no decoder can invent one, so it needs a LINK_CODES identity decision, not an export.',
                r.product_code, COALESCE(a.description,'no description'), r.ean_source),
         0.95
  FROM l2_ean_resolved r
  LEFT JOIN _q_art a ON a.product_code=r.product_code
  LEFT JOIN _q_pos sp ON sp.product_code=r.product_code
  LEFT JOIN _q_ros rs ON rs.product_code=r.product_code
  WHERE r.store_code=p_store AND NOT r.is_real
    AND (COALESCE(sp.soh,0) <> 0 OR COALESCE(rs.sales_qty_91d,0) > 0);
  GET DIAGNOSTICS v_absent = ROW_COUNT;

  DROP TABLE IF EXISTS _q_pos; DROP TABLE IF EXISTS _q_ros; DROP TABLE IF EXISTS _q_art;

  RETURN jsonb_build_object('store_code', p_store,
    'shared_ean', v_shared, 'pack_family', v_family, 'absent_from_dbrefe', v_absent,
    'total', v_shared + v_family + v_absent,
    'resolved', 0, 'note', 'candidates only -- resolution held for the item-12 ruling',
    'refreshed_at', now());
END $fn$;

-- R30 addendum extension: mutating function -> REVOKE from PUBLIC *and* anon.
REVOKE ALL     ON FUNCTION public.refresh_l2_link_codes_queue(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_link_codes_queue(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_link_codes_queue(text) TO authenticated;

-- Wired into refresh_l2_pipeline directly after refresh_l2_ean_resolved.
-- See sql/create_refresh_l2_pipeline.sql.
