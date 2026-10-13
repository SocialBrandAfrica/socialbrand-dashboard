-- =============================================================================
-- ENG-241 -- THE DRAW IS STOCKED, NOT COMPUTED ON CLICK (SB-CC-STOCKTAKE-001 v1.2 section 2)
--
-- MEASURED 13-10-2026 at 10116: stocktake_candidates took 11 to 16 s per call (the pool view
-- 4.6 s, the item-barcode decoder 3.0 s, the 28-day sales scan 1.3 s, the classification probe
-- per line), and a generate called it twice: 36 s, past the 30 s ceiling of an authenticated
-- call. The draw is a daily fact (stock, last count, the 28-day sales and the classification all
-- move once a night), so it is stocked ONCE a night and the app READS it (R32: the pantry is
-- stocked, an app reads).
--
--   l2_stocktake_draw          one row per (store, kind, product). kind DRAW = the uncounted pool
--                              in the ruled order, kind CONFIRM = the confirmation count list.
--   l2_stocktake_pool_summary  one row per store: the pool figures the dashboard shows.
--   refresh_l2_stocktake_draw  writes both from the two compute functions (DELETE + INSERT in one
--                              transaction per store, so a reader never sees a half-built draw).
--   cron stocktake-draw-refresh  03:30 UTC (05:30 store time), after the 20:15 UTC nightly chain
--                              and before the stores open. forge-daily-issue runs at 04:30 UTC.
--
-- stocktake_candidates and stocktake_confirm_candidates keep their names and their columns and
-- now READ the stocked rows, so rpc_stocktake_generate and rpc_stocktake_store_state are
-- unchanged in shape. The compute bodies keep their own names (..._compute), unchanged.
--
-- A line finalised today is kept out of the next generation by the cycle exclusion (open cycles
-- and cycles finalised inside stocktake_posting_wait_days), not by the stocked rows, so a second
-- generation the same day does not repeat lines. When Sigma posts the count overnight the line
-- leaves the stocked draw on the next refresh.
--
-- ROLLBACK: DROP both tables and refresh_l2_stocktake_draw, cron.unschedule('stocktake-draw-refresh'),
-- then rename the ..._compute functions back to stocktake_candidates and
-- stocktake_confirm_candidates.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_stocktake_draw (
  store_code        text        NOT NULL,
  kind              text        NOT NULL CHECK (kind IN ('DRAW','CONFIRM')),
  product_code      bigint      NOT NULL,
  grp               text        NOT NULL,
  grp_prio          integer     NOT NULL,
  rank_overall      integer     NOT NULL,
  rand_value        numeric,
  soh               numeric,
  unit_cost         numeric,
  description       text,
  size_text         text,
  dept_name         text,
  subdept_name      text,
  ean_status        text,
  identifier        text        NOT NULL,
  identifier_kind   text        NOT NULL,
  route             text        NOT NULL,
  route_reason      text,
  last_counted_date date,
  last_sale_date    date,
  in_range          boolean,
  count_days        integer,
  latest_var_pct    numeric,
  refreshed_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, kind, product_code)
);
CREATE INDEX IF NOT EXISTS l2_stocktake_draw_rank ON public.l2_stocktake_draw (store_code, kind, rank_overall);

CREATE TABLE IF NOT EXISTS public.l2_stocktake_pool_summary (
  store_code      text PRIMARY KEY,
  pool            integer NOT NULL,
  in_range        integer NOT NULL,
  counted_91      integer NOT NULL,
  uncounted       integer NOT NULL,
  negative        integer NOT NULL,
  zero_stock      integer NOT NULL,
  cost_errors_out integer NOT NULL,
  refreshed_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.l2_stocktake_draw         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_stocktake_pool_summary ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.l2_stocktake_draw, public.l2_stocktake_pool_summary FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.l2_stocktake_draw, public.l2_stocktake_pool_summary TO service_role;

COMMENT ON TABLE public.l2_stocktake_draw IS 'GRADE: CALCULATED. The count app''s stocked draw, one row per (store, kind, product): DRAW = the uncounted count pool in the ruled order (NEGATIVE, INACTIVE, SUSPECT, ZERO), CONFIRM = the confirmation count list. Written nightly by refresh_l2_stocktake_draw (cron stocktake-draw-refresh) from stocktake_candidates_compute and stocktake_confirm_candidates_compute. Read only through stocktake_candidates and stocktake_confirm_candidates (ENG-241, SB-CC-STOCKTAKE-001).';
COMMENT ON TABLE public.l2_stocktake_pool_summary IS 'GRADE: CALCULATED. One row per store: the count pool figures the stocktake dashboard shows (pool, in range, counted in 91 days, uncounted, negative, zero stock, cost errors held out). Written nightly with l2_stocktake_draw.';

-- The compute functions keep their bodies. The two readers take the names the app already calls.
DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'stocktake_candidates' AND pronamespace = 'public'::regnamespace)
     AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'stocktake_candidates_compute' AND pronamespace = 'public'::regnamespace) THEN
    ALTER FUNCTION public.stocktake_candidates(text) RENAME TO stocktake_candidates_compute;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'stocktake_confirm_candidates' AND pronamespace = 'public'::regnamespace)
     AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'stocktake_confirm_candidates_compute' AND pronamespace = 'public'::regnamespace) THEN
    ALTER FUNCTION public.stocktake_confirm_candidates(text) RENAME TO stocktake_confirm_candidates_compute;
  END IF;
