-- =============================================================================
-- ENG-241 -- NORMALISED LINES (SB-CC-STOCKTAKE-001 v1.2 section 4)
--
-- A normalised line is a buy-and-sell line whose stock the ledger has been shown to track.
-- THE TEST (all config, nothing typed into code):
--   * two DIWAINV counts on two different days no more than stocktake_confirm_window_days
--     (60) apart (one count per day: a day with several postings is ONE count, the closing-day
--     unit, stocktake_count_days);
--   * a correction is "correct" when its size is no more than stocktake_normalised_tolerance_pct
--     of the LARGER of the stock before and after the count;
--   * entry view B (stocktake_normalised_strict = 0): the LATER count of the pair is correct.
--     Strict view A (= 1): both counts of the pair are correct.
-- A normalised line KEEPS its status. The date it qualified is the earliest count day at which
-- the test holds, derived from the count history since stocktake_history_start_yyyymmdd, so a
-- line does not drop out when its pair slides past the window. Every count on it AFTER that day
-- is measured shrinkage (units, and rand at the line's unit cost: cost_value is 0 on count
-- postings).
--
-- THE PANTRY (R32): refresh_l2_normalised stocks both tables, once a night, as the FIRST step of
-- refresh_l2_stocktake_draw (the confirmation list reads them), so the app and the toolkit read
-- one stocked fact. Config changes (tolerance, window, view) take effect at the next refresh.
--
--   l2_normalised_line   one row per (store, product) that has at least one count PAIR inside the
--                        window. min_var_b / min_var_a are the smallest qualifying sizes under
--                        each view, so the share at ANY tolerance reads straight off the table
--                        (the page shows 2 and 5 side by side). qualified_date is under the
--                        configured view and tolerance.
--   l2_normalised_count  the counts after qualification on normalised lines: measured shrinkage.
--
-- ROLLBACK: DROP both tables, refresh_l2_normalised and rpc_stocktake_normalised, restore
-- stocktake_not_normalised and refresh_l2_stocktake_draw from the earlier ENG-241 files.
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT v.k, '*', v.n, 'DEMO_CALIBRATION', DATE '2026-10-13', v.note
FROM (VALUES
  ('stocktake_history_start_yyyymmdd', 20260414::numeric,
   'RULING from SB-CC-STOCKTAKE-001 v1.2 section 4: the count history in the mirror starts on 14-04-2026, so the normalised state is derived from counts on or after this date (stored as yyyymmdd because forge_config carries numbers). Base rate unstatable. NOTE for PM: DIWAINV rows exist in the ledger back to 2025-08 at 10116, so the brief''s start date is narrower than the data. Change the value to widen it, then wait for the next nightly refresh.'),
  ('stocktake_normalised_compare_pct', 2::numeric,
   'SEED, UNDERIVED. The second tolerance the count page shows beside stocktake_normalised_tolerance_pct (PM''s 2%, Pieter''s 98%), so the effect of the choice is visible. Derivation owed once a quarter of count history exists.')
) AS v(k, n, note)
WHERE NOT EXISTS (
  SELECT 1 FROM public.forge_config f
  WHERE f.config_key = v.k AND f.store_format = '*' AND f.retired_on IS NULL
);

CREATE TABLE IF NOT EXISTS public.l2_normalised_line (
  store_code      text        NOT NULL,
  product_code    bigint      NOT NULL,
  count_days      integer     NOT NULL,
  min_var_b       numeric     NOT NULL,
  min_var_a       numeric     NOT NULL,
  qualified_date  date,
  prev_date       date,
  prev_var_pct    numeric,
  qual_var_pct    numeric,
  tolerance_pct   numeric     NOT NULL,
  strict          boolean     NOT NULL,
  window_days     integer     NOT NULL,
  refreshed_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);
CREATE INDEX IF NOT EXISTS l2_normalised_line_qualified ON public.l2_normalised_line (store_code, qualified_date);

CREATE TABLE IF NOT EXISTS public.l2_normalised_count (
  store_code    text    NOT NULL,
  product_code  bigint  NOT NULL,
  count_date    date    NOT NULL,
  correction    numeric NOT NULL,
  soh_before    numeric,
  soh_after     numeric,
  var_pct       numeric,
  unit_cost     numeric,
  rand_value    numeric,
  PRIMARY KEY (store_code, product_code, count_date)
);
CREATE INDEX IF NOT EXISTS l2_normalised_count_date ON public.l2_normalised_count (store_code, count_date);

