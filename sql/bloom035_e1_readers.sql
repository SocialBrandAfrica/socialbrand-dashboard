-- =============================================================================
-- BLOOM-035 E1, part 3 -- THE TWO OTHER CACHE READERS WITHHOLD 'unordered' ROWS TOO.
-- Checked 14-10-2026 against every function that reads bloom_order_cache_line (7 in pg_proc):
--   rpc_bloom_delivery_chain, rpc_bloom_month_projection  count suggested_packs > 0 and sum value: a 0/0 row changes nothing.
--   rpc_bloom_promo_floor_gap                             filters promo_in_window and promo_floor_units IS NOT NULL: the new rows carry NULL there.
--   rpc_bloom_order_cached                                patched in sql/bloom035_e1_cache_rows.sql (the served payload).
--   rpc_bloom_pool_search                                 on_sheet was "<> 'covered'": an unordered row would read as ON the sheet while the
--                                                         served sheet withholds it. Now false for 'covered' and 'unordered'.
--   rpc_bloom_stored_overview                             the card counted every line but 'covered': 12,000 zero rows would have inflated
--                                                         `lines` on a DC desk. Both aggregates (2 occurrences) now exclude 'unordered'.
-- Asserted replace on each live definition. REVERSE: replace "NOT IN ('covered', 'unordered')" by "<> 'covered'" in
-- pool_search, and "COALESCE(l.line_kind, '') NOT IN ('covered', 'unordered')" by "l.line_kind IS DISTINCT FROM 'covered'"
-- (twice) in stored_overview.
-- =============================================================================

DO $mig$
DECLARE
  def text;
  n int;
BEGIN
  def := pg_get_functiondef('public.rpc_bloom_pool_search(text, text, text, integer)'::regprocedure);
  n := (length(def) - length(replace(def, $a$AND COALESCE(l.line_kind, '') <> 'covered')$a$, ''))) / length($a$AND COALESCE(l.line_kind, '') <> 'covered')$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'pool_search anchor found % times', n; END IF;
  def := replace(def, $a$AND COALESCE(l.line_kind, '') <> 'covered')$a$, $b$AND COALESCE(l.line_kind, '') NOT IN ('covered', 'unordered'))$b$);
  EXECUTE def;

  def := pg_get_functiondef('public.rpc_bloom_stored_overview(text, text, date, date, text, numeric)'::regprocedure);
  n := (length(def) - length(replace(def, $a$l.line_kind IS DISTINCT FROM 'covered'$a$, ''))) / length($a$l.line_kind IS DISTINCT FROM 'covered'$a$);
  IF n <> 2 THEN RAISE EXCEPTION 'stored_overview anchor found % times, expected 2', n; END IF;
  def := replace(def, $a$l.line_kind IS DISTINCT FROM 'covered'$a$, $b$COALESCE(l.line_kind, '') NOT IN ('covered', 'unordered')$b$);
  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
