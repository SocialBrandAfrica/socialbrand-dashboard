-- SB-CC-BLOOM-029 item 4 -- THE ISSUING GUARD. Two clauses, two functions.
--
-- Applied live 2026-09-02 as migration `bloom029_item4_issuing_guard`. The two
-- DO blocks below are BYTE-IDENTICAL to what was applied, so this file is not
-- rotted off live on the day it was written.
--
-- THE DEFECT (brief F6, measured at source). The toolkit lets one person issue
-- the same store-day twice, and random mode has no ceiling. On 2026-08-31 the
-- account socialbrand.africa@gmail.com issued 2,487 lines at 80175 and 2,083 at
-- 10116 between 16:29 and 16:48; on 2026-08-25 it issued six identical 185-line
-- daily runs at 80175 inside two minutes. Job 25 (`refresh_forge_daily_issue`)
-- was never the cause -- every 06:30 system run issued exactly the ruled volume.
--
-- ⚠ AND IT IS NOT HISTORICAL. Measured while building this fix: 10116 carried
-- TWO daily runs for 2026-09-02 -- job 25's correct 200-line run at 06:30 SAST
-- and a manual 176-line run by the same account at 11:08 SAST, about an hour
-- before this migration was applied.
--
-- 🔴 THE CEILING IS WORSE THAN THE BRIEF STATES, AND THIS IS MEASURED. Random
-- mode partitioned `ROW_NUMBER() OVER (PARTITION BY p.sc, p.dept)` and capped on
-- `COALESCE(p_n, 50)`, so p_n was PER DEPARTMENT. The UI field is literally named
-- `nper` / `n_per_dept`. Measured before the change, with NOBODY typing anything:
--     random 80175, no p_n -> 690 lines against a store budget of 200
--     random 80176, no p_n -> 441 lines against a store budget of  70
-- So the untouched DEFAULT was already 3.5x and 6.3x the budget. Changing the
-- default alone would have left the multiplier in place. The PARTITION is the fix.
--
-- ⚠ ONE CORRECTION TO THE BRIEF, stated rather than silently followed. Clause (b)
-- describes the daily budget as "pool / trading days of the cycle, §15". That
-- formula was RETIRED on 2026-08-13 (SB-CC-TOOLKIT-002 item 1) and replaced by
-- the fixed `forge_config.daily_count_volume` per store_format, SPAR 200 / TOPS
-- 70, which `rpc_forge_count_list` already reads as `cfg.vol`. Implementing the
-- parenthetical would have resurrected a retired self-sizing formula. The brief's
-- own R22 target (80175 random with no p_n must be <= 200) IS the config value,
-- so the intent matches and only the description was stale.
--
-- NO NEW CONFIG KEY, as the brief requires: both clauses read `daily_count_volume`,
-- which already exists and is already populated.
--
-- SITE COUNT (R30 addendum 3).
--   clause (a), the same-store-same-day guard: 2 sites carry the pattern.
--     `refresh_forge_daily_issue` (job 25) ALREADY had it -- untouched.
--     `rpc_forge_log_count_run` (the toolkit's path) did NOT -- added here.
--     That gap is the whole of F6: job 25 was guarded, the manual path was not.
--   clause (b), the random ceiling: 1 function (`rpc_forge_count_list`) + 3 UI
--     sites in public/toolkit.html (the input default, the p_n argument, the
--     params key). `/toolkit` is the same file, served by src/app/toolkit/route.js.
--   VERIFIED NOT SITES: `refresh_forge_daily_issue` and
--     src/app/api/forge/export-stocktake/route.js both call rpc_forge_count_list
--     with mode 'daily' and pass no p_n, so neither can reach the random path.
--
-- 🔴 NAMED AND NOT FIXED (brief §2 "no additions"): job 25's own guard compares
-- against a hardcoded 'Africa/Johannesburg' rather than the store's timezone.
-- That is an ENG-117 sibling site. The guard added here uses `store_local_today`,
-- so the NEW site is portable and the OLD one is a filed defect, not a
-- propagated one. Both agree today because all five stores are on that zone.

BEGIN;

-- ---------------------------------------------------------------------------
-- CLAUSE (b): random mode is capped at the STORE's own daily budget.
-- The cap becomes a store total instead of a per-department quota. An explicit
-- p_n is honoured and also means a store total, which is what every caller has
-- always believed it meant.
-- ---------------------------------------------------------------------------
DO $b029b$
DECLARE
  src text;
  f_from text := $q$      SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.sc, p.dept ORDER BY p.rnd) AS rn
      FROM pool p WHERE p.soh0 <> 0
    ) x WHERE p_mode='random' AND x.rn <= COALESCE(p_n, 50)$q$;
  f_to text := $q$      SELECT p.*, c.vol AS store_vol,
             ROW_NUMBER() OVER (PARTITION BY p.sc ORDER BY p.rnd) AS rn
      FROM pool p JOIN cfg c ON c.sc = p.sc WHERE p.soh0 <> 0
    ) x WHERE p_mode='random' AND x.rn <= COALESCE(p_n, x.store_vol)$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_forge_count_list';
  IF src IS NULL THEN RAISE EXCEPTION 'BLOOM-029 item 4: rpc_forge_count_list not found'; END IF;
  IF (length(src)-length(replace(src,f_from,'')))/length(f_from) <> 1 THEN
    RAISE EXCEPTION 'BLOOM-029 item 4: rand_mode anchor is not unique'; END IF;
  src := replace(src, f_from, f_to);
  EXECUTE src;
