-- =====================================================================
-- create_forge_count_run.sql
-- THE COMPLIANCE RUN-LOG for the Daily Count Law
-- CLEANUP-ENGINE-CANON section 15 ("Compliance loop") + its 2026-07-10
-- ADDENDUM, which names this object as a NAMED DEBT owed by CC:
--   "every issued list is a run (who, when, selection, seed). Next morning
--    the engine diffs the list against booked I-movements -> counted/uncounted
--    per line; uncounted roll forward flagged with age; compliance % per store
--    per day lands in the run log. A list nobody executed stays loud, never
--    assumed done (R22)."
--
-- Author: CC (Claude Code)   Created: 2026-08-04 (system clock, cross-checked
-- local / machine-UTC / DB now() at +2, arbiter = cron job 10 on its own slot)
-- Ref: SB-CC-TOOLKIT-001, Forge/PROJECT.md "Open for CC" item 2
--
-- WHY IT IS A PLATFORM FACT AND NOT A FORGE TABLE (R32).
-- rpc_forge_count_list already has THREE consumers: Forge's own Stocktake
-- Composer, Sparrie's StockFlow stocktake SELECTION (SB-RA-SF-002) and the
-- standalone Bloom app's count capture (SB-RA-BLOOM-001 Phase 3). A run-log
-- built inside one of them is a pantry debt paid bespoke. `source` carries
-- which surface issued the list, so all three log to one ledger.
--
-- SCOPE / R28: GENERAL. No constant here is fitted to our five stores -- the
-- cycle constants stay in forge_config where they already live. Store #6
-- inherits this unchanged.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE RUN HEADER -- who, when, selection, seed
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.forge_count_run (
  run_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     text        NOT NULL DEFAULT 'socialbrand',
  store_code    text        NOT NULL,

  issued_at     timestamptz NOT NULL DEFAULT now(),
  -- PROVENANCE ONLY. Records who issued the list, never who approved it.
  -- CANON section 17, THE ITEM-12 CHURN: "`confirmed_by` records who observed,
  -- never who approved, and no engine branch may read it as a permission."
  -- The forbidden form, kept here so it stays recognisable in review:
  --   if issued_by is not null then <resolve/act>
  issued_by     text        NULL,

  source        text        NOT NULL DEFAULT 'forge'
                            CHECK (source IN ('forge','stockflow','bloom')),
  mode          text        NOT NULL
                            CHECK (mode IN ('daily','random','targeted')),

  -- The full selection, so the run is reproducible without re-deriving it.
  -- R22: "a sample you cannot reproduce is not auditable" (canon section 15,
  -- ad-hoc modes). seed is lifted out of params because reproducibility is
  -- the gate, not a detail.
  params        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  seed          text        NULL,

  line_count    integer     NOT NULL CHECK (line_count >= 0),

  -- What the self-deriving budget computed AT ISSUE TIME. Frozen, because the
  -- pool moves nightly and a later pool must never rewrite what was issued.
  pool_size     integer     NULL,
  daily_budget  integer     NULL,

  notes         text        NULL
);

COMMENT ON TABLE public.forge_count_run IS
  'Count-list run header (canon 15 compliance loop). One row per issued list, any surface. issued_by is a provenance stamp, NEVER a permission (canon 17 item-12 ruling).';

CREATE INDEX IF NOT EXISTS forge_count_run_store_issued_idx
  ON public.forge_count_run (store_code, issued_at DESC);

-- ---------------------------------------------------------------------
-- 2. THE RUN LINES -- frozen state at issue (R22)
-- ---------------------------------------------------------------------
-- Same discipline as l2_anomaly_daily: "every row carries full frozen state at
-- detection". A run must stay auditable after the pool, the SOH and the
-- classification have all moved on.
CREATE TABLE IF NOT EXISTS public.forge_count_run_line (
  run_id                uuid    NOT NULL
                                REFERENCES public.forge_count_run(run_id) ON DELETE CASCADE,
  store_code            text    NOT NULL,
  product_code          bigint  NOT NULL,

  stratum               text    NULL,   -- canon 15's five strata
  description           text    NULL,
  soh_at_issue          numeric NULL,
  capital_at_issue      numeric NULL,

  -- THE COMPLIANCE ANCHOR, and it is the whole reason the diff can fail.
  -- Frozen DIRECT FROM THE LEDGER at issue (not from l2_last_counted, which
  -- refreshes nightly and would be up to a day stale). A line is executed only
  -- when the ledger moves PAST this value -- so a count already booked earlier
  -- on the issue date can never be mistaken for compliance with this run.
  last_counted_at_issue date    NULL,

  PRIMARY KEY (run_id, product_code)
);

