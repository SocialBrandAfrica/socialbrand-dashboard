-- =============================================================================
-- BLOOM-035 s34 (PM 14-10-2026 16:55): "R282k a week of demand on lines with no DC link at 10116, and 57% at 21355".
--
--   READ (14-10 17:2x SAST, 10116 DC ambient departments, 28 days to the 13-10 watermark, cost per week): the departments sell R809k a week. R527k sits in the DC ambient pool
--   (5,290 lines). The R282k "outside the pool" is NOT lines with no supplier link. It is R139k on the brand desks (702 lines), R60k on the derived supplier desks (1,056 lines),
--   R0.4k on the catch-all desk and R82k with no desk at all (377 lines). Of that R82k, R69k is NON_STOCK lines (70 of them, R57k, are buy-and-sell lines with a stopped DC link, all at
--   zero stock) and about R13k is stock lines with no desk (209 lines). The label "no active DC supplier link, ENG-008" on the Stock now card was therefore wrong for 85 per cent of it.
--
--   WHAT THIS CHANGES: rpc_bloom_stock_state returns, in weekly_demand_gap_label (text, the column that carried the constant 'no_active_dc_route'), WHERE the outside demand is ordered:
--   "on a brand desk R139,449 (702 lines), on a supplier desk R60,300 (1,056 lines), ...". Columns, types and the signature are unchanged. The page line is reworded in the same release.
--
-- Asserted replace on the live definition, pinned on md5(prosrc) 2ab5d21304d05bf203b40ea9f7c38ea6 (5,588 chars). One count assertion per anchor.
-- REVERSE: put 'no_active_dc_route' back and remove the gapmix CTE.
-- =============================================================================

SET lock_timeout = '5s';

CREATE FUNCTION pg_temp.rp(p_def text, p_from text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: anchor [%] found % time(s), expected %', p_what, left(p_from, 70), n, p_expect;
  END IF;
  RETURN replace(p_def, p_from, p_to);
END $f$;

DO $mig$
DECLARE
  def text; v_live text;
BEGIN
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_bloom_stock_state';
  IF v_live IS DISTINCT FROM '2ab5d21304d05bf203b40ea9f7c38ea6' THEN RAISE EXCEPTION 'pin failed: live md5 % is not 2ab5d213', v_live; END IF;

  def := pg_get_functiondef('public.rpc_bloom_stock_state(text, text)'::regprocedure);

  def := pg_temp.rp(def, $a$    LEFT JOIN pool_run   pr ON pr.product_code = s.product_code
  )
  SELECT g.grp, g.lines::int, g.selling_lines::int,$a$,
                         $b$    LEFT JOIN pool_run   pr ON pr.product_code = s.product_code
  ),
  -- BLOOM-035 s34: WHERE the demand outside this desk's pool is ordered (the gap is not "no DC link").
  gapmix AS (
    SELECT COALESCE(string_agg(b.bucket || ' R' || to_char(round(b.wk), 'FM999G999G999') || ' (' || b.n || ' lines)', ', ' ORDER BY b.ord), 'none') AS label
      FROM (
        SELECT x.bucket, x.ord, SUM(x.wk) AS wk, count(*) AS n
          FROM (
            SELECT s2.cost28 / 4.0 AS wk,
                   (CASE WHEN v.route_key = 'DC_FRESH' THEN 'on the DC fresh desk'
                         WHEN v.route_key = 'DIRECT_CATCHALL' THEN 'on the catch-all desk'
                         WHEN v.route_key = 'DIRECT_BEER' THEN 'on the beer desk'
                         WHEN v.route_key ~ '^DIRECT_S[0-9]+$' THEN 'on a supplier desk'
                         WHEN v.route_key LIKE 'DIRECT\_%' ESCAPE '\' THEN 'on a brand desk'
                         WHEN v.route_key IS NOT NULL THEN 'on another desk'
                         WHEN spx.class = 'NON_STOCK' THEN 'non-stock lines, never ordered'
                         ELSE 'stock lines on no desk' END) AS bucket,
                   (CASE WHEN v.route_key = 'DC_FRESH' THEN 1
                         WHEN v.route_key LIKE 'DIRECT\_%' ESCAPE '\' AND v.route_key !~ '^DIRECT_S[0-9]+$' AND v.route_key NOT IN ('DIRECT_CATCHALL', 'DIRECT_BEER') THEN 2
                         WHEN v.route_key ~ '^DIRECT_S[0-9]+$' THEN 3
                         WHEN v.route_key = 'DIRECT_CATCHALL' THEN 4
                         WHEN v.route_key = 'DIRECT_BEER' THEN 5
                         WHEN v.route_key IS NOT NULL THEN 6
                         WHEN spx.class = 'NON_STOCK' THEN 7
                         ELSE 8 END) AS ord
              FROM sales28 s2
              JOIN dept_scope ds2 ON ds2.product_code = s2.product_code
              LEFT JOIN pool_run pr2 ON pr2.product_code = s2.product_code
              LEFT JOIN l2_population_verdict v ON v.store_code = p_store_code AND v.product_code = s2.product_code
              LEFT JOIN l2_stock_position spx ON spx.store_code = p_store_code AND spx.product_code = s2.product_code
             WHERE pr2.product_code IS NULL AND s2.cost28 > 0
          ) x
         GROUP BY x.bucket, x.ord
      ) b
  )
  SELECT g.grp, g.lines::int, g.selling_lines::int,$b$, 1, 'gapmix cte');

  def := pg_temp.rp(def, $a$(SELECT gap_n FROM totals)::int, 'no_active_dc_route', v_now$a$,
                         $b$(SELECT gap_n FROM totals)::int, (SELECT gm.label FROM gapmix gm), v_now$b$, 1, 'gap label');

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