END
$b029b$;

-- ---------------------------------------------------------------------------
-- CLAUSE (a): one daily list per store per STORE-LOCAL day, on the path the
-- toolkit actually uses. A second daily issue returns the run that already
-- exists and writes nothing. R29: the return states which clause bound.
-- ---------------------------------------------------------------------------
DO $b029a$
DECLARE
  src text;
  d_from text := $q$DECLARE
  v_run_id uuid;
  v_rows   integer;
BEGIN$q$;
  d_to text := $q$DECLARE
  v_run_id uuid;
  v_rows   integer;
  v_existing uuid;
  v_today  date;
  v_tz     text;
  v_vol    int;
BEGIN$q$;
  g_from text := $q$  INSERT INTO public.forge_count_run
    (store_code, issued_by, source, mode, params, seed, line_count, pool_size, daily_budget)$q$;
  g_to text := $q$  IF p_mode = 'daily' THEN
    SELECT s.timezone INTO v_tz FROM public.stores s WHERE s.store_code = p_store_code;
    v_today := public.store_local_today(p_store_code);
    SELECT r.run_id INTO v_existing
      FROM public.forge_count_run r
     WHERE r.store_code = p_store_code
       AND r.mode = 'daily'
       AND (r.issued_at AT TIME ZONE v_tz)::date = v_today
     ORDER BY r.issued_at
     LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object(
        'run_id',         v_existing,
        'store_code',     p_store_code,
        'mode',           p_mode,
        'source',         p_source,
        'lines_offered',  jsonb_array_length(p_lines),
        'lines_logged',   0,
        'seed',           p_seed,
        'already_issued', true,
        'reason',         'clause (a): a daily list was already issued for this store on '
                          || v_today::text || ' (store-local). Nothing re-issued.');
    END IF;
  END IF;

  INSERT INTO public.forge_count_run
    (store_code, issued_by, source, mode, params, seed, line_count, pool_size, daily_budget)$q$;
  r_from text := $q$  UPDATE public.forge_count_run SET line_count = v_rows WHERE run_id = v_run_id;

  RETURN jsonb_build_object(
    'run_id',        v_run_id,$q$;
  r_to text := $q$  IF p_mode = 'random' THEN
    SELECT f.value_num::int INTO v_vol
      FROM public.forge_config f
      JOIN public.stores s ON s.store_code = p_store_code
     WHERE f.config_key = 'daily_count_volume' AND f.retired_on IS NULL
       AND f.store_format IN (s.store_type, '*')
     ORDER BY f.store_format DESC LIMIT 1;
  END IF;

  UPDATE public.forge_count_run
     SET line_count = v_rows,
         daily_budget = COALESCE(daily_budget, v_vol),
         params = CASE
           WHEN p_mode = 'random' AND v_vol IS NOT NULL AND v_rows > v_vol
             THEN coalesce(params,'{}'::jsonb)
                  || jsonb_build_object('over_budget_explicit', true,
                                        'daily_budget', v_vol,
                                        'reason', 'clause (b): an explicit p_n issued '
                                                  || v_rows || ' lines against a store budget of ' || v_vol)
           ELSE params END
   WHERE run_id = v_run_id;

  RETURN jsonb_build_object(
    'already_issued', false,
    'over_budget_explicit', (p_mode = 'random' AND v_vol IS NOT NULL AND v_rows > v_vol),
    'daily_budget',  v_vol,
    'run_id',        v_run_id,$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_forge_log_count_run';
  IF src IS NULL THEN RAISE EXCEPTION 'BLOOM-029 item 4: rpc_forge_log_count_run not found'; END IF;
  IF (length(src)-length(replace(src,d_from,'')))/length(d_from) <> 1 THEN
    RAISE EXCEPTION 'BLOOM-029 item 4: DECLARE anchor is not unique'; END IF;
  src := replace(src, d_from, d_to);
  IF (length(src)-length(replace(src,g_from,'')))/length(g_from) <> 1 THEN
    RAISE EXCEPTION 'BLOOM-029 item 4: INSERT anchor is not unique'; END IF;
  src := replace(src, g_from, g_to);
  IF (length(src)-length(replace(src,r_from,'')))/length(r_from) <> 1 THEN
    RAISE EXCEPTION 'BLOOM-029 item 4: RETURN anchor is not unique'; END IF;
  src := replace(src, r_from, r_to);
  EXECUTE src;
END
$b029a$;

COMMIT;

-- ---------------------------------------------------------------------------
-- R22, measured at source 2026-09-02 after apply.
--
-- clause (b), reads only:
--   random 80175 no p_n   690 -> 200   (= store budget)
--   random 80176 no p_n   441 ->  70   (= store budget)
--   random 80175 p_n=500        -> 500 (explicit honoured, store total)
--   daily controls UNCHANGED: 10116 200 · 80175 200 · 21355 70 · 80176 70 · 80579 70
--   which is job 25's own 200/200/70/70/70, unmoved.
--
-- clause (a), on 80176 (the one store with no run today, so the test is clean):
--   call 1  already_issued=false  lines_logged=1  run_id 89f813a0…
--   call 2  already_issued=true   lines_logged=0  run_id 89f813a0…  SAME RUN
--   rows in forge_count_run from two calls: 1. Probe deleted after, 0 remaining.
-- ---------------------------------------------------------------------------