COMMENT ON TABLE public.forge_count_run_line IS
  'Lines of an issued count list, state frozen at issue (R22). last_counted_at_issue is the ledger anchor the compliance diff must be beaten by.';

CREATE INDEX IF NOT EXISTS forge_count_run_line_store_product_idx
  ON public.forge_count_run_line (store_code, product_code);

-- ---------------------------------------------------------------------
-- 3. RLS -- on, with no anon path
-- ---------------------------------------------------------------------
-- The linter flags any public table with RLS disabled regardless of grant
-- intent (the bloom_delivery_schedule precedent). issued_by can carry a person,
-- so anon gets NOTHING here -- the user_profiles precedent, where a stray anon
-- SELECT on PII was revoked. Reads reach this through authenticated RPCs only.
ALTER TABLE public.forge_count_run      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forge_count_run_line ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS forge_count_run_select_auth ON public.forge_count_run;
CREATE POLICY forge_count_run_select_auth ON public.forge_count_run
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS forge_count_run_line_select_auth ON public.forge_count_run_line;
CREATE POLICY forge_count_run_line_select_auth ON public.forge_count_run_line
  FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.forge_count_run      FROM PUBLIC, anon;
REVOKE ALL ON public.forge_count_run_line FROM PUBLIC, anon;
GRANT SELECT ON public.forge_count_run      TO authenticated;
GRANT SELECT ON public.forge_count_run_line TO authenticated;

