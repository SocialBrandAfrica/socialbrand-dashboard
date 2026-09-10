-- ENG-183 (B) -- the desk split by receipts, RECIPE half. APPLY ONLY AFTER (A) AND AFTER
-- refresh_l2_population_verdict HAS RUN FOR ALL FIVE STORES. Quantity-bearing: per-store R22 on every desk.
-- rpc_bloom_order_recipe 70d99c33906f4e69fc243d1de9fbfeb0 -> c085128d9b767e471bf4d4d05924db22
-- Generated 2026-09-10 by CC from the md5-verified live body; the patch asserts exactly one match.

DO $eng183r$
DECLARE
  src text;
  k int;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe') <> 1 THEN RAISE EXCEPTION 'rpc_bloom_order_recipe: overloads <> 1'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe';
  IF md5(src) <> '70d99c33906f4e69fc243d1de9fbfeb0' THEN RAISE EXCEPTION 'rpc_bloom_order_recipe: live pin is %, expected 70d99c33906f4e69fc243d1de9fbfeb0', md5(src); END IF;
  k := (length(src) - length(replace(src, $o1$COALESCE(rs.range_state,'') <> 'EXCLUDED'
$o1$, ''))) / length($o1$COALESCE(rs.range_state,'') <> 'EXCLUDED'
$o1$);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_order_recipe patch 1 matched % times', k; END IF;
  src := replace(src, $o1$COALESCE(rs.range_state,'') <> 'EXCLUDED'
$o1$, $n1$COALESCE(rs.range_state,'') <> 'EXCLUDED'
        -- ENG-183 (ORDERING-CANON SSA2): a product linked on more than one desk rides ONLY the desk the
        -- population verdict assigned it by receipts. No verdict row, no change (R33 clause 3).
        AND NOT EXISTS (SELECT 1 FROM l2_population_verdict pv WHERE pv.store_code=%1$L AND pv.product_code=b.product_code AND pv.route_overlap AND pv.route_key IS DISTINCT FROM %15$L::text)
$n1$);
  IF md5(src) <> 'c085128d9b767e471bf4d4d05924db22' THEN RAISE EXCEPTION 'rpc_bloom_order_recipe: patched text md5 is %, expected c085128d9b767e471bf4d4d05924db22', md5(src); END IF;
  EXECUTE src;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe';
  IF md5(src) <> 'c085128d9b767e471bf4d4d05924db22' THEN RAISE EXCEPTION 'rpc_bloom_order_recipe: installed pin is %, expected c085128d9b767e471bf4d4d05924db22', md5(src); END IF;
END $eng183r$;
