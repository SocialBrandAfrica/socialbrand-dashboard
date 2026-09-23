-- =============================================================================
-- ENG-187 / ENGINE-CANON-COUNT-LAW §15.1 (PM ruling 2026-09-20). THE UNIT IS THE OBLIGATION.
--
-- APPLIED AND LIVE 2026-09-23 (CC), on Pieter's one-word go. This file is the source of record
-- and reproduces the live objects exactly. PIN: md5 of the four concatenated definitions
-- (both viewdefs + both functiondefs, in the order they appear below) = dda95634c9e552ce8b31aaf5b1143dcf.
-- The gate is worth reading, because it caught something: re-applying this file moved the pin off
-- the migrations' own 6e966a9eaf17ebaf8206153069ca56d1. A function body is stored BYTE-EXACT in
-- prosrc, so the aligned spacing in this file ("p_from   IS NULL") is a different definition from
-- the migration's ("p_from IS NULL") even though the meaning is identical. Semantics were then
-- re-proved behaviourally rather than assumed cosmetic: obligations, excess (0 at every store)
-- and both percentages reproduce to the digit at all five stores. Live now matches THIS file.
--
-- (R28: the header this file carried until 2026-09-23 -- "BUILT AND PROVEN READ-ONLY, NOT
-- APPLIED, the apply was refused three times by the session's auto-mode classifier" -- is
-- retired_on 2026-09-23, superseded_by this header. The refusals were real and are recorded in
-- BUG-LOG ENG-187; the fourth attempt passed.)
--
-- THE DEFECT IT FIXES (three definitions of "counted" at three sites):
--   1. v_forge_count_line_evidence / v_forge_count_compliance: a DIWAINV posting inside
--      [issue, +2] at LINE grain, so one posting is credited to every run that issued the
--      product. Measured: 3.58 issues per obligation on average, up to 40. UNDERSTATES.
--   2. rpc_forge_run_compliance: ANY 'I' posting of ANY module from the issue date onward with
--      NO upper bound. OVERSTATES, and credits a count the list did not cause.
--   3. rpc_forge_compliance_summary: aggregates (2) at row grain across runs.
--
-- THE RULING, three parts:
--   1. THE UNIT IS THE OBLIGATION. An obligation opens at an issue when none is open on that
--      (store, product); a line issued again while still owed is the SAME obligation rolled
--      forward carrying its age; a DIWAINV posting closes exactly one obligation.
--   2. THE WINDOW IS count_window_days FROM THE OBLIGATION'S LAST ISSUE. Inside it the
--      obligation is ADHERED. After it the posting still CLOSES the obligation, because a count
--      is a count, but it is closed_late with its lag. TWO figures leave the engine, never one.
--   3. THE MODULE IS DIWAINV ONLY. Any other 'I' module is named in exception_module and never
--      credited (DIWAZENT, 6 postings ever).
--
-- FIVE DEFECTS WERE FOUND IN THIS BUILD *AFTER* IT WENT LIVE, BY MEASURING IT RATHER THAN BY
-- TRUSTING THE READ-ONLY PROOF. All five are fixed above the line; they are recorded here
-- because the lesson is the R22 one -- the proof run and the live object are not the same thing
-- until the live object has been measured.
--   D1 CORRECTNESS, THE CLOSING-DAY RULE WAS NEVER STATED. Where a store posts a product TWICE
--      on the date that closes an obligation, the first cut picked one row with
--      "ORDER BY qty <> 0 DESC LIMIT 1", which TIES when both rows are zero or both non-zero --
--      the ENG-182 class, where a rebuild flips a column nobody touched. Measured at 10116:
--      10 obligations, 78 issued lines, 2 of the 10 flipping MATCHED vs variance on the tie.
--      They are real double-counts: 21-09, Nkele counts at 15:38 and Pieter re-counts the same
--      products at 17:49 (product 582: -13 to 103, then +1 to 104).
--      THE RULE: the count is the whole day's counting. counted_soh is the LAST posting of the
--      closing date (movement_time, then movement_id); count_delta_qty is the SUM of that date's
--      postings. MATCHED therefore means the day's counting moved nothing. closing_postings is
--      published so a double-count is visible rather than silently netted.
--   D2 CREDITED FIRED ON MORE THAN ONE ROW PER OBLIGATION -- the worst of the five, because it
--      reintroduced the very over-count this row exists to abolish, one layer up. The flag read
--      (issued_date = last_issued_on), so a product issued on TWO RUNS ON THE SAME DATE was
--      credited twice and its single closing posting counted twice. Measured whole history:
--      4,741 credited rows against 3,493 real obligations at 10116; 2,359 excess group-wide.
--      THE RULE: exactly ONE issued line carries credited -- the obligation's LAST issue, and
--      where that date carries several runs, the latest run by issued_at then run_id. Enforced
--      with row_number(), not a date test, so no later reader can double-count by filtering
--      differently. After the fix, credited rows = distinct obligations at every store, exactly.
--   D3 MIXED GRAIN ON ONE RATIO, and it was on the screen. Both consumers -- public/toolkit.html
--      and /api/forge/weekly-report -- do `issued += lines_issued; posted += lines_counted` and
--      render posted/issued. lines_issued was the ISSUED-LINE count while lines_counted was the
--      OBLIGATION count, so every compliance figure on screen would have read about a quarter of
--      the truth. Both are now the obligation unit; issued_lines_raw carries the raw line count.
--   D4 THE VERDICT ACCUSED STORES THAT WERE STILL IN TIME. A list issued TODAY read "PARTIAL --
--      200 obligation(s) owed" and one issued YESTERDAY read "NOT EXECUTED", although
--      count_window_days = 2 leaves the store another day. Adherence is measured at the window's
--      close, so the verdict now reads IN WINDOW until the window shuts.
--   D5 PERFORMANCE. The issued rows were re-joined to the timeline on five columns (a nested
--      loop over CTE scans on a rows=1 estimate) and exception_module ran as a correlated scan
--      PER OUTPUT ROW; the whole-population read did not return inside two minutes, which for
--      `anon` (statement_timeout 30s) means the pane renders "Could not load" -- the exact
--      ENG-179 failure. Fixed by carrying the issue payload through the timeline, so the join is
--      structurally unnecessary, and by probing exception_module ONCE PER OBLIGATION through
--      idx_sigma_moves_store_prod_date. Whole population now returns in seconds.
--
-- CONFIG. count_window_days = 2, store_format '*', DEMO_CALIBRATION, stamped SEED UNDERIVED.
-- Applied 2026-09-23 ahead of this file (the INSERT below is idempotent and will no-op).
--
-- R22, POST-APPLY, MEASURED ON THE LIVE OBJECTS 2026-09-23. Obligations whose last issue falls
-- in the trailing 30 days. The live platform reproduces the read-only proof EXACTLY:
--
--   store | published RPC before | line-grain view | OBLIGATION adherence | closure | obligations
--   10116 |               45.7 % |          19.1 % |               19.4 % |  29.6 % |       2,060
--   21355 |               42.6 % |          23.6 % |               35.2 % |  40.3 % |         290
--   80175 |               21.9 % |          13.1 % |               26.7 % |  42.9 % |       2,100
--   80176 |               38.7 % |          32.0 % |               60.7 % |  61.2 % |         405
--   80579 |                5.6 % |           0.7 % |                2.9 % |   7.5 % |         174
--
-- The figure moves at every store and in BOTH directions, which is what canon predicted. All
-- time, the obligation unit reads 10116 3,493 obligations / 33.5 % adhered / 43.7 % closed,
-- independently reproducing PM's own 2026-09-20 measurement (3,433 / 33.8 %) within three days
-- of drift. Average issues per obligation 3.78 to 7.87, maximum 40: that spread IS the
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
  SELECT r.run_id, r.store_code, r.issued_at, r.issued_at::date AS issued_date,
         l.product_code, l.description, l.stratum, l.soh_at_issue
  FROM public.forge_count_run r
  JOIN public.forge_count_run_line l ON l.run_id = r.run_id
),
lo AS MATERIALIZED (SELECT min(issued_date) - 1 AS floor_date FROM iss),
post AS MATERIALIZED (
  SELECT m.store_code, m.product_code, m.movement_date, m.movement_time, m.movement_id, m.qty, m.new_soh
  FROM public.sigma_movements m
  WHERE m.movement_type = 'I' AND m.module = 'DIWAINV'
    AND m.movement_date >= (SELECT floor_date FROM lo)
),
-- The issue payload rides the timeline. It is NOT joined back afterwards: that join was five
-- columns wide over CTE scans and planned as a nested loop on a rows=1 estimate (D5).
tl AS (
  SELECT store_code, product_code, issued_date AS d, 0 AS is_post, run_id, issued_at,
         description, stratum, soh_at_issue
  FROM iss
  UNION ALL
  SELECT p.store_code, p.product_code, p.movement_date, 1, NULL::uuid, NULL::timestamptz,
         NULL::text, NULL::text, NULL::numeric
  FROM post p
  WHERE EXISTS (SELECT 1 FROM iss i WHERE i.store_code = p.store_code AND i.product_code = p.product_code)
),
-- THE OBLIGATION, deterministic and with no imperative loop: an issue's obligation number is the
-- count of postings strictly before it, so every issue between two postings belongs to the SAME
-- obligation and the posting that closes it is the next one.
seq AS (
  SELECT t.*,
         COALESCE(sum(t.is_post) OVER (PARTITION BY t.store_code, t.product_code
                                       ORDER BY t.d, t.is_post
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::int AS oseq
  FROM tl t
),
oblig AS (
  SELECT store_code, product_code, oseq, min(d) AS opened_on, max(d) AS last_issued_on, count(*)::int AS issues
  FROM seq WHERE is_post = 0 GROUP BY 1,2,3
),
postn AS (
  SELECT store_code, product_code, oseq, min(d) AS counted_date
  FROM seq WHERE is_post = 1 GROUP BY 1,2,3
),
closed AS (
  SELECT o.store_code, o.product_code, o.oseq, o.opened_on, o.last_issued_on, o.issues,
         pn.counted_date, p.count_delta_qty, p.counted_soh, p.closing_postings, xm.exception_module
  FROM oblig o
  LEFT JOIN postn pn ON pn.store_code = o.store_code AND pn.product_code = o.product_code AND pn.oseq = o.oseq
  -- THE CLOSING DAY IS THE UNIT OF COUNTING (D1). The balance is the LAST posting of the date;
  -- the delta is the SUM of the date's postings. Both cast back to the declared numeric(14,4),
  -- because sum() widens the type and a view replace refuses the widening.
  LEFT JOIN LATERAL (
    SELECT sum(px.qty)::numeric(14,4) AS count_delta_qty,
           (array_agg(px.new_soh ORDER BY px.movement_time DESC NULLS LAST, px.movement_id DESC))[1]::numeric(14,4) AS counted_soh,
           count(*)::int AS closing_postings
    FROM post px
    WHERE px.store_code = o.store_code AND px.product_code = o.product_code
      AND px.movement_date = pn.counted_date
  ) p ON pn.counted_date IS NOT NULL
  -- ONE index probe per obligation, not one scan per output row (D5).
  LEFT JOIN LATERAL (
    SELECT min(x.module) AS exception_module
    FROM public.sigma_movements x
    WHERE x.store_code = o.store_code AND x.product_code = o.product_code
      AND x.movement_date BETWEEN o.opened_on AND o.last_issued_on + (SELECT win FROM cfg)
      AND x.movement_type = 'I' AND x.module <> 'DIWAINV'
  ) xm ON true
),
-- EXACTLY ONE ROW PER OBLIGATION CARRIES credited (D2). A date test credits twice when a product
-- is issued on two runs in one day, and counts the single closing posting twice.
joined AS (
  SELECT s.run_id, s.store_code, s.d, s.product_code, s.description, s.stratum, s.soh_at_issue, s.oseq,
         c.counted_date, c.count_delta_qty, c.counted_soh, c.closing_postings, c.exception_module,
         c.opened_on, c.last_issued_on, c.issues,
         row_number() OVER (PARTITION BY s.store_code, s.product_code, s.oseq
                            ORDER BY s.d DESC, s.issued_at DESC, s.run_id DESC) AS rn
  FROM seq s
  JOIN closed c ON c.store_code = s.store_code AND c.product_code = s.product_code AND c.oseq = s.oseq
  WHERE s.is_post = 0
)
SELECT j.run_id, j.store_code, j.d AS issued_date, j.product_code, j.description, j.stratum, j.soh_at_issue,
       j.counted_date, j.count_delta_qty, j.counted_soh,
       (j.counted_date IS NOT NULL) AS counted,
       (j.store_code || ':' || j.product_code || ':' || j.oseq) AS obligation_id,
       j.opened_on AS obligation_opened_on,
       j.last_issued_on AS obligation_last_issued_on,
       j.issues AS obligation_issues,
       (j.rn = 1) AS credited,
       (j.counted_date IS NOT NULL AND j.counted_date <= j.last_issued_on + (SELECT win FROM cfg)) AS adhered,
       (j.counted_date IS NOT NULL AND j.counted_date >  j.last_issued_on + (SELECT win FROM cfg)) AS closed_late,
       (j.counted_date - j.last_issued_on)::int AS lag_days,
       CASE WHEN j.counted_date IS NULL THEN (CURRENT_DATE - j.last_issued_on)::int END AS open_age_days,
       CASE WHEN j.counted_date IS NULL THEN NULL
            WHEN j.count_delta_qty = 0 THEN 'MATCHED'
            WHEN j.counted_soh = 0     THEN 'COUNTED_TO_ZERO'
            ELSE 'RECOUNTED' END AS count_outcome,
       j.exception_module,
       (SELECT win FROM cfg) AS window_days,
       j.closing_postings
FROM joined j;

COMMENT ON VIEW public.v_forge_count_line_evidence IS
'GRADE: CALCULATED. ENGINE-CANON-COUNT-LAW 15.1, ENG-187. Every issued count line, with its OBLIGATION. An obligation opens at an issue when none is open on that (store, product); a re-issue while it is still owed is the same obligation rolled forward carrying its age; the first DIWAINV posting after it closes it. Adherence is read on the OBLIGATION, never the issued line: read rows WHERE credited. EXACTLY ONE ROW PER OBLIGATION CARRIES credited -- its last issue, and where that date carries several runs, the latest run by issued_at then run_id. It is enforced with row_number(), not with a date test, because a date test credits twice when a product is issued on two runs on one day and counts the single posting twice. adhered = closed within count_window_days of the obligation''s LAST issue. closed_late = closed after it, which still closes the obligation because a count is a count, but the list did not cause it. THE CLOSING DAY IS THE UNIT OF COUNTING: where a store posts the same product more than once on the closing date, counted_soh is the LAST posting of that date (movement_time, then movement_id) and count_delta_qty is the SUM of that date''s postings, so MATCHED means the day''s counting moved nothing; closing_postings shows how many postings there were. Module DIWAINV only; any other I module is named in exception_module and never credited. Two figures leave this view, never one: adherence and closure.';

-- ---------------------------------------------------------------------------
-- 2. RUN GRAIN. The obligation columns lead; the legacy names stay as aliases.
--    NOTE: this view is DROPPED and recreated, not replaced -- CREATE OR REPLACE VIEW cannot
--    reorder columns, and the obligation columns sit ahead of the legacy ones. Checked before
--    the drop: no function and no view depends on it, and the toolkit's pane was repointed onto
--    rpc_forge_compliance_summary at ENG-179 (commit 70f7bbb).
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_forge_count_compliance;

CREATE VIEW public.v_forge_count_compliance AS
SELECT r.run_id, r.store_code, r.issued_at::date AS issued_date, r.source, r.mode,
       r.line_count AS lines_issued,
       count(*) FILTER (WHERE e.credited)::int AS obligations,
       count(*) FILTER (WHERE e.credited AND e.adhered)::int AS obligations_adhered,
       count(*) FILTER (WHERE e.credited AND e.closed_late)::int AS obligations_closed_late,
       count(*) FILTER (WHERE e.credited AND e.counted)::int AS obligations_closed,
       count(*) FILTER (WHERE e.credited AND NOT e.counted)::int AS obligations_open,
       count(*) FILTER (WHERE e.credited AND e.count_outcome = 'MATCHED')::int AS matched_posted,
       count(*) FILTER (WHERE e.credited AND e.count_outcome IS NOT NULL AND e.count_outcome <> 'MATCHED')::int AS variance_posted,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS adherence_pct,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.counted) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS closure_pct,
       count(*) FILTER (WHERE e.credited AND e.counted)::int AS lines_posted,
       round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS pct_counted
FROM public.forge_count_run r
LEFT JOIN public.v_forge_count_line_evidence e ON e.run_id = r.run_id
GROUP BY r.run_id, r.store_code, r.issued_at, r.source, r.mode, r.line_count;

COMMENT ON VIEW public.v_forge_count_compliance IS
'GRADE: CALCULATED. ENG-187 / count law 15.1. Run grain on the OBLIGATION unit. adherence_pct = closed inside count_window_days of the obligation''s last issue; closure_pct = closed at all. lines_posted and pct_counted are kept as aliases so an older reader does not break. An obligation issued on several runs is credited to its LAST issue only, so one posting can never be counted twice.';

-- ---------------------------------------------------------------------------
-- 3. THE PUBLISHED INTERFACES (R30 §1). Both are DROPPED and recreated: their OUT-parameter row
--    type gains the obligation columns, which CREATE OR REPLACE FUNCTION cannot do. Grants are
--    restored in the same transaction, so no window exists where a caller sees a missing function.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_forge_run_compliance(uuid);
DROP FUNCTION IF EXISTS public.rpc_forge_compliance_summary(text[], date, date);

CREATE FUNCTION public.rpc_forge_run_compliance(p_run_id uuid)
RETURNS TABLE(run_id uuid, store_code text, product_code bigint, stratum text, description text,
              soh_at_issue numeric, last_counted_at_issue date, counted_on date, counted boolean,
              days_outstanding integer, story text,
              obligation_id text, credited boolean, adhered boolean, closed_late boolean,
              lag_days integer, obligation_issues integer, count_outcome text, exception_module text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.run_id, e.store_code, e.product_code, e.stratum, e.description, e.soh_at_issue,
         e.obligation_opened_on AS last_counted_at_issue,
         e.counted_date AS counted_on,
         e.counted,
         e.open_age_days AS days_outstanding,
         CASE
           WHEN e.adhered THEN 'Counted ' || e.counted_date || ', inside the ' || e.window_days
                               || '-day window from the last issue ' || e.obligation_last_issued_on
                               || CASE WHEN e.closing_postings > 1
                                       THEN ' (counted ' || e.closing_postings || ' times that day)' ELSE '' END
           WHEN e.closed_late THEN 'Counted ' || e.counted_date || ', ' || e.lag_days
                               || ' day(s) after the window closed. The count stands, the list did not cause it'
           WHEN e.open_age_days <= e.window_days
             THEN 'Not yet counted -- day ' || e.open_age_days || ' of the ' || e.window_days
                  || '-day window, still in time'
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

-- lines_issued and lines_counted are BOTH the obligation unit, because both consumers divide one
-- by the other (D3). issued_lines_raw carries the raw issued-line count.
CREATE FUNCTION public.rpc_forge_compliance_summary(p_stores text[] DEFAULT NULL::text[],
                                                    p_from date DEFAULT NULL::date,
                                                    p_to date DEFAULT NULL::date)
RETURNS TABLE(store_code text, issue_date date, runs integer, lines_issued integer, lines_counted integer,
              compliance_pct numeric, oldest_outstanding_days integer, verdict text,
              obligations integer, adhered integer, closed_late integer, still_open integer,
              adherence_pct numeric, closure_pct numeric, issued_lines_raw integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT e.store_code, e.issued_date AS issue_date,
         count(DISTINCT e.run_id)::int AS runs,
         count(*) FILTER (WHERE e.credited)::int AS lines_issued,
         count(*) FILTER (WHERE e.credited AND e.adhered)::int AS lines_counted,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS compliance_pct,
         max(e.open_age_days) FILTER (WHERE e.credited)::int AS oldest_outstanding_days,
         CASE
           WHEN count(*) FILTER (WHERE e.credited) = 0
             THEN 'EMPTY RUN -- nothing was owed on this list'
           WHEN count(*) FILTER (WHERE e.credited AND e.counted) = count(*) FILTER (WHERE e.credited)
             THEN 'COMPLETE'
           WHEN count(*) FILTER (WHERE e.credited AND e.counted) = 0
                AND COALESCE(max(e.open_age_days) FILTER (WHERE e.credited), 0) <= max(e.window_days)
             THEN 'IN WINDOW -- ' || count(*) FILTER (WHERE e.credited)::text
                  || ' obligation(s), still inside the ' || max(e.window_days)::text || '-day window'
           WHEN count(*) FILTER (WHERE e.credited AND e.counted) = 0
             THEN 'NOT EXECUTED -- no obligation on this list was counted'
           WHEN COALESCE(max(e.open_age_days) FILTER (WHERE e.credited), 0) <= max(e.window_days)
             THEN 'PARTIAL, IN WINDOW -- ' || count(*) FILTER (WHERE e.credited AND NOT e.counted)::text
                  || ' obligation(s) still owed, inside the ' || max(e.window_days)::text || '-day window'
           ELSE 'PARTIAL -- ' || count(*) FILTER (WHERE e.credited AND NOT e.counted)::text || ' obligation(s) owed'
         END AS verdict,
         count(*) FILTER (WHERE e.credited)::int AS obligations,
         count(*) FILTER (WHERE e.credited AND e.adhered)::int AS adhered,
         count(*) FILTER (WHERE e.credited AND e.closed_late)::int AS closed_late,
         count(*) FILTER (WHERE e.credited AND NOT e.counted)::int AS still_open,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.adhered) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS adherence_pct,
         round(100.0 * count(*) FILTER (WHERE e.credited AND e.counted) / NULLIF(count(*) FILTER (WHERE e.credited), 0), 1) AS closure_pct,
         count(*)::int AS issued_lines_raw
  FROM public.v_forge_count_line_evidence e
  WHERE (p_stores IS NULL OR e.store_code = ANY(p_stores))
    AND (p_from   IS NULL OR e.issued_date >= p_from)
    AND (p_to     IS NULL OR e.issued_date <= p_to)
  GROUP BY e.store_code, e.issued_date
  ORDER BY e.issued_date DESC, e.store_code;
$function$;

COMMENT ON FUNCTION public.rpc_forge_compliance_summary(text[], date, date) IS
'ENG-187 / count law 15.1. Store-day grain on the OBLIGATION unit. lines_issued and lines_counted are BOTH obligations, because the consumers divide one by the other; issued_lines_raw carries the raw issued-line count. compliance_pct = adherence. The verdict reads IN WINDOW while count_window_days has not elapsed, and only calls a list NOT EXECUTED once the window has shut.';

REVOKE ALL ON FUNCTION public.rpc_forge_run_compliance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_forge_compliance_summary(text[], date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_forge_run_compliance(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_forge_compliance_summary(text[], date, date) TO anon, authenticated, service_role;
REVOKE ALL ON public.v_forge_count_line_evidence FROM PUBLIC;
REVOKE ALL ON public.v_forge_count_compliance FROM PUBLIC;
GRANT SELECT ON public.v_forge_count_line_evidence, public.v_forge_count_compliance TO anon, authenticated, service_role;

-- DONE AFTER THE APPLY, 2026-09-23:
--  1. The R22 table above was re-run on the live objects and reproduces the read-only proof
--     exactly, per store, both directions.
--  2. The toolkit Count-compliance pane and /api/forge/weekly-report were repointed onto the
--     obligation unit in the same pass (D3) and walked.
--  3. The pre-ENG-187 figures stay in BUG-LOG ENG-187 with their date. Nothing is silently
--     restated.
