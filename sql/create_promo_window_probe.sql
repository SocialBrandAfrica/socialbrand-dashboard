-- create_promo_window_probe.sql
--
-- ENG-082 -- THE PROMO ORDER WINDOW PROBE. Pieter's spot check, made into evidence.
-- APPLIED 2026-09-09. Migrations: eng082_promo_window_probe,
--   eng082_promo_probe_first_capture_and_schedule,
--   eng082_promo_probe_record_floor_observation.
-- CORRECTED 2026-09-10 09:13 SAST. Migrations: eng082_probe_upsert_never_wipes_observations,
--   eng082_restore_20260909_floor_observations.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog 2026-09-10 09:2x SAST
-- (pg_get_functiondef, pg_attribute, pg_constraint, pg_policies, relacl, cron.job).
-- capture_promo_window_probe() live md5 9ad02d964c79e0268236429ce260e72b.
-- Until this commit the file was header-only: three live objects with no committed
-- source, the ENG-175 gap, and the gap was CC's own. Re-applying this file reproduces live.
--
-- ============================================================================
-- A DEFECT CC INTRODUCED, FOUND THE MORNING AFTER, FIXED AND REVERSED
-- ============================================================================
-- The first capture did DELETE-for-today then INSERT, and the INSERT never carried
-- observed_*. So the nightly 20:45 SAST run DESTROYED every floor observation recorded
-- earlier the same day -- all fourteen from Pieter's 2026-09-09 round (seven promos x
-- two stores). Found 2026-09-10 ~09:1x SAST.
--   FIX:     eng082_probe_upsert_never_wipes_observations. The capture is an UPSERT on
--            the primary key that refreshes the MEASURED columns only and never writes
--            observed_orderable / observed_by / observed_at. There is no DELETE anywhere.
--   RESTORE: eng082_restore_20260909_floor_observations. All fourteen back on the
--            2026-09-09 rows (219 rows that day, 14 observed, verified after the write).
--            observed_at reads the RESTORE time, so observed_by carries the true
--            provenance: "PG 2026-09-09 ~18:30 SAST, restored from BUG-LOG ENG-082 add.3".
--            Restored from the log, not re-observed, and every row says so.
-- They survived only because the same observations were ALSO written to BUG-LOG that
-- night. A floor observation kept in one place is one bad capture from gone.
--
-- TWO OPERATING FACTS, both deductive from the code below:
--   * TODAY'S ROWS DO NOT EXIST UNTIL 20:45 SAST. An observation made during the day
--     finds no row for CURRENT_DATE, and rpc_promo_probe_observe returns recorded 0 with
--     a warning -- it records NOTHING. Run SELECT capture_promo_window_probe(); first
--     (an idempotent upsert now), then observe. The 20:45 run keeps the observation.
--   * CURRENT_DATE is the DATABASE date, which is UTC (the ENG-117 sibling). The 18:45
--     UTC schedule is safe; an observation recorded 00:00-02:00 SAST lands on the
--     previous day unless p_date is passed.
--
-- ============================================================================
-- WHY IT EXISTS
-- ============================================================================
-- We cannot see "open for ordering" anywhere in the mirror. Measured whole-population:
-- 0 of 4,843 FUTURE promo lines carry a cost, and on a future row only `new_price` and
-- `start_date` vary at all. So the opening signal is absent. The CLOSING signal is
-- absent too, and we now have a hard bracket on it: RH4 ended 2026-09-08 and is still
-- orderable at +1 day; PH1 ended 2026-08-17 and is shut at +23. Somewhere in between,
-- the DC closes the window -- and the engine currently closes it ON the end date, which
-- is why the last-bite discount is lost.
--
-- PIETER'S DESIGN, and it is the right one: watch a promo daily until it shuts, then
-- look back at our own feed for that day and ask whether ANYTHING moved.
--
-- THE INSTRUMENT IS `row_fingerprint`, and it is what makes the test conclusive.
-- It is an md5 over the ENTIRE line set -- product, status, list_cost, new_price,
-- old_price, discount_pct, start_date, end_date -- ordered. **We therefore do not have
-- to guess which field might carry the signal.** If the promo shuts and the fingerprint
-- has not moved, then NO field moved, and Pieter's hypothesis is proven: the SPAR DC
-- closes the window manually on their side and no signal exists in the feed to find.
-- **That negative result is a real finding, not a failed search** -- it converts an
-- open-ended hunt into a closed question and sends the fix to F1a (extract Sigma's own
-- order-deadline field) instead of to another seed.
--
-- ============================================================================
-- A CANDIDATE ALREADY TESTED AND REJECTED -- do not re-run it
-- ============================================================================
-- "A promo still holding status-0 lines is still open" looked strong: PH1 (shut) is all
-- status 2, RH4 (open) is mixed. Tested across every 2026 promo at both SPARs it is a
-- GRADIENT, NOT A SWITCH: still selling 89.3% mixed · ended 1-7d 62.5% · 8-21d 44.4% ·
-- 22-60d 43.3% · 60+d 2.6%. The two buckets either side of the boundary that matters are
-- 44.4 and 43.3, and PH1 sits where 43% are still mixed. Day-zero capture shows the same
-- noise directly: PH6 holds 24 status-0 lines at +10 days while QH1 is fully closed at +9.
--
-- ============================================================================
-- HOW TO RUN THE CHECK
-- ============================================================================
--   1. The snapshot takes itself daily -- pg_cron `promo-window-probe-daily`,
--      18:45 UTC = 20:45 SAST, after the extractor refreshes the promo tables.
--   2. Pieter opens the Sigma promo order screen and sees whether RH4 still takes an
--      order. One look, no system.
--   3. Record it (before 20:45 SAST, capture first -- see OPERATING FACTS above):
--        SELECT capture_promo_window_probe();
--        SELECT rpc_promo_probe_observe('RH4', true);      -- or false
--      Optionally per store:  rpc_promo_probe_observe('RH4', false, '10116')
--   4. When it flips to false, diff the fingerprints either side of that date:
--        SELECT probe_date, suffix, store_code, days_past_end, observed_orderable,
--               row_fingerprint, lines_status0, lines_status2, lines_with_cost
--          FROM promo_window_probe WHERE upper(suffix)='RH4' ORDER BY probe_date;
--      A moving fingerprint on the closing date names the field. A still one closes
--      the question the other way.
--
-- Scope is deliberately narrow: promos ending between CURRENT_DATE-60 and +90, which is
-- the only region where the boundary can be observed. Grants: writers revoked from
-- PUBLIC and anon, granted to authenticated and service_role; the table reads to anon.
--
-- The detailed hunt for the true opening and closing signal is a DEDICATED SESSION
-- (Pieter, 2026-09-09: "it's clearly not the obvious ones"). This probe is what gives
-- that session evidence to start from instead of a blank page.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.promo_window_probe (
  probe_date          date        NOT NULL DEFAULT CURRENT_DATE,
  store_code          text        NOT NULL,
  promo_nr            bigint      NOT NULL,
  suffix              text,
  start_date          date,
  end_date            date,
  days_past_end       integer,
  hdr_status          text,
  lines               integer,
  lines_status0       integer,
  lines_status2       integer,
  lines_with_cost     integer,
  distinct_new_price  integer,
  row_fingerprint     text,
  observed_orderable  boolean,
  observed_by         text,
  observed_at         timestamptz,
  captured_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT promo_window_probe_pkey PRIMARY KEY (probe_date, store_code, promo_nr)
);

