-- =============================================================================
-- create_rpc_bloom_budget_context.sql
-- SB-CC-BLOOM-029 item 7 -- ONE published interface replaces five base-table reads.
-- =============================================================================
-- WHY THIS EXISTS (R30 section 1). `src/app/bloom/page.jsx` reads two BASE TABLES
-- directly with the browser key -- `order_budget_ledger` (x4) and
-- `l2_sales_budget` (x1). A page that reads L1/L2 base tables is a DEFECT even
-- while it works: it is a breakage waiting for the next grant or schema change,
-- and it is the exact shape that silently emptied the Pulse Mini Kitchen tab
-- when SEC-001 landed. Every surface reads a published interface. This is it.
--
-- AND THE DUPLICATED RULE GOES WITH IT (R30 addendum 3, the propagation rule).
-- The desk -> ledger-route mapping was written out a SECOND time in the browser:
--
--   const ledgerRoute = desk === 'DIRECT_BEER' ? 'DIRECT_BEER'
--                     : desk.startsWith('DIRECT_') ? 'DIRECT' : 'DC'
--
-- with a comment saying it "must stay in lockstep with" the recipe's own
-- v_ledger_route CASE. A rule that is documented as needing to stay in lockstep
-- is a rule with two homes. The expression below is lifted VERBATIM from
-- `rpc_bloom_order_recipe` (read at source via pg_get_functiondef 2026-09-02),
-- backslash escape included, and the browser copy is retired with this ship.
--
-- SIGNATURE
--   rpc_bloom_budget_context(p_store_code text, p_desk text, p_delivery_date date DEFAULT NULL)
--   RETURNS jsonb
--
--   p_delivery_date NULL means "the latest ledger row for this route", which is
--   what the RecipeMode read did. Non-NULL means "the newest row AT OR BEFORE the
--   delivery date", which is ENG-055's fix and what the Desks screen does. Both
--   call sites keep their own behaviour; neither re-derives a week boundary
--   client-side (R21/R27 -- the engine picks, the surface never re-cooks).
--
-- READ ROUTINE, so it carries the same grants as rpc_bloom_order_cached: anon +
-- authenticated EXECUTE (R30 addendum extension scopes the anon revoke to
-- MUTATING functions; read RPCs stay anon-executable by design). SECURITY
-- DEFINER because `l2_sales_budget` and `order_budget_ledger` are reached as the
-- engine, not as the caller -- the same reason rpc_kpi_stock_by_date carries it.
--
-- =============================================================================
-- TWO THINGS THIS FUNCTION DELIBERATELY REPRODUCES RATHER THAN CORRECTS, because
-- item 7's R22 is "byte-identical to what the five direct reads return today"
-- and a silent improvement would make that gate unfalsifiable:
--
--   1. NO `grain` FILTER. `rpc_bloom_order_recipe` filters `grain = 'weekly'`
--      when it reads this ledger. The FRONTEND never did. `order_budget_ledger`
--      holds both weekly and monthly rows, so the screen can legitimately be
--      reading a monthly row where the engine reads a weekly one. That is a real
--      question and it is NOT answered here -- reproducing the screen's own
--      behaviour is what makes the repoint provable. Filed for PM, not fixed.
--
--   2. `rail` TAKES THE EARLIEST BUDGET WEEK (`ORDER BY budget_week_start ASC`),
--      which is what the screen does. It is the coverage rail, not the money, so
--      the earliest row is defensible -- but it is stated here so nobody reads
--      it as the delivery week's row.
--
-- ONE THING IT DELIBERATELY DOES NOT REPRODUCE, named because it is a change:
--      `direct_beer_row` resolves the current month from the STORE's own local
--      date (`store_local_today`, ENG-117) instead of the BROWSER's clock, which
--      is what `monthStartIso()` used. The browser's clock is not the store's
--      clock, and this database's TimeZone is UTC, so neither CURRENT_DATE nor
--      the browser was reliably right. `direct_beer_row` is outside item 7's
--      stated R22 set (desk_row / all_row / rail), so this correction is safe to
--      make in the same pass; it is called out so it is not discovered later.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_budget_context(
  p_store_code    text,
  p_desk          text,
  p_delivery_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH route AS (
    -- VERBATIM from rpc_bloom_order_recipe's v_ledger_route CASE. One home.
    SELECT CASE
             WHEN p_desk = 'DIRECT_BEER'                    THEN 'DIRECT_BEER'
             WHEN p_desk LIKE 'DIRECT\_%' ESCAPE '\'        THEN 'DIRECT'
             ELSE 'DC'
           END AS ledger_route
  ),
  desk_row AS (
    SELECT to_jsonb(obl) AS j
    FROM public.order_budget_ledger obl, route r
    WHERE obl.store_code = p_store_code
      AND obl.route_key  = r.ledger_route
      AND (p_delivery_date IS NULL OR obl.year_month <= p_delivery_date)
    ORDER BY obl.year_month DESC
    LIMIT 1
  ),
  all_row AS (
    SELECT to_jsonb(obl) AS j
    FROM public.order_budget_ledger obl
    WHERE obl.store_code = p_store_code
      AND obl.route_key  = 'ALL'
      AND (p_delivery_date IS NULL OR obl.year_month <= p_delivery_date)
    ORDER BY obl.year_month DESC
    LIMIT 1
  ),
  beer_row AS (
    SELECT to_jsonb(obl) AS j
    FROM public.order_budget_ledger obl
    WHERE p_desk = 'DIRECT_BEER'
      AND obl.store_code = p_store_code
      AND obl.route_key  = 'DIRECT_BEER'
      AND obl.year_month = date_trunc('month', public.store_local_today(p_store_code))::date
    LIMIT 1
  ),
  rail AS (
    SELECT jsonb_build_object(
             'products_in_pool',         b.products_in_pool,
             'products_with_ly_history', b.products_with_ly_history,
             'budget_week_start',        b.budget_week_start
           ) AS j
    FROM public.l2_sales_budget b
    WHERE b.store_code = p_store_code
      AND b.route_key  = p_desk
    ORDER BY b.budget_week_start ASC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'store_code',      p_store_code,
    'desk',            p_desk,
    'delivery_date',   p_delivery_date,
    'ledger_route',    (SELECT ledger_route FROM route),
    -- R29: the basis travels with the number, so a screen can say WHICH week it
    -- is showing rather than presenting a fallback as an exact answer.
    'desk_row_basis',  CASE
                         WHEN NOT EXISTS (SELECT 1 FROM desk_row) THEN 'no_ledger_row'
                         WHEN p_delivery_date IS NULL             THEN 'latest_row'
                         ELSE 'at_or_before_delivery_date'
                       END,
    'desk_row',        (SELECT j FROM desk_row),
    'all_row',         (SELECT j FROM all_row),
    'direct_beer_row', (SELECT j FROM beer_row),
    'rail',            (SELECT j FROM rail)
  );
$function$;

COMMENT ON FUNCTION public.rpc_bloom_budget_context(text, text, date) IS
'GRADE: CALCULATED. SB-CC-BLOOM-029 item 7. The one published interface for the Bloom desk''s budget context: the desk''s own ledger row, the store ALL row, the DIRECT_BEER month row, and the l2_sales_budget coverage rail. Replaces five direct base-table reads in src/app/bloom/page.jsx (R30 section 1) and retires the browser copy of the desk->ledger-route CASE (R30 addendum 3). The route expression is verbatim from rpc_bloom_order_recipe. Reproduces the screen''s existing semantics deliberately, including the absence of a grain filter -- see the file header for what is reproduced and what is corrected.';

-- Grants stated explicitly in the create file (R30 addendum). Read routine:
-- anon stays executable by design, matching rpc_bloom_order_cached.
REVOKE EXECUTE ON FUNCTION public.rpc_bloom_budget_context(text, text, date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_bloom_budget_context(text, text, date) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
