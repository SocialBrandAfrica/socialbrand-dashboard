-- =============================================================================
-- ENG-241 -- THE COUNT POOL, REFINED (SB-CC-STOCKTAKE-001 v1.2 section 7, defects 1 and 2)
--
-- DEFECT 1 (the pool is a moment test). The pool was World 1 lines with soh <> 0 today. A
-- selling line whose stock reads 0 dropped out, so it was never asked for and never counted,
-- and the coverage ratio moved with no count at all. Measured 13-10 16:3x at 10116: the
-- buy-and-sell range (sold or received in 91 days) is 9,238 lines, 967 of them at 0 today and
-- outside the pool.
-- DEFECT 2 ("counted" took any I-movement). Module DIWAZENT counted 9 lines (4 at 21355,
-- 5 at 80175). A count is DIWAINV (canon 15.1 point 3).
--
-- THE REFINED POOL (one home, v_stocktake_pool): World 1 (class NORMAL) lines that sold or
-- were received in the last 91 store-local days, plus any World 1 line with soh <> 0.
-- counted_91 = a DIWAINV posting inside 91 store-local days.
--
-- THE NEW PANTRY FACT. "Sold or received in 91 days" cannot be read live inside a view: the
-- receipt scan alone measured 10 s cold across the group. l2_count_range holds it per
-- (store, product), written by refresh_l2_last_counted in the SAME nightly call that already
-- writes the count recency (wired in refresh_l2_pipeline), so no pipeline edit is needed and
-- the two cannot drift apart (R32: the pantry is stocked, an app READS).
--
-- refresh_l2_last_counted also gains: module = DIWAINV only; a deterministic pick when a
-- product is counted twice on one day (movement_time, movement_id), the closing-day unit
-- (ENG-187); SET search_path (the 75-function security debt, one fewer).
--
-- GRANTS: l2_count_range is revoked from PUBLIC, anon and authenticated (read only by
-- SECURITY DEFINER functions). refresh_l2_last_counted keeps its ACL (CREATE OR REPLACE).
-- R30 ADDENDUM 3 SITE COUNT: see BUG-LOG ENG-241 (the other writers of the 91-day count test
-- are named there, not changed here).
-- ROLLBACK: sql/_archive/refresh_l2_last_counted_6ac14928_pre_eng241.sql and
--           sql/_archive/v_stocktake_pool_pre_eng241.sql, then DROP TABLE l2_count_range.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_count_range (
  store_code   text        NOT NULL,
  product_code bigint      NOT NULL,
  sold_91      boolean     NOT NULL DEFAULT false,
  received_91  boolean     NOT NULL DEFAULT false,
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);
ALTER TABLE public.l2_count_range ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.l2_count_range FROM PUBLIC;
REVOKE ALL ON public.l2_count_range FROM anon;
REVOKE ALL ON public.l2_count_range FROM authenticated;
GRANT ALL ON public.l2_count_range TO service_role;
COMMENT ON TABLE public.l2_count_range IS
'GRADE: CALCULATED. The buy-and-sell range per (store, product): sold_91 = a positive till sale (sigma_sales K) in the last 91 store-local days, received_91 = a positive R/W receipt in the same window. Written nightly by refresh_l2_last_counted (ENG-241, SB-CC-STOCKTAKE-001 section 7). A line is in the range when either is true. Read only through v_stocktake_pool.';

