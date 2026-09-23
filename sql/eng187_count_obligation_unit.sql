-- =============================================================================
-- ENG-187 / ENGINE-CANON-COUNT-LAW §15.1 (PM ruling 2026-09-20). THE UNIT IS THE OBLIGATION.
--
-- BUILT AND PROVEN READ-ONLY 2026-09-23 (CC). **NOT APPLIED** -- the apply was refused three
-- times by the session's auto-mode classifier as a production deploy. One go applies this file
-- as written; nothing in it is conditional on the day it runs.
--
-- THE DEFECT (three definitions of "counted" at three sites):
--   1. v_forge_count_line_evidence / v_forge_count_compliance: a DIWAINV posting inside
--      [issue, +2] at LINE grain, so one posting is credited to every run that issued the
--      product. Measured: 3.58 issues per obligation on average, up to 40. UNDERSTATES.
--   2. rpc_forge_run_compliance: ANY 'I' posting of ANY module from the issue date onward with
--      NO upper bound. OVERSTATES, and credits a count the list did not cause.
--   3. rpc_forge_compliance_summary: aggregates (2) at row grain across runs.
--
-- THE RULING, three parts, built here:
--   1. THE UNIT IS THE OBLIGATION. An obligation opens at an issue when none is open on that
--      (store, product); a line issued again while still owed is the SAME obligation rolled
--      forward carrying its age; a DIWAINV posting closes exactly one obligation.
--   2. THE WINDOW IS count_window_days FROM THE OBLIGATION'S LAST ISSUE. Inside it the
--      obligation is ADHERED. After it the posting still CLOSES the obligation, because a count
--      is a count, but it is closed_late with its lag. TWO figures leave the engine, never one.
--   3. THE MODULE IS DIWAINV ONLY. Any other 'I' module is named in exception_module and never
--      credited (DIWAZENT, 6 postings ever).
--
-- CONFIG. count_window_days = 2, store_format '*', DEMO_CALIBRATION, stamped SEED UNDERIVED.
-- APPLIED 2026-09-23 ahead of this file (the INSERT below is idempotent and will no-op).
--
-- R22, READ-ONLY, WHOLE POPULATION, run 2026-09-23 before any apply. Obligations whose last
-- issue falls in the trailing 30 days, against the two figures the platform publishes today:
--
--   store | published RPC | line-grain view | OBLIGATION adherence | closure
--   10116 |        45.7 % |          19.1 % |               19.4 % |  29.6 %
--   21355 |        42.6 % |          23.6 % |               35.2 % |  40.3 %
--   80175 |        21.9 % |          13.1 % |               26.7 % |  42.9 %
--   80176 |        38.7 % |          32.0 % |               60.7 % |  61.2 %
--   80579 |         5.6 % |           0.7 % |                2.9 % |   7.5 %
--
-- The figure moves at every store and in BOTH directions, which is what canon predicted. All
-- time, the obligation unit reads 10116 3,493 obligations / 33.5 % adhered / 43.7 % closed,
-- independently reproducing PM's own 2026-09-20 measurement (3,433 / 33.8 %) within three days
-- of drift. Average issues per obligation 3.22 to 4.86, maximum 40: that spread IS the
-- over-counting the line grain was doing.
-- =============================================================================

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT 'count_window_days', '*', 2, 'DEMO_CALIBRATION', DATE '2026-09-20',
       'SEED, UNDERIVED (CANON-DOCTRINE 0h point 2). ENGINE-CANON-COUNT-LAW 15.1: the days from an obligation''s last issue inside which a DIWAINV posting counts as ADHERENCE. 2 is the value the views already carried as a literal; the derivation off the posting-lag distribution is owed work.'
WHERE NOT EXISTS (SELECT 1 FROM public.forge_config WHERE config_key = 'count_window_days' AND store_format = '*');