ALTER TABLE public.l2_normalised_line  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_normalised_count ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.l2_normalised_line, public.l2_normalised_count FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.l2_normalised_line, public.l2_normalised_count TO service_role;

COMMENT ON TABLE public.l2_normalised_line IS 'GRADE: CALCULATED. The normalised state per (store, product) with at least one DIWAINV count pair inside stocktake_confirm_window_days since stocktake_history_start_yyyymmdd. qualified_date is NOT NULL when the line is normalised under the configured view and tolerance (it keeps that status). min_var_b / min_var_a let the share be read at any tolerance. Written nightly by refresh_l2_normalised (ENG-241, SB-CC-STOCKTAKE-001 section 4).';
COMMENT ON TABLE public.l2_normalised_count IS 'GRADE: CALCULATED. Measured shrinkage: every DIWAINV count day AFTER a line qualified, with the correction in units and rand (unit cost, because cost_value is 0 on count postings). Written nightly by refresh_l2_normalised.';

CREATE OR REPLACE FUNCTION public.refresh_l2_normalised(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_tol numeric;
  v_strict boolean;
  v_win integer;
  v_start date;
  v_days integer;
  v_lines integer;
  v_qual integer;
  v_counts integer;
BEGIN
  v_tol    := stocktake_cfg('stocktake_normalised_tolerance_pct', p_store);
  v_strict := COALESCE(stocktake_cfg('stocktake_normalised_strict', p_store), 0) = 1;
  v_win    := stocktake_cfg('stocktake_confirm_window_days', p_store)::int;
  v_start  := to_date(stocktake_cfg('stocktake_history_start_yyyymmdd', p_store)::bigint::text, 'YYYYMMDD');
  IF v_tol IS NULL OR v_win IS NULL OR v_start IS NULL THEN
    RAISE EXCEPTION 'normalised config missing for store %', p_store;
  END IF;
  v_days := store_local_today(p_store) - v_start;

  DELETE FROM l2_normalised_count WHERE store_code = p_store;
  DELETE FROM l2_normalised_line  WHERE store_code = p_store;

  INSERT INTO l2_normalised_line (store_code, product_code, count_days, min_var_b, min_var_a, qualified_date,
                                  prev_date, prev_var_pct, qual_var_pct, tolerance_pct, strict, window_days, refreshed_at)
  WITH d AS (
    SELECT * FROM stocktake_count_days(p_store, v_days)
  ), e AS (
    SELECT d.product_code AS pc, d.count_date AS cd, d.var_pct AS vp,
           LAG(d.count_date) OVER w AS pd, LAG(d.var_pct) OVER w AS pv
    FROM d WINDOW w AS (PARTITION BY d.product_code ORDER BY d.count_date)
  ), k AS (
    SELECT e.*, (e.pd IS NOT NULL AND e.cd - e.pd <= v_win) AS paired,
           (e.pd IS NOT NULL AND e.cd - e.pd <= v_win AND e.vp <= v_tol
            AND (NOT v_strict OR e.pv <= v_tol)) AS ok
    FROM e
  )
  SELECT p_store, k.pc, COUNT(*)::int,
         MIN(k.vp) FILTER (WHERE k.paired),
         MIN(GREATEST(k.vp, k.pv)) FILTER (WHERE k.paired),
         MIN(k.cd) FILTER (WHERE k.ok),
         (ARRAY_AGG(k.pd ORDER BY k.cd) FILTER (WHERE k.ok))[1],
         (ARRAY_AGG(k.pv ORDER BY k.cd) FILTER (WHERE k.ok))[1],
         (ARRAY_AGG(k.vp ORDER BY k.cd) FILTER (WHERE k.ok))[1],
         v_tol, v_strict, v_win, now()
  FROM k
  GROUP BY k.pc
  HAVING BOOL_OR(k.paired);
  GET DIAGNOSTICS v_lines = ROW_COUNT;

  SELECT COUNT(*) INTO v_qual FROM l2_normalised_line WHERE store_code = p_store AND qualified_date IS NOT NULL;

  INSERT INTO l2_normalised_count (store_code, product_code, count_date, correction, soh_before, soh_after, var_pct, unit_cost, rand_value)
  SELECT p_store, d.product_code, d.count_date, d.correction, d.soh_before, d.soh_after, d.var_pct,
         sp.unit_cost, ROUND(d.correction * COALESCE(sp.unit_cost, 0), 2)
  FROM stocktake_count_days(p_store, v_days) d
  JOIN l2_normalised_line n ON n.store_code = p_store AND n.product_code = d.product_code
       AND n.qualified_date IS NOT NULL AND d.count_date > n.qualified_date
  LEFT JOIN l2_stock_position sp ON sp.store_code = p_store AND sp.product_code = d.product_code;
  GET DIAGNOSTICS v_counts = ROW_COUNT;

  RETURN jsonb_build_object('store_code', p_store, 'candidate_lines', v_lines, 'normalised_lines', v_qual,
    'shrinkage_counts', v_counts, 'history_start', v_start, 'tolerance_pct', v_tol, 'strict', v_strict, 'window_days', v_win,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$function$;

-- The confirmation list's basis: lines counted inside the window that are NOT normalised. The
-- test lives in ONE place (refresh_l2_normalised); this reads its stocked result (R33).
CREATE OR REPLACE FUNCTION public.stocktake_not_normalised(p_store text)
 RETURNS TABLE (product_code bigint, count_days integer, latest_date date, latest_var_pct numeric, prev_var_pct numeric)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  WITH w AS (
    SELECT d.*,
           ROW_NUMBER() OVER (PARTITION BY d.product_code ORDER BY d.count_date DESC) AS rn,
           COUNT(*) OVER (PARTITION BY d.product_code) AS n
    FROM stocktake_count_days(p_store, stocktake_cfg('stocktake_confirm_window_days', p_store)::int) d
  ), g AS (
    SELECT w.product_code AS pc, MAX(w.n)::int AS n,
           MAX(w.count_date) FILTER (WHERE w.rn = 1) AS latest_date,
           MAX(w.var_pct)    FILTER (WHERE w.rn = 1) AS latest_var,
           MAX(w.var_pct)    FILTER (WHERE w.rn = 2) AS prev_var
    FROM w GROUP BY w.product_code
  )
  SELECT g.pc, g.n, g.latest_date, g.latest_var, g.prev_var
  FROM g
  WHERE NOT EXISTS (
    SELECT 1 FROM l2_normalised_line nl
    WHERE nl.store_code = p_store AND nl.product_code = g.pc AND nl.qualified_date IS NOT NULL
  )
$$;

-- The nightly stocking: normalised state first (the confirmation list reads it), then the draw.
CREATE OR REPLACE FUNCTION public.refresh_l2_stocktake_draw(p_store text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s record;
  v_t0 timestamptz;
  v_out jsonb := '[]'::jsonb;
  v_draw integer;
  v_conf integer;
  v_norm jsonb;
BEGIN
  FOR s IN SELECT st.store_code FROM stores st WHERE st.is_active AND (p_store IS NULL OR st.store_code = p_store) ORDER BY st.store_code LOOP
    v_t0 := clock_timestamp();
    v_norm := refresh_l2_normalised(s.store_code);
    DELETE FROM l2_stocktake_draw WHERE store_code = s.store_code;

    INSERT INTO l2_stocktake_draw (store_code, kind, product_code, grp, grp_prio, rank_overall, rand_value, soh, unit_cost,
      description, size_text, dept_name, subdept_name, ean_status, identifier, identifier_kind, route, route_reason,
      last_counted_date, last_sale_date, in_range, refreshed_at)
    SELECT c.store_code, 'DRAW', c.product_code, c.grp, c.grp_prio, c.rank_overall, c.rand_value, c.soh, c.unit_cost,
           c.description, c.size_text, c.dept_name, c.subdept_name, c.ean_status, c.identifier, c.identifier_kind,
           c.route, c.route_reason, c.last_counted_date, c.last_sale_date, c.in_range, now()
    FROM stocktake_candidates_compute(s.store_code) c;
    GET DIAGNOSTICS v_draw = ROW_COUNT;

    INSERT INTO l2_stocktake_draw (store_code, kind, product_code, grp, grp_prio, rank_overall, rand_value, soh, unit_cost,
      description, size_text, dept_name, subdept_name, ean_status, identifier, identifier_kind, route, route_reason,
      last_counted_date, last_sale_date, in_range, count_days, latest_var_pct, refreshed_at)
    SELECT c.store_code, 'CONFIRM', c.product_code, c.grp, c.grp_prio, c.rank_overall, c.rand_value, c.soh, c.unit_cost,
           c.description, c.size_text, c.dept_name, c.subdept_name, c.ean_status, c.identifier, c.identifier_kind,
           c.route, c.route_reason, c.last_counted_date, c.last_sale_date, c.in_range, c.count_days, c.latest_var_pct, now()
    FROM stocktake_confirm_candidates_compute(s.store_code) c;
    GET DIAGNOSTICS v_conf = ROW_COUNT;

    DELETE FROM l2_stocktake_pool_summary WHERE store_code = s.store_code;
    INSERT INTO l2_stocktake_pool_summary (store_code, pool, in_range, counted_91, uncounted, negative, zero_stock, cost_errors_out, refreshed_at)
    SELECT s.store_code, COUNT(*), COUNT(*) FILTER (WHERE v.in_range), COUNT(*) FILTER (WHERE v.counted_91),
           COUNT(*) FILTER (WHERE NOT v.counted_91),
           COUNT(*) FILTER (WHERE NOT v.counted_91 AND v.soh < 0),
           COUNT(*) FILTER (WHERE NOT v.counted_91 AND v.soh = 0),
           COUNT(*) FILTER (WHERE NOT v.counted_91 AND cl.bucket = 'COST_ERROR'),
           now()
    FROM v_stocktake_pool v
    LEFT JOIN l2_classification cl ON cl.store_code = v.store_code AND cl.product_code = v.product_code
         AND cl.snapshot_date = (SELECT MAX(x.snapshot_date) FROM l2_classification x WHERE x.store_code = s.store_code)
    WHERE v.store_code = s.store_code;

    v_out := v_out || jsonb_build_object('store_code', s.store_code, 'draw_rows', v_draw, 'confirm_rows', v_conf,
               'normalised_lines', v_norm -> 'normalised_lines',
               'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  END LOOP;
  RETURN jsonb_build_object('stores', v_out);
END;
$function$;

-- The normalised measure for the count page and the toolkit overview. Reads the stocked tables
-- only. Selling lines = World 1 (class NORMAL) lines that sold in the last 91 store-local days.
-- p_store NULL = every active store.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_normalised(p_store text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'store_code'), '[]'::jsonb) INTO v_out FROM (
    SELECT jsonb_build_object(
      'store_code', s.store_code, 'store_name', s.store_name,
      'tolerance_pct', stocktake_cfg('stocktake_normalised_tolerance_pct', s.store_code),
      'compare_pct', stocktake_cfg('stocktake_normalised_compare_pct', s.store_code),
      'strict', COALESCE(stocktake_cfg('stocktake_normalised_strict', s.store_code), 0) = 1,
      'window_days', stocktake_cfg('stocktake_confirm_window_days', s.store_code),
      'history_start', to_date(stocktake_cfg('stocktake_history_start_yyyymmdd', s.store_code)::bigint::text, 'YYYYMMDD'),
      'refreshed_at', (SELECT MAX(nl.refreshed_at) FROM l2_normalised_line nl WHERE nl.store_code = s.store_code),
      'selling_lines', sel.n,
      'normalised_lines', m.norm,
      'share_pct', CASE WHEN sel.n > 0 THEN ROUND(100.0 * m.norm / sel.n, 1) END,
      'at_tolerance', (SELECT jsonb_agg(jsonb_build_object('tolerance_pct', t.tol,
                 'view_b', (SELECT COUNT(*) FROM l2_normalised_line nl JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                             JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                            WHERE nl.store_code = s.store_code AND nl.min_var_b <= t.tol),
                 'view_a', (SELECT COUNT(*) FROM l2_normalised_line nl JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                             JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                            WHERE nl.store_code = s.store_code AND nl.min_var_a <= t.tol)) ORDER BY t.tol)
                 FROM (SELECT DISTINCT stocktake_cfg(k, s.store_code) AS tol FROM (VALUES ('stocktake_normalised_tolerance_pct'), ('stocktake_normalised_compare_pct')) kk(k)) t
                 WHERE t.tol IS NOT NULL),
      'fell_short', (SELECT jsonb_build_object('lines', COUNT(*),
                 'top', COALESCE((SELECT jsonb_agg(jsonb_build_object('product_code', q.product_code, 'description', q.description,
                            'soh', q.soh, 'rand_value', q.rv, 'count_days', q.count_days, 'best_latest_var_pct', ROUND(q.min_var_b, 1)) ORDER BY q.rv DESC)
                            FROM (SELECT nl.product_code, sp.description, sp.soh, ABS(sp.soh * sp.unit_cost) rv, nl.count_days, nl.min_var_b
                                    FROM l2_normalised_line nl
                                    JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                                    JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                                   WHERE nl.store_code = s.store_code AND nl.qualified_date IS NULL
                                   ORDER BY ABS(sp.soh * sp.unit_cost) DESC NULLS LAST LIMIT 30) q), '[]'::jsonb))
                 FROM l2_normalised_line nl
                 JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                 JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                WHERE nl.store_code = s.store_code AND nl.qualified_date IS NULL),
      'trend', (SELECT COALESCE(jsonb_agg(jsonb_build_object('week_ending', w.we, 'normalised', w.n) ORDER BY w.we), '[]'::jsonb)
                 FROM (SELECT g.we, (SELECT COUNT(*) FROM l2_normalised_line nl JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                                       JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                                      WHERE nl.store_code = s.store_code AND nl.qualified_date <= g.we) AS n
                         FROM (SELECT (date_trunc('week', store_local_today(s.store_code))::date + 6 - 7 * i) AS we FROM generate_series(0, 25) i) g) w),
      'shrinkage_weekly', (SELECT COALESCE(jsonb_agg(jsonb_build_object('week_ending', q.we, 'lines_counted', q.lines, 'loss_units', q.loss_u,
                 'gain_units', q.gain_u, 'net_units', q.net_u, 'net_rand', q.net_r, 'loss_rand', q.loss_r) ORDER BY q.we), '[]'::jsonb)
                 FROM (SELECT (date_trunc('week', c.count_date)::date + 6) AS we, COUNT(DISTINCT c.product_code) AS lines,
                              SUM(c.correction) FILTER (WHERE c.correction < 0) AS loss_u, SUM(c.correction) FILTER (WHERE c.correction > 0) AS gain_u,
                              SUM(c.correction) AS net_u, SUM(c.rand_value) AS net_r, SUM(c.rand_value) FILTER (WHERE c.correction < 0) AS loss_r
                         FROM l2_normalised_count c
                        WHERE c.store_code = s.store_code AND c.count_date >= store_local_today(s.store_code) - 26 * 7
                        GROUP BY 1) q),
      'largest_corrections', (SELECT COALESCE(jsonb_agg(jsonb_build_object('product_code', q.product_code, 'description', q.description,
                 'count_date', q.count_date, 'correction', q.correction, 'unit_cost', q.unit_cost, 'rand_value', q.rand_value) ORDER BY ABS(q.rand_value) DESC), '[]'::jsonb)
                 FROM (SELECT c.product_code, sp.description, c.count_date, c.correction, c.unit_cost, c.rand_value
                         FROM l2_normalised_count c
                         LEFT JOIN l2_stock_position sp ON sp.store_code = c.store_code AND sp.product_code = c.product_code
                        WHERE c.store_code = s.store_code AND c.count_date >= store_local_today(s.store_code) - 26 * 7
                        ORDER BY ABS(c.rand_value) DESC NULLS LAST LIMIT 5) q)
    ) AS x
    FROM stores s
    CROSS JOIN LATERAL (SELECT COUNT(*) AS n FROM l2_count_range cr JOIN l2_stock_position sp ON sp.store_code = cr.store_code AND sp.product_code = cr.product_code AND sp.class = 'NORMAL'
                         WHERE cr.store_code = s.store_code AND cr.sold_91) sel
    CROSS JOIN LATERAL (SELECT COUNT(*) AS norm FROM l2_normalised_line nl JOIN l2_count_range cr ON cr.store_code = nl.store_code AND cr.product_code = nl.product_code AND cr.sold_91
                         JOIN l2_stock_position sp ON sp.store_code = nl.store_code AND sp.product_code = nl.product_code AND sp.class = 'NORMAL'
                        WHERE nl.store_code = s.store_code AND nl.qualified_date IS NOT NULL) m
    WHERE s.is_active AND (p_store IS NULL OR s.store_code = p_store)
  ) q;
  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_normalised(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_l2_normalised(text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.rpc_stocktake_normalised(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_stocktake_normalised(text) TO authenticated, service_role;

COMMENT ON FUNCTION public.refresh_l2_normalised(text) IS 'GRADE: CALCULATED. Stocks l2_normalised_line and l2_normalised_count for one store from the DIWAINV count days since stocktake_history_start_yyyymmdd. Runs first inside refresh_l2_stocktake_draw (ENG-241, SB-CC-STOCKTAKE-001 section 4).';
COMMENT ON FUNCTION public.rpc_stocktake_normalised(text) IS 'GRADE: CALCULATED. The normalised measure per store: selling lines, normalised lines and share, the share at the configured tolerance and the compare tolerance under both views, the lines that fell short, the weekly trend and measured shrinkage. Reads the stocked tables only. One home for the count page and the toolkit overview.';

NOTIFY pgrst, 'reload schema';
