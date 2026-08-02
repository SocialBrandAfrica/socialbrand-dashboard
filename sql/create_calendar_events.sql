-- =============================================================================
-- calendar_events -- THE EVENT CALENDAR (canon CLEANUP-ENGINE-CANON §16.2)
-- SB-CC-BLOOM-018 v1.3 item A / ENG-056.  CC 2026-07-30.
-- =============================================================================
-- Canon §16.2: "LOADED, NEVER CODED -- no date literal in any function. The
-- engine never computes Easter; it reads it."  This table is that.
--
-- §0h SCOPE SPLIT, binding.  The GENERAL FORM (a calendar is a dimension that
-- products, orders and counts tie to) is canon's and travels to every store in
-- every country.  THE DATES ARE CALIBRATION: true of South Africa and of this
-- region, not of the platform.  They live here as loaded rows and are pointed to
-- from Calibration/CAL-CALENDAR-001, never written inline into canon.  A store
-- in another country loads its own rows and changes no rule.  Deletion test passes.
--
-- WHY event_stream IS IN THE PRIMARY KEY, and it is the whole of ENG-056:
--   the grant streams STAGGER.  The income window opens on the EARLIEST of them,
--   so no single day-of-month can express it.  Measured on the published 2026/27
--   year at 80175: the fixed p_early_month_build_start_day = 25 misses the real
--   last-delivery-before-pension in 12 of 12 months by 2 to 8 days, mean 5.417,
--   and twice names a day nothing can happen on (Sunday 25 Oct, Christmas Day).
--
-- SOURCE IS NOT NULL BY DESIGN.  A date without a provenance is not loaded (R22).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.calendar_events (
  client_id      text        NOT NULL DEFAULT 'socialbrand',
  scope          text        NOT NULL,
  scope_ref      text        NOT NULL DEFAULT '',
  event_type     text        NOT NULL,
  event_stream   text        NOT NULL DEFAULT '',
  event_date     date        NOT NULL,
  event_end_date date,
  is_non_trading boolean     NOT NULL DEFAULT false,
  description    text,
  source         text        NOT NULL,
  loaded_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT calendar_events_pkey PRIMARY KEY (client_id, scope, scope_ref, event_type, event_stream, event_date),
  CONSTRAINT calendar_events_scope_ck CHECK (scope IN ('country','province','client','store')),
  CONSTRAINT calendar_events_type_ck  CHECK (event_type IN ('PUBLIC_HOLIDAY','SASSA_PAYMENT','SCHOOL_TERM','PAYDAY','LOCAL_EVENT')),
  CONSTRAINT calendar_events_span_ck  CHECK (event_end_date IS NULL OR event_end_date >= event_date)
);

CREATE INDEX IF NOT EXISTS idx_calendar_events_type_date  ON public.calendar_events (event_type, event_date);
CREATE INDEX IF NOT EXISTS idx_calendar_events_nontrading ON public.calendar_events (event_date) WHERE is_non_trading;

COMMENT ON TABLE public.calendar_events IS
  'CLEANUP-ENGINE-CANON §16.2 -- the event calendar as a first-class dimension. LOADED, NEVER CODED: no consumer may carry a date literal (R25). event_stream is part of the grain because SASSA payments STAGGER and the income window opens on the earliest. is_non_trading marks days the store cannot trade or receive, which is what order cutoffs and the count law must skip (§16.4 items 5 and 7). §0h: the dates here are CALIBRATION, pointed to from Calibration/CAL-CALENDAR-001, never inline in canon.';

ALTER TABLE public.calendar_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS calendar_events_read ON public.calendar_events;
CREATE POLICY calendar_events_read ON public.calendar_events FOR SELECT USING (true);
GRANT SELECT ON public.calendar_events TO anon, authenticated;

-- =============================================================================
-- SEED.  Calibration data -- see Calibration/CAL-CALENDAR-001 for provenance,
-- what is deliberately NOT loaded, and the reload procedure for the next period.
-- =============================================================================