COMMENT ON TABLE public.promo_window_probe IS
'GRADE: RAW. ENG-082 probe. Daily snapshot of every promo near its boundary, so that when the floor observes a promo has CLOSED for ordering we can diff our own feed on that date and see whether ANY field moved. row_fingerprint is an md5 over the entire line set, so it catches a change in a field nobody thought to watch. If the fingerprint never moves on the day it shuts, the DC closes the window manually and no signal exists in the mirror -- which is itself the finding.';

COMMENT ON COLUMN public.promo_window_probe.observed_orderable IS
'The FLOOR observation, filled by a person: could this promo still be ordered on Sigma today? Physically observable and falsifiable (canon 17 item-12) -- open the promo order screen and look. Never inferred by the engine.';

-- Live ACL read 2026-09-10: anon=rm, authenticated=rm, service_role=arwdDxtm. The `m`
-- (MAINTAIN) comes from the platform's default privileges; only the writes are revoked.
ALTER TABLE public.promo_window_probe ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS promo_window_probe_read ON public.promo_window_probe;
CREATE POLICY promo_window_probe_read ON public.promo_window_probe FOR SELECT USING (true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.promo_window_probe FROM anon, authenticated;
GRANT SELECT ON public.promo_window_probe TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.capture_promo_window_probe()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows integer;
BEGIN
  INSERT INTO public.promo_window_probe (
    probe_date, store_code, promo_nr, suffix, start_date, end_date, days_past_end, hdr_status,
    lines, lines_status0, lines_status2, lines_with_cost, distinct_new_price, row_fingerprint)
  SELECT CURRENT_DATE, pa.store_code, pa.promo_nr,
         COALESCE(substring(pr.description from '\(([A-Za-z0-9]+)\)\s*$'),
                  substring(pr.description from 'DC Promotion Number\s+(\S+)')),
         min(pa.start_date), max(pa.end_date),
         CURRENT_DATE - max(pa.end_date),
         max(pr.status),
         count(*)::int,
         count(*) FILTER (WHERE pa.status='0')::int,
         count(*) FILTER (WHERE pa.status='2')::int,
         count(*) FILTER (WHERE pa.list_cost > 0)::int,
         count(DISTINCT pa.new_price)::int,
         md5(string_agg(
               pa.product_code::text||'|'||coalesce(pa.status,'')||'|'||
               coalesce(pa.list_cost::text,'')||'|'||coalesce(pa.new_price::text,'')||'|'||
               coalesce(pa.old_price::text,'')||'|'||coalesce(pa.discount_pct::text,'')||'|'||
               coalesce(pa.start_date::text,'')||'|'||coalesce(pa.end_date::text,''),
               E'\n' ORDER BY pa.product_code, pa.line_id))
  FROM public.sigma_promotion_articles pa
  LEFT JOIN public.sigma_promotions pr
         ON pr.store_code = pa.store_code AND pr.promo_nr = pa.promo_nr
  WHERE pa.end_date BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE + 90
  GROUP BY pa.store_code, pa.promo_nr, pr.description
  ON CONFLICT (probe_date, store_code, promo_nr) DO UPDATE SET
    suffix             = EXCLUDED.suffix,
    start_date         = EXCLUDED.start_date,
    end_date           = EXCLUDED.end_date,
    days_past_end      = EXCLUDED.days_past_end,
    hdr_status         = EXCLUDED.hdr_status,
    lines              = EXCLUDED.lines,
    lines_status0      = EXCLUDED.lines_status0,
    lines_status2      = EXCLUDED.lines_status2,
    lines_with_cost    = EXCLUDED.lines_with_cost,
    distinct_new_price = EXCLUDED.distinct_new_price,
    row_fingerprint    = EXCLUDED.row_fingerprint,
    captured_at        = now();
    -- observed_orderable, observed_by, observed_at: deliberately untouched.

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('probe_date', CURRENT_DATE, 'rows', v_rows, 'observations_preserved', true);
END $function$;

REVOKE ALL ON FUNCTION public.capture_promo_window_probe() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.capture_promo_window_probe() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpc_promo_probe_observe(p_suffix text, p_orderable boolean, p_store_code text DEFAULT NULL::text, p_by text DEFAULT 'PG'::text, p_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows integer;
BEGIN
  UPDATE public.promo_window_probe p
     SET observed_orderable = p_orderable,
         observed_by        = p_by,
         observed_at        = now()
   WHERE p.probe_date = p_date
     AND upper(p.suffix) = upper(p_suffix)
     AND (p_store_code IS NULL OR p.store_code = p_store_code);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RETURN jsonb_build_object('recorded', 0,
      'warning', format('no probe row for suffix %s on %s -- run capture_promo_window_probe() first, or the promo is outside the -60/+90 day window', p_suffix, p_date));
  END IF;

  RETURN jsonb_build_object('recorded', v_rows, 'suffix', p_suffix,
                            'orderable', p_orderable, 'probe_date', p_date);
END $function$;

COMMENT ON FUNCTION public.rpc_promo_probe_observe(text, boolean, text, text, date) IS
'GRADE: RAW. ENG-082. Records the FLOOR observation against today probe row: could this promo still be ordered on Sigma today. The question is physically observable and falsifiable (canon 17 item-12) -- open the promo order screen and look. The engine never infers it.';

REVOKE ALL ON FUNCTION public.rpc_promo_probe_observe(text, boolean, text, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_promo_probe_observe(text, boolean, text, text, date) TO authenticated, service_role;

-- Daily, after the extractor refreshes the promo tables (~19:20-19:30 SAST).
-- cron.schedule upserts by job name, so re-running this line is idempotent.
SELECT cron.schedule('promo-window-probe-daily', '45 18 * * *',
  $cron$SET statement_timeout = '600s'; SELECT public.capture_promo_window_probe();$cron$);