END
$mig$;

CREATE OR REPLACE FUNCTION public.stocktake_candidates(p_store text)
 RETURNS TABLE (
   store_code text, product_code bigint, grp text, grp_prio integer, rank_overall integer,
   rand_value numeric, soh numeric, unit_cost numeric, description text, size_text text,
   dept_name text, subdept_name text, ean_status text, identifier text, identifier_kind text,
   route text, route_reason text, last_counted_date date, last_sale_date date, in_range boolean)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  SELECT d.store_code, d.product_code, d.grp, d.grp_prio, d.rank_overall, d.rand_value, d.soh, d.unit_cost,
         d.description, d.size_text, d.dept_name, d.subdept_name, d.ean_status, d.identifier, d.identifier_kind,
         d.route, d.route_reason, d.last_counted_date, d.last_sale_date, d.in_range
  FROM l2_stocktake_draw d
  WHERE d.store_code = p_store AND d.kind = 'DRAW'
$$;

CREATE OR REPLACE FUNCTION public.stocktake_confirm_candidates(p_store text)
 RETURNS TABLE (
   store_code text, product_code bigint, grp text, grp_prio integer, rank_overall integer,
   rand_value numeric, soh numeric, unit_cost numeric, description text, size_text text,
   dept_name text, subdept_name text, ean_status text, identifier text, identifier_kind text,
   route text, route_reason text, last_counted_date date, last_sale_date date, in_range boolean,
   count_days integer, latest_var_pct numeric)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  SELECT d.store_code, d.product_code, d.grp, d.grp_prio, d.rank_overall, d.rand_value, d.soh, d.unit_cost,
         d.description, d.size_text, d.dept_name, d.subdept_name, d.ean_status, d.identifier, d.identifier_kind,
         d.route, d.route_reason, d.last_counted_date, d.last_sale_date, d.in_range, d.count_days, d.latest_var_pct
  FROM l2_stocktake_draw d
  WHERE d.store_code = p_store AND d.kind = 'CONFIRM'
$$;

-- The nightly stocking. p_store NULL = every active store. Each store is one transaction of its
-- own inside the call (DELETE + INSERT), so a reader sees the old draw or the new one, never half.
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
BEGIN
  FOR s IN SELECT st.store_code FROM stores st WHERE st.is_active AND (p_store IS NULL OR st.store_code = p_store) ORDER BY st.store_code LOOP
    v_t0 := clock_timestamp();
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
               'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
  END LOOP;
  RETURN jsonb_build_object('stores', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.stocktake_candidates_compute(text), public.stocktake_confirm_candidates_compute(text),
  public.stocktake_candidates(text), public.stocktake_confirm_candidates(text),
  public.refresh_l2_stocktake_draw(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stocktake_candidates_compute(text), public.stocktake_confirm_candidates_compute(text),
  public.stocktake_candidates(text), public.stocktake_confirm_candidates(text),
  public.refresh_l2_stocktake_draw(text) TO service_role;

COMMENT ON FUNCTION public.stocktake_candidates_compute(text) IS 'GRADE: RECOMMENDED. The count app''s draw for one store COMPUTED from the live pool: the uncounted count pool in the ruled order (NEGATIVE, INACTIVE, SUSPECT by absolute rand value, then ZERO), cost errors out, each line carrying its identifier and its route (TLX or MANUAL). Measured 11 to 16 s at 10116, so it runs only inside refresh_l2_stocktake_draw. Internal, service_role only.';
COMMENT ON FUNCTION public.stocktake_confirm_candidates_compute(text) IS 'GRADE: RECOMMENDED. The confirmation count list for one store COMPUTED: lines counted inside stocktake_confirm_window_days and not yet normalised, highest rand value first. Runs only inside refresh_l2_stocktake_draw. Internal, service_role only.';
COMMENT ON FUNCTION public.stocktake_candidates(text) IS 'GRADE: CALCULATED. The stocked draw for one store (kind DRAW of l2_stocktake_draw). One home: generate and the store state both read it. Internal, service_role only.';
COMMENT ON FUNCTION public.stocktake_confirm_candidates(text) IS 'GRADE: CALCULATED. The stocked confirmation list for one store (kind CONFIRM of l2_stocktake_draw). Internal, service_role only.';
COMMENT ON FUNCTION public.refresh_l2_stocktake_draw(text) IS 'GRADE: CALCULATED. Stocks l2_stocktake_draw and l2_stocktake_pool_summary for one store, or every active store when p_store is NULL. Nightly via cron stocktake-draw-refresh at 03:30 UTC (ENG-241).';

-- The schedule (applied 13-10-2026 as cron jobid 43). 03:30 UTC = 05:30 store time.
-- SELECT cron.schedule('stocktake-draw-refresh', '30 3 * * *',
--   $c$SET statement_timeout = '1800s'; SELECT public.refresh_l2_stocktake_draw();$c$);
-- First stocking, run by hand 13-10-2026: 10116 33.9 s, 21355 19.1 s, 80175 24.0 s, 80176 15.0 s, 80579 18.1 s.

NOTIFY pgrst, 'reload schema';