-- SA PUBLIC HOLIDAYS 2026.  Source: canon §16.3, citing Public Holidays Act 36
-- of 1994.  The Sunday rule is a FORMULA canon carries: a holiday on a Sunday is
-- observed the Monday, a holiday on a Saturday does not move.  Where the rule
-- applies the OBSERVED date is the non-trading row.
INSERT INTO public.calendar_events (scope, event_type, event_date, is_non_trading, description, source) VALUES
  ('country','PUBLIC_HOLIDAY','2026-01-01', true, 'New Years Day', 'CLEANUP-ENGINE-CANON 16.3 (Public Holidays Act 36 of 1994)'),
  ('country','PUBLIC_HOLIDAY','2026-03-21', true, 'Human Rights Day (Saturday, NOT moved)', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-04-03', true, 'Good Friday (lunar -- READ, never computed)', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-04-06', true, 'Family Day (lunar -- READ, never computed)', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-04-27', true, 'Freedom Day', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-05-01', true, 'Workers Day', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-06-16', true, 'Youth Day', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-08-10', true, 'National Womens Day OBSERVED (statutory 2026-08-09 is a Sunday)', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-09-24', true, 'Heritage Day', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-12-16', true, 'Day of Reconciliation', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-12-25', true, 'Christmas Day', 'CLEANUP-ENGINE-CANON 16.3'),
  ('country','PUBLIC_HOLIDAY','2026-12-26', true, 'Day of Goodwill (Saturday, NOT moved)', 'CLEANUP-ENGINE-CANON 16.3')
ON CONFLICT DO NOTHING;

-- SASSA 2026/27, the published year.  Source: DSD 2026/2027 grant schedule
-- (dsd.gov.za).  THREE streams -- DSD publishes no reviews and no care-dependency
-- date.  One stream, one provenance.
INSERT INTO public.calendar_events (scope, event_type, event_stream, event_date, is_non_trading, description, source)
SELECT 'country','SASSA_PAYMENT', s.stream, s.d, false, s.descr, 'DSD 2026/2027 grant schedule (dsd.gov.za)'
FROM (VALUES
  ('OLDER_PERSONS','2026-04-02'::date,'Older persons grant'), ('DISABILITY','2026-04-07','Disability grant'), ('CHILDREN','2026-04-08','Child support grant'),
  ('OLDER_PERSONS','2026-05-05','Older persons grant'),      ('DISABILITY','2026-05-06','Disability grant'), ('CHILDREN','2026-05-07','Child support grant'),
  ('OLDER_PERSONS','2026-06-02','Older persons grant'),      ('DISABILITY','2026-06-03','Disability grant'), ('CHILDREN','2026-06-04','Child support grant'),
  ('OLDER_PERSONS','2026-07-02','Older persons grant'),      ('DISABILITY','2026-07-03','Disability grant'), ('CHILDREN','2026-07-06','Child support grant'),
  ('OLDER_PERSONS','2026-08-04','Older persons grant'),      ('DISABILITY','2026-08-05','Disability grant'), ('CHILDREN','2026-08-06','Child support grant'),
  ('OLDER_PERSONS','2026-09-02','Older persons grant'),      ('DISABILITY','2026-09-03','Disability grant'), ('CHILDREN','2026-09-04','Child support grant'),
  ('OLDER_PERSONS','2026-10-02','Older persons grant'),      ('DISABILITY','2026-10-05','Disability grant'), ('CHILDREN','2026-10-06','Child support grant'),
  ('OLDER_PERSONS','2026-11-03','Older persons grant'),      ('DISABILITY','2026-11-04','Disability grant'), ('CHILDREN','2026-11-05','Child support grant'),
  ('OLDER_PERSONS','2026-12-02','Older persons grant'),      ('DISABILITY','2026-12-03','Disability grant'), ('CHILDREN','2026-12-04','Child support grant'),
  ('OLDER_PERSONS','2027-01-05','Older persons grant'),      ('DISABILITY','2027-01-06','Disability grant'), ('CHILDREN','2027-01-07','Child support grant'),
  ('OLDER_PERSONS','2027-02-02','Older persons grant'),      ('DISABILITY','2027-02-03','Disability grant'), ('CHILDREN','2027-02-04','Child support grant'),
  ('OLDER_PERSONS','2027-03-02','Older persons grant'),      ('DISABILITY','2027-03-03','Disability grant'), ('CHILDREN','2027-03-04','Child support grant')
) AS s(stream, d, descr)
ON CONFLICT DO NOTHING;

-- The single REVIEWS row.  It is NOT in the DSD schedule, and its source string
-- says so rather than borrowing DSD's authority.  No reviews date exists for any
-- other month and none is invented.
INSERT INTO public.calendar_events (scope, event_type, event_stream, event_date, is_non_trading, description, source) VALUES
  ('country','SASSA_PAYMENT','REVIEWS','2026-08-07', false,
   'Reviews -- secondary source only, see source string. Single row: no reviews date exists for any other month.',
   'SASSA announcement + news coverage (SAnews, Cape Town ETC Aug 2026). NOT in the DSD 2026/2027 schedule, which publishes three streams and no reviews date.')
ON CONFLICT DO NOTHING;

-- R22 GATE, run this after any load.  A schedule that shifts off non-working days
-- should never land on one; a hit here means a mis-transcription, not a finding.
-- Expected: 0 rows.
--   SELECT event_date, event_stream FROM calendar_events ce
--    WHERE event_type='SASSA_PAYMENT'
--      AND (EXTRACT(ISODOW FROM event_date) IN (6,7)
--           OR EXISTS (SELECT 1 FROM calendar_events h WHERE h.is_non_trading AND h.event_date = ce.event_date));
