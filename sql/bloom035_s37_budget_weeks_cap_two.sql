-- BLOOM-035 s37 (PM 14-10-2026 21:15, Pieter B4): measured weekly = one budget week, not weekly = two budget weeks, never more.
-- The recipe's fit window read GREATEST(1, CEIL(gap/7)) weeks: 18 derived desks with a 21 to 63 day gap to the next delivery read 3 to 9 weeks
-- (DIRECT_S3 at 80175 nine, DIRECT_S1165 at 10116 eight). Capped at 2. A weekly desk and a desk with a gap of 7 or 14 days are unchanged.
-- APPLIED 14-10 21:3x SAST. Asserted replace of rpc_bloom_order_recipe, pinned to md5(pg_get_functiondef) 015bd16a540e6b74b03fc55aacfa771b, one overload.
-- Live md5 after: 362a817ee74b13a79833999ad9fb06f2. sql/create_rpc_bloom_order_recipe.sql line 489 carries the same one-line change.
-- It reaches the stored sheets at the next build (job 26, 01:30 SAST). Until then every stored sheet reads as an "earlier recipe" on the card, as after any recipe edit.
DO $m$
DECLARE
  d text; n int; oid_ oid;
  e1 constant text := 'AND obl.year_month < v_week_start + 7 * GREATEST(1, CEIL((v_next_delivery - p_delivery_date) / 7.0))::int;';
  r1 constant text := 'AND obl.year_month < v_week_start + 7 * LEAST(2, GREATEST(1, CEIL((v_next_delivery - p_delivery_date) / 7.0)))::int;';
BEGIN
  SELECT count(*) INTO n FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_bloom_order_recipe';
  IF n <> 1 THEN RAISE EXCEPTION 'rpc_bloom_order_recipe overloads: %', n; END IF;
  SELECT p.oid INTO oid_ FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_bloom_order_recipe';
  d := pg_get_functiondef(oid_);
  IF md5(d) <> '015bd16a540e6b74b03fc55aacfa771b' THEN
    IF position(r1 IN d) > 0 THEN RAISE NOTICE 'already patched'; RETURN; END IF;
    RAISE EXCEPTION 'recipe body moved: md5 %', md5(d);
  END IF;
  IF (length(d) - length(replace(d, e1, ''))) / length(e1) <> 1 THEN RAISE EXCEPTION 'e1 count'; END IF;
  d := replace(d, e1, r1);
  EXECUTE d;
END
$m$;
