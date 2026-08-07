-- =============================================================================
-- create_rpc_kpi_stock_by_date.sql
-- BUG-LOG ENG-074 -- the STOCK half of the ENG-069 repoint.
-- Canonical source. Deployed 2026-08-07 via Supabase MCP migration
--   eng074_rpc_kpi_stock_by_date.
-- =============================================================================
-- WHAT THIS DOES:
--   Returns the four point-in-time STOCK facts per (store, date) that the KPI
--   cards read -- neg_soh_count, slow_mover_count, capital_tied,
--   ghost_stock_value -- with the SAME column names and the SAME expressions
--   v_kpi_by_date already uses, so the frontend swap is source-only and no
--   figure is redefined.
--
-- WHY IT EXISTS (ENG-069 left this half deliberately, ENG-074 closes it):
--   PostgREST connects as `authenticator`, which carries statement_timeout=8s,
--   and its mid-session SET ROLE does NOT re-apply the target role's rolconfig.
--   So a plain VIEW is 8s-bound whatever anon/authenticated are set to, while a
--   SECURITY DEFINER function can hold its own SET LOCAL. Sales moved to
--   rpc_dept_summary at ENG-069; these four stayed on the view and inherited the
--   timeout, so on a recent date they rendered UNAVAILABLE.
--   DO NOT raise the timeout instead: Kong kills ~30s (standing constraint 4)
--   and authenticator's 8s is not the target role's to change. The work moves.
--
-- ROOT CAUSE, MEASURED AT SOURCE 2026-08-07 -- and it is bigger than "a view
-- cannot hold a timeout". TWO independent faults compounding:
--   (1) THE INDEX COULD NOT SEEK. v_kpi_by_date joins l2_soh_daily to
--       l2_stock_position on (store_code, product_code) ONLY. The unique index
--       idx_l2_pos_pk is (client_id, store_code, product_code) -- CLIENT_ID
--       LEADING -- so the join could not seek it and each probe cost ~4,665.
--       This is CLEANUP-ENGINE-CANON section 17's own standing note ("any query
--       against these two facts carries client_id in the predicate") firing on a
--       live dashboard object. Carrying client_id drops the probe to cost 2.65.
--   (2) THE ESTIMATE WAS 77,000x WRONG. l2_soh_daily filtered to a recent date
--       estimates rows=1 against a real 89,999 for one store (387,378 across
--       five), because the table gains ~387k rows/day and the newest date is
--       always past the histogram. rows=1 makes the planner choose a Nested
--       Loop, which then runs ~90k expensive probes.
--   NOTE THE CONSEQUENCE, because it is not "flaky under load": the newest date
--   is ALWAYS the worst-estimated one, so the failure is structural and recurs
--   by construction on the exact date the owner reads each morning.
--
-- MEASURED, same store/date, same expressions:
--   80175 / 2026-08-06, one store  : view shape CANCELLED past 25s
--                                    this shape  1,153 ms
--   five stores / 2026-08-06       : this shape  4,301 ms
--
-- SECURITY DEFINER IS LOAD-BEARING, NOT BOILERPLATE (proven behaviourally, per
--   ENG-068 -- never read a grant, run it as the role):
--     SET ROLE anon -> SELECT count(*) FROM l2_soh_daily WHERE
--     snapshot_date='2026-08-06' returns 0. The table has RLS ENABLED with ZERO
--     policies, which silently overrides the SELECT grant that reads `true`.
--   A SECURITY INVOKER version would therefore return no rows and report a
--   confident, permanent ZERO on every stock card -- a wrong number, which is
--   worse than an absent one (R22 section 3, and the ENG-069 `?? []` lesson).
--
-- client_id IN THE JOIN CANNOT MOVE A NUMBER TODAY, verified before relying on
--   it: l2_soh_daily and l2_stock_position each carry exactly ONE distinct
--   client_id, zero (store_code, product_code) pairs hold more than one, and the
--   join returns 270,594 matched rows across five stores -- so the values agree.
--   It is a planner enabler today and correct scoping the day a second client
--   lands.
--
-- GRANTS: read RPC -- anon + authenticated EXECUTE, matching the
--   rpc_dept_summary / rpc_kpi_dept_counts precedent. R30's addendum extension
--   scopes the anon revoke to MUTATING functions; this one reads.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_kpi_stock_by_date(text[], text[]);

CREATE FUNCTION public.rpc_kpi_stock_by_date(
  p_store_codes text[],
  p_dates       text[]
)
RETURNS TABLE (
  store_code        text,
  snapshot_date     date,
  neg_soh_count     bigint,
  slow_mover_count  bigint,
  capital_tied      numeric,
  ghost_stock_value numeric
)
LANGUAGE plpgsql
-- Deliberately NOT marked STABLE: this function issues SET LOCAL, and
-- rpc_dept_summary carries the same note for the same reason. Volatile costs
-- nothing here -- it is called once per render, never in a scan.
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  -- Pre-cast to date[] in a variable. An inline `= ANY(p_dates::date[])` in the
  -- predicate defeats the index on l2_soh_daily; the pre-cast keeps it (RULE-BOOK
  -- section 8 index rule -- cast the parameter, never the column).
  v_dates date[] := p_dates::date[];
BEGIN
  -- Own ceiling. Measured worst case is 4.3s for five stores on one date; 20s is
  -- headroom without reaching Kong's ~30s kill, so a genuine overrun returns a
  -- named error rather than a gateway failure.
  SET LOCAL statement_timeout = '20s';

  RETURN QUERY
  WITH soh AS MATERIALIZED (
    -- MATERIALIZED on purpose: it fences the rows=1 mis-estimate above so it
    -- cannot propagate into the join's plan choice.
    SELECT ls.client_id, ls.store_code, ls.snapshot_date, ls.product_code, ls.soh
    FROM l2_soh_daily ls
    WHERE ls.store_code    = ANY(p_store_codes)
      AND ls.snapshot_date = ANY(v_dates)
  )
  SELECT
    s.store_code,
    s.snapshot_date,
    SUM(CASE WHEN s.soh < 0 THEN 1 ELSE 0 END)::bigint             AS neg_soh_count,
    SUM(CASE WHEN sp.slow_mover_signal THEN 1 ELSE 0 END)::bigint  AS slow_mover_count,
    COALESCE(ROUND(SUM(CASE WHEN sp.class = 'NORMAL' AND s.soh > 0
                            THEN s.soh * COALESCE(sp.unit_cost, 0) END), 2), 0)  AS capital_tied,
    COALESCE(ROUND(SUM(CASE WHEN sp.class IN ('PRODUCTION','NON_STOCK') AND s.soh > 0
                            THEN s.soh * COALESCE(sp.unit_cost, 0) END), 2), 0)  AS ghost_stock_value
  FROM soh s
  JOIN l2_stock_position sp
    ON  sp.client_id    = s.client_id     -- the seek key (canon section 17)
    AND sp.store_code   = s.store_code
    AND sp.product_code = s.product_code
  GROUP BY s.store_code, s.snapshot_date;
END
$function$;

REVOKE ALL ON FUNCTION public.rpc_kpi_stock_by_date(text[], text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_kpi_stock_by_date(text[], text[]) TO anon, authenticated;

COMMENT ON FUNCTION public.rpc_kpi_stock_by_date(text[], text[]) IS
  'ENG-074. The four point-in-time stock KPI facts per (store, date), moved off '
  'v_kpi_by_date. Same expressions, same column names. SECURITY DEFINER is '
  'load-bearing: l2_soh_daily has RLS enabled with zero policies, so an invoker '
  'read as anon returns 0 rows and would render a false zero.';