-- ---------------------------------------------------------------------
-- 4. THE WRITE PATH -- one published function, R30 addendum 2
-- ---------------------------------------------------------------------
-- "App-born workflow events land as platform tables in public, written ONLY
-- through published SECURITY DEFINER rpc_* write-functions granted to
-- authenticated." No surface INSERTs into these tables directly.
CREATE OR REPLACE FUNCTION public.rpc_forge_log_count_run(
  p_store_code   text,
  p_mode         text,
  p_lines        jsonb,                      -- [{product_code, stratum, description, soh, capital_value}, ...]
  p_params       jsonb   DEFAULT '{}'::jsonb,
  p_seed         text    DEFAULT NULL,
  p_source       text    DEFAULT 'forge',
  p_issued_by    text    DEFAULT NULL,
  p_pool_size    integer DEFAULT NULL,
  p_daily_budget integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id uuid;
  v_rows   integer;
BEGIN
  IF p_store_code IS NULL OR btrim(p_store_code) = '' THEN
    RAISE EXCEPTION 'rpc_forge_log_count_run: p_store_code is required';
  END IF;

  -- No silent empties (canon 8.6 guard 4). A zero-line run is a real event and
  -- is logged as one, but it is never logged as a SUCCESS with no shape.
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'rpc_forge_log_count_run: p_lines must be a jsonb array (got %)',
                    coalesce(jsonb_typeof(p_lines),'null');
  END IF;

  INSERT INTO public.forge_count_run
    (store_code, issued_by, source, mode, params, seed, line_count, pool_size, daily_budget)
  VALUES
    (p_store_code, p_issued_by, p_source, p_mode, coalesce(p_params,'{}'::jsonb), p_seed,
     jsonb_array_length(p_lines), p_pool_size, p_daily_budget)
  RETURNING run_id INTO v_run_id;

  -- Freeze the lines, and take the compliance anchor STRAIGHT FROM THE LEDGER.
  -- movement_type = 'I' is the DIWAINV count channel, byte-for-byte the same
  -- predicate refresh_l2_last_counted uses -- deliberately identical so the
  -- run-log and the nightly fact cannot drift apart (the ENG-061 discipline:
  -- share the expression, do not restate it).
  INSERT INTO public.forge_count_run_line
    (run_id, store_code, product_code, stratum, description,
     soh_at_issue, capital_at_issue, last_counted_at_issue)
  SELECT
    v_run_id,
    p_store_code,
    (l->>'product_code')::bigint,
    l->>'stratum',
    l->>'description',
    (l->>'soh')::numeric,
    (l->>'capital_value')::numeric,
    (SELECT max(m.movement_date)
       FROM public.sigma_movements m
      WHERE m.store_code   = p_store_code
        AND m.product_code = (l->>'product_code')::bigint
        AND m.movement_type = 'I')
  FROM jsonb_array_elements(p_lines) AS l
  ON CONFLICT (run_id, product_code) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- R22: report what actually inserted, never what was handed in. Same reason
  -- rpc_bloom_submit_order recomputes line_count from the rows that landed.
  UPDATE public.forge_count_run SET line_count = v_rows WHERE run_id = v_run_id;

  RETURN jsonb_build_object(
    'run_id',        v_run_id,
    'store_code',    p_store_code,
    'mode',          p_mode,
    'source',        p_source,
    'lines_offered', jsonb_array_length(p_lines),
    'lines_logged',  v_rows,
    'seed',          p_seed
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_forge_log_count_run IS
  'Logs one issued count list (canon 15 compliance loop). The only write path into forge_count_run/_line (R30 addendum 2).';

-- R30 addendum extension (2026-07-21, ENG-031, THIRD firing of this trap):
-- REVOKE FROM PUBLIC alone is proven insufficient -- Supabase carries an
-- ALTER DEFAULT PRIVILEGES granting EXECUTE to anon DIRECTLY on every new
-- public function, and a role-specific grant survives a REVOKE FROM PUBLIC.
-- Both revokes are required on any mutating function, then prove it.
REVOKE EXECUTE ON FUNCTION public.rpc_forge_log_count_run(text,text,jsonb,jsonb,text,text,text,integer,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forge_log_count_run(text,text,jsonb,jsonb,text,text,text,integer,integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_forge_log_count_run(text,text,jsonb,jsonb,text,text,text,integer,integer) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. THE DIFF -- per line, counted or not, with its age
-- ---------------------------------------------------------------------
-- Derived on demand, never stored. A stored compliance figure is a stored
-- aggregate that disagrees with its own lines the moment the ledger moves
-- (canon 12e 4b, THE STORED-AGGREGATE LAW / ENG-050).
-- SECURITY DEFINER IS LOAD-BEARING HERE, NOT BOILERPLATE. sigma_movements has
-- RLS ENABLED with ZERO policies -- locked by default, the same shape that
-- silently emptied the Kitchen tab and the Pulse Mini tiles (R30 repair set,
-- 2026-07-06). A read function without it reads the ledger as the caller and
-- gets zero rows SILENTLY, so every line would report NOT COUNTED and
-- compliance would sit at a plausible, permanent 0%. Proven live before the
-- fix: SET ROLE authenticated -> count(*) on the I-channel = 0. Every sibling
-- engine read RPC is already SECURITY DEFINER; these two were the outliers.
CREATE OR REPLACE FUNCTION public.rpc_forge_run_compliance(p_run_id uuid)
RETURNS TABLE (
  run_id                uuid,
  store_code            text,
  product_code          bigint,
  stratum               text,
  description           text,
  soh_at_issue          numeric,
  last_counted_at_issue date,
  counted_on            date,
  counted               boolean,
  days_outstanding      integer,
  story                 text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH hdr AS (
    SELECT r.run_id, r.issued_at, r.store_code FROM public.forge_count_run r WHERE r.run_id = p_run_id
  ),
  ln AS (
    SELECT l.*, h.issued_at
    FROM public.forge_count_run_line l
    JOIN hdr h ON h.run_id = l.run_id
  ),
  -- The count that would discharge this line: an I-movement on or after the
  -- issue date that is ALSO strictly later than the anchor frozen at issue.
  -- Both conditions matter. The date test alone would let a count booked
  -- earlier on the issue day masquerade as compliance -- a gate that cannot
  -- fail is not proof (R28 section 5).
  hit AS (
    SELECT ln.run_id, ln.product_code, min(m.movement_date) AS counted_on
    FROM ln
    JOIN public.sigma_movements m
      ON  m.store_code    = ln.store_code
      AND m.product_code  = ln.product_code
      AND m.movement_type = 'I'
      AND m.movement_date >= ln.issued_at::date
      AND (ln.last_counted_at_issue IS NULL OR m.movement_date > ln.last_counted_at_issue)
    GROUP BY ln.run_id, ln.product_code
  )
  SELECT
    ln.run_id,
    ln.store_code,
    ln.product_code,
    ln.stratum,
    ln.description,
    ln.soh_at_issue,
    ln.last_counted_at_issue,
    hit.counted_on,
    (hit.counted_on IS NOT NULL) AS counted,
    CASE WHEN hit.counted_on IS NULL
         THEN (CURRENT_DATE - ln.issued_at::date)::integer
    END AS days_outstanding,
    -- R29: the reason travels with the number, in a buyer's words.
    CASE
      WHEN hit.counted_on IS NOT NULL
        THEN 'Counted ' || hit.counted_on
             || ' (issued ' || ln.issued_at::date || ')'
      WHEN (CURRENT_DATE - ln.issued_at::date) = 0
        THEN 'Issued today, not yet counted'
      ELSE 'NOT COUNTED -- ' || (CURRENT_DATE - ln.issued_at::date)::text
           || ' day(s) outstanding since ' || ln.issued_at::date
           || coalesce('; last counted ' || ln.last_counted_at_issue::text, '; never counted')
    END AS story
  FROM ln
  LEFT JOIN hit ON hit.run_id = ln.run_id AND hit.product_code = ln.product_code
  ORDER BY (hit.counted_on IS NOT NULL), ln.stratum, ln.product_code;
$$;

COMMENT ON FUNCTION public.rpc_forge_run_compliance IS
  'Per-line counted/uncounted for one run, diffed against the I-channel. Derived on demand, never stored (canon 12e 4b).';

REVOKE EXECUTE ON FUNCTION public.rpc_forge_run_compliance(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forge_run_compliance(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_forge_run_compliance(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. COMPLIANCE % PER STORE PER DAY -- "a list nobody executed stays loud"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_forge_compliance_summary(
  p_stores text[]  DEFAULT NULL,
  p_from   date    DEFAULT NULL,
  p_to     date    DEFAULT NULL
)
RETURNS TABLE (
  store_code       text,
  issue_date       date,
  runs             integer,
  lines_issued     integer,
  lines_counted    integer,
  compliance_pct   numeric,
  oldest_outstanding_days integer,
  verdict          text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH runs AS (
    SELECT r.run_id, r.store_code, r.issued_at::date AS issue_date
    FROM public.forge_count_run r
    WHERE (p_stores IS NULL OR r.store_code = ANY(p_stores))
      AND (p_from   IS NULL OR r.issued_at::date >= p_from)
      AND (p_to     IS NULL OR r.issued_at::date <= p_to)
  ),
  lines AS (
    SELECT ru.store_code, ru.issue_date, ru.run_id, c.counted, c.days_outstanding
    FROM runs ru
    CROSS JOIN LATERAL public.rpc_forge_run_compliance(ru.run_id) c
  )
  SELECT
    l.store_code,
    l.issue_date,
    count(DISTINCT l.run_id)::integer                              AS runs,
    count(*)::integer                                              AS lines_issued,
    count(*) FILTER (WHERE l.counted)::integer                     AS lines_counted,
    -- NULL, never a fake 100%, when a run legitimately issued zero lines.
    CASE WHEN count(*) > 0
         THEN round(100.0 * count(*) FILTER (WHERE l.counted) / count(*), 1)
    END                                                            AS compliance_pct,
    max(l.days_outstanding)::integer                               AS oldest_outstanding_days,
    CASE
      WHEN count(*) = 0                                        THEN 'EMPTY RUN -- nothing was issued'
      WHEN count(*) FILTER (WHERE l.counted) = count(*)        THEN 'COMPLETE'
      WHEN count(*) FILTER (WHERE l.counted) = 0
           AND max(l.days_outstanding) > 0                     THEN 'NOT EXECUTED -- no line on this list was counted'
      ELSE 'PARTIAL -- ' || count(*) FILTER (WHERE NOT l.counted)::text || ' line(s) outstanding'
    END                                                            AS verdict
  FROM lines l
  GROUP BY l.store_code, l.issue_date
  ORDER BY l.issue_date DESC, l.store_code;
$$;

COMMENT ON FUNCTION public.rpc_forge_compliance_summary IS
  'Compliance % per store per issue-date (canon 15). A list nobody executed reads NOT EXECUTED, never a silent blank.';

REVOKE EXECUTE ON FUNCTION public.rpc_forge_compliance_summary(text[],date,date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forge_compliance_summary(text[],date,date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_forge_compliance_summary(text[],date,date) TO authenticated;

NOTIFY pgrst, 'reload schema';