-- ---------------------------------------------------------------------------
-- 1. THE ONE HOME. Every issued line, with its obligation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_forge_count_line_evidence AS
WITH cfg AS (
  SELECT COALESCE((SELECT fc.value_num FROM public.forge_config fc
                    WHERE fc.config_key = 'count_window_days' AND fc.store_format = '*'
                      AND fc.retired_on IS NULL), 2)::int AS win
),
iss AS MATERIALIZED (
  SELECT r.run_id, r.store_code, r.issued_at, r.issued_at::date AS issued_date, r.source, r.mode,
         l.product_code, l.description, l.stratum, l.soh_at_issue, l.last_counted_at_issue
  FROM public.forge_count_run r
  JOIN public.forge_count_run_line l ON l.run_id = r.run_id
),
lo AS MATERIALIZED (SELECT min(issued_date) - 1 AS floor_date FROM iss),
post AS MATERIALIZED (
  SELECT m.store_code, m.product_code, m.movement_date, m.qty, m.new_soh
  FROM public.sigma_movements m
  WHERE m.movement_type = 'I' AND m.module = 'DIWAINV'
    AND m.movement_date >= (SELECT floor_date FROM lo)
),
-- One timeline per (store, product). A posting on the SAME date as an issue does not close an
-- earlier obligation than the one that issue opens, so issues sort before postings on a tie.
tl AS (
  SELECT store_code, product_code, issued_date AS d, 0 AS is_post, run_id
  FROM iss
  UNION ALL
  SELECT p.store_code, p.product_code, p.movement_date, 1, NULL::uuid
  FROM post p
  WHERE EXISTS (SELECT 1 FROM iss i WHERE i.store_code = p.store_code AND i.product_code = p.product_code)
),
seq AS (
  SELECT t.*,
         COALESCE(sum(t.is_post) OVER (PARTITION BY t.store_code, t.product_code
                                       ORDER BY t.d, t.is_post
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::int AS oseq
  FROM tl t
),
oblig AS (
  SELECT store_code, product_code, oseq,
         min(d) AS opened_on, max(d) AS last_issued_on, count(*)::int AS issues
  FROM seq WHERE is_post = 0 GROUP BY 1,2,3
),
postn AS (
  SELECT s.store_code, s.product_code, s.oseq, min(s.d) AS counted_date
  FROM seq s WHERE s.is_post = 1 GROUP BY 1,2,3
),
closed AS (
  SELECT o.*, pn.counted_date, p.qty AS count_delta_qty, p.new_soh AS counted_soh
  FROM oblig o
  LEFT JOIN postn pn ON pn.store_code = o.store_code AND pn.product_code = o.product_code AND pn.oseq = o.oseq
  LEFT JOIN LATERAL (
    SELECT px.qty, px.new_soh FROM post px
    WHERE px.store_code = o.store_code AND px.product_code = o.product_code AND px.movement_date = pn.counted_date
    ORDER BY px.qty <> 0 DESC LIMIT 1
  ) p ON true
),
keyed AS (
  SELECT i.*, s.oseq
  FROM iss i
  JOIN seq s ON s.store_code = i.store_code AND s.product_code = i.product_code
            AND s.is_post = 0 AND s.run_id = i.run_id AND s.d = i.issued_date
)
SELECT k.run_id,
       k.store_code,
       k.issued_date,
       k.product_code,
       k.description,
       k.stratum,
       k.soh_at_issue,
       c.counted_date,
       c.count_delta_qty,
       c.counted_soh,
       (c.counted_date IS NOT NULL)                                   AS counted,
       (k.store_code || ':' || k.product_code || ':' || k.oseq)        AS obligation_id,
       c.opened_on                                                    AS obligation_opened_on,
       c.last_issued_on                                               AS obligation_last_issued_on,
       c.issues                                                       AS obligation_issues,
       (k.issued_date = c.last_issued_on)                             AS credited,
       (c.counted_date IS NOT NULL AND c.counted_date <= c.last_issued_on + (SELECT win FROM cfg)) AS adhered,
       (c.counted_date IS NOT NULL AND c.counted_date >  c.last_issued_on + (SELECT win FROM cfg)) AS closed_late,
       (c.counted_date - c.last_issued_on)::int                       AS lag_days,
       CASE WHEN c.counted_date IS NULL THEN (CURRENT_DATE - c.last_issued_on)::int END AS open_age_days,
       CASE WHEN c.counted_date IS NULL THEN NULL
            WHEN c.count_delta_qty = 0 THEN 'MATCHED'
            WHEN c.counted_soh = 0     THEN 'COUNTED_TO_ZERO'
            ELSE 'RECOUNTED' END                                      AS count_outcome,
       (SELECT min(x.module) FROM public.sigma_movements x
         WHERE x.store_code = k.store_code AND x.product_code = k.product_code
           AND x.movement_type = 'I' AND x.module <> 'DIWAINV'
           AND x.movement_date BETWEEN c.opened_on AND c.last_issued_on + (SELECT win FROM cfg)) AS exception_module,
       (SELECT win FROM cfg)                                          AS window_days
FROM keyed k
JOIN closed c ON c.store_code = k.store_code AND c.product_code = k.product_code AND c.oseq = k.oseq;

COMMENT ON VIEW public.v_forge_count_line_evidence IS
'GRADE: CALCULATED. ENGINE-CANON-COUNT-LAW 15.1, ENG-187. Every issued count line, with its OBLIGATION. An obligation opens at an issue when none is open on that (store, product); a re-issue while it is still owed is the same obligation rolled forward carrying its age; a DIWAINV posting closes exactly one obligation. Adherence is read on the OBLIGATION, never the issued line: read rows WHERE credited. adhered = closed within count_window_days of the obligation''s LAST issue. closed_late = closed after it, which still closes the obligation because a count is a count, but the list did not cause it. Module DIWAINV only; any other I module is named in exception_module and never credited. Two figures leave this view, never one: adherence and closure. The shrinkage split (count_outcome COUNTED_TO_ZERO against RECOUNTED) publishes nothing until counted_soh has a second instrument (R28 addendum 4).';

-- ---------------------------------------------------------------------------
-- 2. Run grain, on the obligation unit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_forge_count_compliance AS
SELECT r.run_id,
       r.store_code,
       r.issued_at::date AS issued_date,
       r.source,
       r.mode,
       r.line_count                                                    AS lines_issued,
       count(*) FILTER (WHERE e.credited)::int                         AS obligations,
       count(*) FILTER (WHERE e.credited AND e.adhered)::int           AS obligations_adhered,
       count(*) FILTER (WHERE e.credited AND e.closed_late)::int       AS obligations_closed_late,
       count(*) FILTER (WHERE e.credited AND e.counted)::int           AS obligations_closed,
       count(*) FILTER (WHERE e.credited AND NOT e.counted)::int       AS obligations_open,
       count(*) FILTER (WHERE e.credited AND e.count_outcome = 'MATCHED')::int  AS matched_posted,
       count(*) FILTER (WHERE e.credited AND e.count_outcome IS NOT NULL
                          AND e.count_outcome <> 'MATCHED')::int       AS variance_posted,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered)
             / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS adherence_pct,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.counted)
             / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS closure_pct,
       count(*) FILTER (WHERE e.credited AND e.counted)::int           AS lines_posted,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered)
             / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS pct_counted
