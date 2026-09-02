-- =============================================================================
-- fix_rpc_forge_compliance_summary_distinct_products.sql
-- BUG-LOG ENG-171 -- the compliance scoreboard counts one physical count twice.
-- =============================================================================
-- THE DEFECT, measured at source 2026-09-02 on 10116.
--
--   what the scoreboard publishes   : 376 lines issued, 136 counted, 36.2%
--   what actually happened          : 200 distinct products issued, 68 counted
--
-- Both numbers are exactly DOUBLE. Two `daily` runs were issued for that store
-- on that day -- the 06:30 system list (200 lines) and a manual re-issue at
-- 11:08 (176 lines) -- and the manual list is a SUBSET of the system one. The
-- summary aggregates the two runs at ROW grain, so every product on both lists
-- is issued twice and, if it was counted, counted twice.
--
--   06:30 system   200 issued   68 counted   34.0%
--   11:08 manual   176 issued   68 counted   38.6%
--   store total    376 issued  136 counted   36.2%   <- 68 real counts, reported as 136
--
-- WHY IT MATTERS MORE THAN THE PERCENTAGE SUGGESTS. Here the percentage lands
-- near the truth by luck, because the two lists overlap almost completely. Where
-- the overlap is partial the percentage is wrong too -- and the LINE COUNTS are
-- wrong in every case. A scoreboard that says "136 lines counted" when 68
-- products were counted is publishing a total off the wrong population, which is
-- the ORDERING-CANON D6.1 rule and R34.5 point 4 (you cannot count what you have
-- not named; publish the denominator) arriving on the Forge lane.
--
-- POPULATION. 50 duplicate `daily` rows exist across the history, so every
-- historical compliance figure covering one of those store-days is inflated. The
-- worst are the 2026-08-31 manual `random` over-issues: 80175 reports 5 runs and
-- 2,487 lines issued that day, 10116 four runs and 2,083.
--
-- ⚠ NOT A REGRESSION FROM TODAY'S GUARD. BLOOM-029 item 4 clause (a) now returns
-- `already_issued` on a second same-day `daily` run, so this stops GROWING. It
-- does not repair the arithmetic, and it does not cover `random` or `targeted`
-- re-issues, which is why this fix is still needed.
--
-- THE FIX. Count DISTINCT product_code instead of rows, within the store-day.
-- Two edits plus carrying product_code through the `lines` CTE, which the body
-- did not select. `runs` already uses count(DISTINCT run_id) and is unchanged.
-- Signature, return type and column order are untouched, so CREATE OR REPLACE
-- applies with no DROP and no dependent invalidated -- and the toolkit and the
-- weekly-report route both keep reading it unchanged.
--
-- Regenerated from the live body (`pg_get_functiondef`, normalised-hash gated
-- against `sql/create_forge_count_run.sql` earlier tonight), so this file is a
-- faithful edit of what is deployed rather than a rewrite from memory.
--
-- 🔴 NOT APPLIED. Written 2026-09-02 while the database is frozen until the
-- three 03-09 DC orders are placed and exported. Apply in one pass afterwards,
-- and re-splice the canonical `sql/create_forge_count_run.sql` in the same pass
-- so the no-divergence gate stays shut.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_forge_compliance_summary(p_stores text[] DEFAULT NULL::text[], p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(store_code text, issue_date date, runs integer, lines_issued integer, lines_counted integer, compliance_pct numeric, oldest_outstanding_days integer, verdict text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH runs AS (
    SELECT r.run_id, r.store_code, r.issued_at::date AS issue_date
    FROM public.forge_count_run r
    WHERE (p_stores IS NULL OR r.store_code = ANY(p_stores))
      AND (p_from   IS NULL OR r.issued_at::date >= p_from)
      AND (p_to     IS NULL OR r.issued_at::date <= p_to)
  ),
  lines AS (
    -- ENG-171: product_code is carried so the aggregate below can count PRODUCTS
    -- rather than rows. Two overlapping runs on one store-day used to issue and
    -- count the same product twice.
    SELECT ru.store_code, ru.issue_date, ru.run_id, c.product_code,
           c.counted, c.days_outstanding
    FROM runs ru
    CROSS JOIN LATERAL public.rpc_forge_run_compliance(ru.run_id) c
  )
  SELECT
    l.store_code,
    l.issue_date,
    count(DISTINCT l.run_id)::integer                                   AS runs,
    -- ENG-171: DISTINCT product, not row. A product on two lists for the same
    -- store-day is ONE product to count, and one count when the floor counts it.
    count(DISTINCT l.product_code)::integer                             AS lines_issued,
    count(DISTINCT l.product_code) FILTER (WHERE l.counted)::integer    AS lines_counted,
    CASE WHEN count(DISTINCT l.product_code) > 0
         THEN round(100.0 * count(DISTINCT l.product_code) FILTER (WHERE l.counted)
                          / count(DISTINCT l.product_code), 1)
    END                                                                 AS compliance_pct,
    max(l.days_outstanding)::integer                                    AS oldest_outstanding_days,
    CASE
      WHEN count(DISTINCT l.product_code) = 0                       THEN 'EMPTY RUN -- nothing was issued'
      WHEN count(DISTINCT l.product_code) FILTER (WHERE l.counted)
           = count(DISTINCT l.product_code)                         THEN 'COMPLETE'
      WHEN count(DISTINCT l.product_code) FILTER (WHERE l.counted) = 0
           AND max(l.days_outstanding) > 0                          THEN 'NOT EXECUTED -- no line on this list was counted'
      ELSE 'PARTIAL -- ' || (count(DISTINCT l.product_code)
                             - count(DISTINCT l.product_code) FILTER (WHERE l.counted))::text
                         || ' line(s) outstanding'
    END                                                                 AS verdict
  FROM lines l
  GROUP BY l.store_code, l.issue_date
  ORDER BY l.issue_date DESC, l.store_code;
$function$;

-- =============================================================================
-- R22 -- run AFTER. 10116 on 2026-09-02 is the worked case.
-- =============================================================================
-- SELECT store_code, issue_date, runs, lines_issued, lines_counted, compliance_pct
-- FROM rpc_forge_compliance_summary(ARRAY['10116'], DATE '2026-09-02', DATE '2026-09-02');
--   BEFORE : runs 2, issued 376, counted 136, 36.2
--   AFTER  : runs 2, issued 200, counted  68, 34.0
--
-- And the independent derivation it must equal:
-- WITH r AS (SELECT run_id FROM forge_count_run
--            WHERE store_code='10116'
--              AND (issued_at AT TIME ZONE 'Africa/Johannesburg')::date = DATE '2026-09-02'),
--      l AS (SELECT c.product_code, c.counted
--            FROM r CROSS JOIN LATERAL rpc_forge_run_compliance(r.run_id) c)
-- SELECT count(DISTINCT product_code)                            AS issued,   -- 200
--        count(DISTINCT product_code) FILTER (WHERE counted)     AS counted;  --  68
--
-- A store-day with exactly one run must be BYTE-IDENTICAL before and after --
-- that is the zero-delta half of the gate:
-- SELECT count(*) FROM rpc_forge_compliance_summary(NULL, current_date-30, current_date)
--  WHERE runs = 1;   -- compare the rows before/after, expect no change
-- =============================================================================