CREATE OR REPLACE FUNCTION public.refresh_l2_last_counted(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
  v_range int;
  v_today date;
BEGIN
  v_today := store_local_today(p_store);

  -- The count recency fact. DIWAINV only (a count is a DIWAINV posting, canon 15.1 point 3).
  -- One product counted twice on one day resolves on movement_time then movement_id.
  DELETE FROM public.l2_last_counted WHERE store_code = p_store;

  INSERT INTO public.l2_last_counted (store_code, product_code, last_counted_date, last_counted_soh, counted_91d)
  SELECT DISTINCT ON (m.store_code, m.product_code)
    m.store_code, m.product_code, m.movement_date, m.new_soh,
    (m.movement_date >= CURRENT_DATE - 91)
  FROM public.sigma_movements m
  WHERE m.store_code = p_store AND m.movement_type = 'I' AND m.module = 'DIWAINV'
  ORDER BY m.store_code, m.product_code, m.movement_date DESC, m.movement_time DESC, m.movement_id DESC;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- The buy-and-sell range fact (ENG-241): sold or received in the last 91 store-local days.
  DELETE FROM public.l2_count_range WHERE store_code = p_store;

  INSERT INTO public.l2_count_range (store_code, product_code, sold_91, received_91, refreshed_at)
  SELECT p_store, u.product_code, bool_or(u.sold), bool_or(u.recv), now()
  FROM (
    SELECT s.product_code, true AS sold, false AS recv
    FROM public.sigma_sales s
    WHERE s.store_code = p_store AND s.period_kind = 'T' AND s.txn_kind = 1
      AND s.qty > 0 AND s.sale_date >= v_today - 91
    GROUP BY s.product_code
    UNION ALL
    SELECT m.product_code, false, true
    FROM public.sigma_movements m
    WHERE m.store_code = p_store AND m.movement_type IN ('R','W')
      AND m.qty > 0 AND m.movement_date >= v_today - 91
    GROUP BY m.product_code
  ) u
  GROUP BY u.product_code;

  GET DIAGNOSTICS v_range = ROW_COUNT;

  RETURN jsonb_build_object('store_code', p_store, 'rows', v_rows, 'range_rows', v_range,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$function$;

CREATE OR REPLACE VIEW public.v_stocktake_pool AS
SELECT sp.client_id,
       sp.store_code,
       sp.product_code,
       sp.description,
       sp.dept_name,
       sp.subdept_name,
       sp.soh,
       sp.capital_value,
       sp.unit_cost,
       lc.last_counted_date,
       (lc.last_counted_date IS NOT NULL
        AND lc.last_counted_date >= ((now() AT TIME ZONE s.timezone)::date - 91)) AS counted_91,
       COALESCE(cr.sold_91, false)                                                AS sold_91,
       COALESCE(cr.received_91, false)                                            AS received_91,
       (cr.product_code IS NOT NULL)                                              AS in_range
FROM public.l2_stock_position sp
JOIN public.sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
JOIN public.stores s ON s.store_code = sp.store_code AND s.is_active
LEFT JOIN public.l2_last_counted lc ON lc.store_code = sp.store_code AND lc.product_code = sp.product_code
LEFT JOIN public.l2_count_range cr ON cr.store_code = sp.store_code AND cr.product_code = sp.product_code
WHERE sp.class = 'NORMAL' AND (sp.soh <> 0 OR cr.product_code IS NOT NULL);

COMMENT ON VIEW public.v_stocktake_pool IS
'GRADE: CALCULATED. The count pool, one row per (store, product): World 1 (class NORMAL) lines that sold or were received in the last 91 store-local days (l2_count_range), plus any World 1 line with soh <> 0 (SB-CC-STOCKTAKE-001 v1.2 section 7: a selling line at 0 stays in the pool and a count of 0 confirms it). counted_91 = a DIWAINV posting inside 91 store-local days, DERIVED ON READ from l2_last_counted.last_counted_date, never from the stored counted_91d flag (ENG-240). in_range = the buy-and-sell range. The ONE home of the count pool for rpc_forge_integrity, rpc_forge_integrity_lines and the stocktake count app. Read by SECURITY DEFINER functions only.';

REVOKE ALL ON public.v_stocktake_pool FROM PUBLIC;
REVOKE ALL ON public.v_stocktake_pool FROM anon;
REVOKE ALL ON public.v_stocktake_pool FROM authenticated;
GRANT SELECT ON public.v_stocktake_pool TO service_role;

-- Config keys the count app reads. Every one is a forge_config row, nothing is typed into a
-- function (R21, R25). Notes carry the evidence class and the derivation status (section 0h).
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT v.k, '*', v.n, 'DEMO_CALIBRATION', DATE '2026-10-13', v.note
FROM (VALUES
  ('stocktake_inactive_days', 28::numeric,
   'RULING, base rate unstatable. Pieter 13-10-2026 16:24: inactive = stock above 0 and no sale in 4 weeks. SB-CC-STOCKTAKE-001 v1.2 section 2. A sale is a positive till sale (sigma_sales K qty > 0).'),
  ('stocktake_confirm_window_days', 60::numeric,
   'RULING, base rate unstatable. PM test 13-10-2026 on Pieter''s two-counts-in-2-months rule: two DIWAINV counts on two different days within this window. SB-CC-STOCKTAKE-001 v1.2 section 4.'),
  ('stocktake_normalised_tolerance_pct', 5::numeric,
   'SEED, UNDERIVED. PM set 2 (Pieter''s 98%); Pieter 13-10-2026 16:5x: 2% is maybe too narrow, maybe 5%. Provisional at 5 until he confirms. A correction is correct when its size is no more than this share of the LARGER of the stock before and after the count. Derivation owed once a quarter of count history exists. The page shows the result at 2 and at 5 side by side.'),
  ('stocktake_normalised_strict', 0::numeric,
   'RULING (PM brief v1.2 section 4): 0 = entry view B, the latest count correct admits a line. 1 = strict view A, the latest two counts both correct.'),
  ('stocktake_adhoc_batch_size', 200::numeric,
   'RULING, base rate unstatable. Pieter 13-10-2026 16:06: optional sub-department batches of around 200 as ad hoc counts.'),
  ('stocktake_flag_tolerance_pct', 0::numeric,
   'SEED, UNDERIVED. A captured line is flagged for review when its variance exceeds this percent of the system stock. 0 flags every non-zero variance until Pieter rules the tolerance (SB-CC-STOCKTAKE-001 section 3 step 6).'),
  ('stocktake_posting_wait_days', 3::numeric,
   'SEED, UNDERIVED. A finalised cycle''s lines stay out of the next generation this many days, waiting for Sigma''s I-movement to land overnight. Derivation owed: the lag between finalise and the DIWAINV posting, from the app''s own log.')
) AS v(k, n, note)
WHERE NOT EXISTS (
  SELECT 1 FROM public.forge_config f
  WHERE f.config_key = v.k AND f.store_format = '*' AND f.retired_on IS NULL
);

NOTIFY pgrst, 'reload schema';