FROM public.forge_count_run r
LEFT JOIN public.v_forge_count_line_evidence e ON e.run_id = r.run_id
GROUP BY r.run_id, r.store_code, r.issued_at, r.source, r.mode, r.line_count;

COMMENT ON VIEW public.v_forge_count_compliance IS
'GRADE: CALCULATED. ENG-187 / count law 15.1. Run grain on the OBLIGATION unit. adherence_pct = closed inside count_window_days of the obligation''s last issue; closure_pct = closed at all. lines_posted and pct_counted are kept as aliases so an older reader does not break. An obligation issued on several runs is credited to its LAST issue only, so one posting can never be counted twice.';

-- ---------------------------------------------------------------------------
-- 3. The two published readers, repointed at the one home. Existing columns keep their names
--    and order (every consumer reads by name); the obligation columns are APPENDED.
--    Consumers: src/app/api/forge/run/route.js, src/app/api/forge/weekly-report/route.js,
--    public/toolkit.html.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_forge_run_compliance(p_run_id uuid)
RETURNS TABLE(run_id uuid, store_code text, product_code bigint, stratum text, description text,
              soh_at_issue numeric, last_counted_at_issue date, counted_on date, counted boolean,
              days_outstanding integer, story text,
              obligation_id text, credited boolean, adhered boolean, closed_late boolean,
              lag_days integer, obligation_issues integer, count_outcome text, exception_module text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.run_id, e.store_code, e.product_code, e.stratum, e.description, e.soh_at_issue,
         e.obligation_opened_on AS last_counted_at_issue,
         e.counted_date         AS counted_on,
         e.counted,
         e.open_age_days        AS days_outstanding,
         CASE
           WHEN e.adhered      THEN 'Counted ' || e.counted_date || ', inside the ' || e.window_days
                                    || '-day window from the last issue ' || e.obligation_last_issued_on
           WHEN e.closed_late  THEN 'Counted ' || e.counted_date || ', ' || e.lag_days
                                    || ' day(s) after the window closed. The count stands, the list did not cause it'
           WHEN e.open_age_days = 0 THEN 'Issued today, not yet counted'
           ELSE 'NOT COUNTED -- ' || e.open_age_days || ' day(s) owed since ' || e.obligation_last_issued_on
                || CASE WHEN e.obligation_issues > 1
                        THEN ', issued ' || e.obligation_issues || ' times on this obligation since ' || e.obligation_opened_on
                        ELSE '' END
         END AS story,
         e.obligation_id, e.credited, e.adhered, e.closed_late, e.lag_days, e.obligation_issues,
         e.count_outcome, e.exception_module
  FROM public.v_forge_count_line_evidence e
  WHERE e.run_id = p_run_id
  ORDER BY e.counted, e.stratum, e.product_code;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_forge_compliance_summary(p_stores text[] DEFAULT NULL::text[],
                                                               p_from date DEFAULT NULL::date,
                                                               p_to date DEFAULT NULL::date)
RETURNS TABLE(store_code text, issue_date date, runs integer, lines_issued integer, lines_counted integer,
              compliance_pct numeric, oldest_outstanding_days integer, verdict text,
              obligations integer, adhered integer, closed_late integer, still_open integer,
              adherence_pct numeric, closure_pct numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.store_code,
         e.issued_date                                                   AS issue_date,
         count(DISTINCT e.run_id)::int                                   AS runs,
         count(*)::int                                                   AS lines_issued,
         count(*) FILTER (WHERE e.credited AND e.adhered)::int           AS lines_counted,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered)
               / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS compliance_pct,
         max(e.open_age_days)::int                                       AS oldest_outstanding_days,
         CASE
           WHEN count(*) FILTER (WHERE e.credited) = 0
             THEN 'EMPTY RUN -- nothing was owed on this list'
           WHEN count(*) FILTER (WHERE e.credited AND e.counted) = count(*) FILTER (WHERE e.credited)
             THEN 'COMPLETE'
           WHEN count(*) FILTER (WHERE e.credited AND e.counted) = 0 AND max(e.open_age_days) > 0
             THEN 'NOT EXECUTED -- no obligation on this list was counted'
           ELSE 'PARTIAL -- ' || count(*) FILTER (WHERE e.credited AND NOT e.counted)::text || ' obligation(s) owed'
         END                                                             AS verdict,
         count(*) FILTER (WHERE e.credited)::int                         AS obligations,
         count(*) FILTER (WHERE e.credited AND e.adhered)::int           AS adhered,
         count(*) FILTER (WHERE e.credited AND e.closed_late)::int       AS closed_late,
         count(*) FILTER (WHERE e.credited AND NOT e.counted)::int       AS still_open,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered)
               / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS adherence_pct,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.counted)
               / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1)       AS closure_pct
  FROM public.v_forge_count_line_evidence e
  WHERE (p_stores IS NULL OR e.store_code = ANY(p_stores))
    AND (p_from   IS NULL OR e.issued_date >= p_from)
    AND (p_to     IS NULL OR e.issued_date <= p_to)
  GROUP BY e.store_code, e.issued_date
  ORDER BY e.issued_date DESC, e.store_code;
$function$;

REVOKE ALL ON FUNCTION public.rpc_forge_run_compliance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_forge_compliance_summary(text[], date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_forge_run_compliance(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_forge_compliance_summary(text[], date, date) TO anon, authenticated, service_role;
REVOKE ALL ON public.v_forge_count_line_evidence FROM PUBLIC;
REVOKE ALL ON public.v_forge_count_compliance FROM PUBLIC;
GRANT SELECT ON public.v_forge_count_line_evidence, public.v_forge_count_compliance TO anon, authenticated, service_role;

-- AFTER THE APPLY, IN THIS ORDER:
--  1. Re-run the R22 table above and publish the moved figure per store, both directions.
--  2. Walk the toolkit Progress pane and /api/forge/weekly-report as a fresh user: the numbers
--     move, so the walk is the R31 half.
--  3. The old figures stay in BUG-LOG ENG-187 with their date. Nothing is silently restated.
