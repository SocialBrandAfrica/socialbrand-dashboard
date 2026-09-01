-- ============================================================================
-- ENG-154 -- the cadence half of supplier_calendar rots, and the cutoff guard
--            reads the rot.
--
-- Ref:      BUG-LOG ENG-154 · ORDERING-CANON SSA5, SSA6 · RULE-BOOK R28, R29, R30
-- Author:   CC (Claude Code)
-- Date:     2026-09-01 SAST (clock read fresh at the write: local 08:50:11 /
--           UTC 06:50:11 / DB now() 06:50:15 UTC, all three +2 and agreeing)
-- Applies:  two function bodies. NO schema change. NO new config key.
--
-- ---------------------------------------------------------------------------
-- ROOT CAUSE, measured at source 2026-09-01, and it is NOT the guard.
-- ---------------------------------------------------------------------------
-- supplier_calendar has two halves and only one is maintained:
--   * the CUTOFF half  -- refresh_supplier_calendar_cutoff, pg_cron job 40,
--                         weekly since 2026-08-31 (ENG-048b).
--   * the CADENCE half -- refresh_supplier_calendar. ZERO cron jobs and ZERO
--                         callers in any function body. Verified at source.
--                         Last ran approximately 2026-07-18.
--
-- 10116 DIRECT_NATBRANDS proves it in its own source_note: the stored note
-- reads "median gap 10.5 ... cycle 1 wk", and CEIL(10.5/7 - 0.5) = 1, which was
-- CORRECT BY ITS OWN RULE when written. The same derivation today returns a
-- median gap of 13 -> cycle_weeks 2. The value did not derive wrong. It rotted.
--
-- The cutoff guard then reads that rotted input:
--     pair_ok = (pairs >= 5 AND bound_lead < cycle_weeks * 7)
--   10116: 8 < 1*7  -> FALSE -> falls to the dow basis -> cutoff 1
--   80175: 8 < 2*7  -> TRUE  -> cutoff derived from the demonstrated pair lead
-- Same route, same supplier behaviour, same Tuesday, same 8-day lead.
-- cycle_weeks is the ONLY differing input between the two stores.
--
-- Two hypotheses killed by the count BEFORE anything was built on them:
--   (1) the two supplier accounts at 10116 ({99, 2071}) are not the cause --
--       supplier 2071 has ZERO receipts in the 182-day window;
--   (2) the derivation is not broken -- run live it returns the right answer.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE DOES AND DOES NOT DO
-- ---------------------------------------------------------------------------
-- (a) puts the ENG-125 floor under the dow fallback branch.
-- (b) stops the cadence refresh from erasing the cutoff provenance.
-- It does NOT write any calendar row. Enacting the corrected cadence is a
-- separate, deliberate call (see the FOOT of this file), because it moves
-- quantity on a live desk.
--
-- Both patches are applied by ASSERTED replace() over pg_get_functiondef, so
-- the body this pass does not touch is never retyped through the channel (the
-- 2026-08-31 finding: this channel collapses a doubled backslash to one).
-- Verified before writing: both bodies carry ZERO backslashes and ZERO carriage
-- returns, and every anchor fragment below occurs EXACTLY ONCE.
-- Pre-change live pins: rpc_derive_order_cutoff  d217f4d84c6c86396ec577d36d6d5630 / 8138
--                       refresh_supplier_calendar 5f710a9e09b5be0b26f993fea483970b / 2387
-- ============================================================================


-- ----------------------------------------------------------------------------
-- (a) THE DOW FALLBACK GAINS THE FLOOR THE PAIR BASIS ALREADY HAS
--
-- ENG-125 ruled order_cutoff_floor_days a RULE, not a derivation, because the
-- observed leads are contaminated by the discipline that produced them, and it
-- ruled that the derived part may only RAISE the floor. That was applied to the
-- pair branch (GREATEST(floor, smallest lead demonstrated more than once)) and
-- never to the dow branch.
--
-- The defect in one line: a guard that rejects 8 days as implausible must not
-- then accept 1. 10116 DIRECT_NATBRANDS is exactly that -- the guard refuses an
-- 8-day lead as impossible on a 1-week cycle, falls through, and enacts 1.
--
-- Blast radius MEASURED across all 20 desks before writing: exactly ONE desk
-- moves (10116 DIRECT_NATBRANDS, 1 -> 2). Every other route on a dow basis
-- already sits at 3.
--
-- Degradation is safe by construction: GREATEST ignores NULLs in Postgres, so
-- if the config key were ever absent the expression returns dow_lead, which is
-- today's behaviour. This matches the idiom the pair branch already uses.
--
-- NAMED LIMIT, not fixed here: this does NOT cover the ELSE branch, which
-- carries the route's currently-enacted value. 80176 DIRECT_BEER carries 1
-- there today, and DB-SCHEMA records that 1 as Pieter's own attested floor
-- figure. That conflicts with order_cutoff_floor_days = 2 being a RULING and it
-- is a ruling to settle, never a value to quietly raise in code.
-- ----------------------------------------------------------------------------
DO $do$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;
  v_old  text := $frag$WHEN f.dow_ok  THEN f.dow_lead$frag$;
  v_rep  text := $frag$WHEN f.dow_ok  THEN GREATEST((SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'order_cutoff_floor_days' AND fc.store_format = '*' AND fc.retired_on IS NULL), f.dow_lead)$frag$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_derive_order_cutoff';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'ENG-154 (a) PRE-FLIGHT FAIL: rpc_derive_order_cutoff not found';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'ENG-154 (a) PRE-FLIGHT FAIL: anchor found % times, expected exactly 1', v_hits;
  END IF;

  v_new := replace(v_src, v_old, v_rep);

  IF position('order_cutoff_floor_days' in v_new) < 1 THEN
    RAISE EXCEPTION 'ENG-154 (a) PRE-FLIGHT FAIL: replacement did not land';
  END IF;

  EXECUTE v_new;
END
$do$;


-- ----------------------------------------------------------------------------
-- (b) THE CADENCE REFRESH MUST STOP ERASING THE CUTOFF PROVENANCE
--
-- refresh_supplier_calendar does SET source_note = v_note, an OVERWRITE, while
-- refresh_supplier_calendar_cutoff APPENDS " | cutoff derived <date>: ...".
-- Putting the cadence refresh on a schedule as it stands would wipe the entire
-- cutoff trail on every run -- an R29 provenance destruction, and the two jobs
-- would fight. This is the prerequisite for scheduling it at all.
--
-- The fix preserves the cutoff tail verbatim and refreshes only the cadence
-- half of the note. It is IDEMPOTENT: the cadence note is replaced each run and
-- the cutoff tail is carried, never duplicated.
--
-- This adds NO bytes per run, so it does not repeat the ENG-048b append problem
-- that forced job 40 to weekly rather than nightly.
-- ----------------------------------------------------------------------------
DO $do$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  a1_old text := $frag$  v_note text;$frag$;
  a1_new text := $frag$  v_note text;
  v_cutoff_tail text;$frag$;

  a2_old text := $frag$) INTO v_exists;$frag$;
  a2_new text := $frag$) INTO v_exists;

    -- ENG-154: carry the cutoff provenance the cutoff refresh appends. Without
    -- this, stamping the cadence half erases the whole cutoff trail (R29).
    SELECT CASE
             WHEN position(' | cutoff derived' in COALESCE(sc2.source_note, '')) > 0
             THEN substring(sc2.source_note from position(' | cutoff derived' in sc2.source_note))
             ELSE ''
           END
      INTO v_cutoff_tail
      FROM public.supplier_calendar sc2
     WHERE sc2.store_code = d.store_code AND sc2.route_key = d.route_key;
    v_cutoff_tail := COALESCE(v_cutoff_tail, '');$frag$;

  a3_old text := $frag$source_note             = v_note,$frag$;
  a3_new text := $frag$source_note             = v_note || v_cutoff_tail,$frag$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'refresh_supplier_calendar';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'ENG-154 (b) PRE-FLIGHT FAIL: refresh_supplier_calendar not found';
  END IF;

  -- every anchor must be present exactly once, or nothing is written
  v_hits := (length(v_src) - length(replace(v_src, a1_old, ''))) / length(a1_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ENG-154 (b) PRE-FLIGHT FAIL: anchor 1 found % times', v_hits; END IF;

  v_hits := (length(v_src) - length(replace(v_src, a2_old, ''))) / length(a2_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ENG-154 (b) PRE-FLIGHT FAIL: anchor 2 found % times', v_hits; END IF;

  v_hits := (length(v_src) - length(replace(v_src, a3_old, ''))) / length(a3_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ENG-154 (b) PRE-FLIGHT FAIL: anchor 3 found % times', v_hits; END IF;

  v_new := replace(v_src, a1_old, a1_new);
  v_new := replace(v_new, a2_old, a2_new);
  v_new := replace(v_new, a3_old, a3_new);

  IF position('v_cutoff_tail' in v_new) < 1 THEN
    RAISE EXCEPTION 'ENG-154 (b) PRE-FLIGHT FAIL: replacement did not land';
  END IF;

  EXECUTE v_new;
END
$do$;


-- ============================================================================
-- R22 -- run these AFTER applying, before the enact. Expected values stated so
-- the gate can FAIL. Every figure below was measured on the pre-change database
-- 2026-09-01 08:5x-09:1x SAST.
-- ============================================================================
-- 1. THE FLOOR MOVES EXACTLY ONE DESK OF TWENTY. Anything else is a defect.
--
--    SELECT store_code, route_key, cutoff_days, basis, dow_lead_days
--    FROM (SELECT * FROM rpc_derive_order_cutoff('10116') UNION ALL
--          SELECT * FROM rpc_derive_order_cutoff('21355') UNION ALL
--          SELECT * FROM rpc_derive_order_cutoff('80175') UNION ALL
--          SELECT * FROM rpc_derive_order_cutoff('80176') UNION ALL
--          SELECT * FROM rpc_derive_order_cutoff('80579')) t
--    WHERE basis LIKE 'derived_placement_dow%' AND cutoff_days <> dow_lead_days;
--
--    EXPECT: exactly 1 row -- 10116 DIRECT_NATBRANDS, cutoff_days 2, dow_lead_days 1.
--    Before the change that query returns 0 rows.
--
-- 2. THE NOTE MERGE PRESERVES THE CUTOFF TRAIL. Run the cadence refresh scoped,
--    then confirm the cutoff history survived:
--
--    SELECT store_code, route_key,
--           position(' | cutoff derived' in source_note) > 0 AS cutoff_trail_kept
--    FROM supplier_calendar WHERE route_key='DIRECT_NATBRANDS';
--
--    EXPECT: true on both stores. Before this fix the cadence refresh would
--    return false on any row it touched.
--
-- 3. THE ENACT, scoped to the one approved desk. Before/after in rands:
--
--    SELECT count(*) AS lines, count(*) FILTER (WHERE suggested_packs>0) AS ordered,
--           round(sum(suggested_packs*pack_cost)::numeric,2) AS value
--    FROM rpc_bloom_order_recipe(p_store_code=>'10116',
--           p_delivery_date=>date '2026-09-15', p_next_delivery=>date '2026-09-29',
--           p_route=>'DIRECT_NATBRANDS');
--
--    EXPECT AFTER: 24 lines, 19 ordered, R8,305.83  (BEFORE, at the stale
--    cycle_weeks=1 and its 09-08/09-15 dates: 6 lines, 3 ordered, R1,055.76.)
--
-- 4. NOTHING ELSE MOVED. 80175 DIRECT_NATBRANDS must be untouched:
--    cycle_weeks 2, delivery_dows {2}. Its stored order_cutoff_days is 8 and the
--    live derivation now returns 6 -- that gap is NOT this change, it is job 40
--    being a week stale, and it corrects itself on Sunday.
--
-- 5. RECIPE PIN UNMOVED. rpc_bloom_order_recipe md5 must still read
--    6204ae7bf6b12f1a17e8bcb3d72028ea / 44,251. Nothing here touches it.
-- ============================================================================


-- ============================================================================
-- NOT IN THIS FILE, DELIBERATELY -- each needs its own decision
-- ============================================================================
-- 1. ENACTING THE CORRECTED CADENCE. Scoped to the one approved route:
--
--      SELECT * FROM public.refresh_supplier_calendar('10116','DIRECT_NATBRANDS');
--      SELECT * FROM public.refresh_supplier_calendar_cutoff('10116','DIRECT_NATBRANDS');
--
--    Simulated before proposing, as a pure read:
--      A live  (cycle_weeks 1, delivery 2026-09-08, cover  7d):  6 lines,  3 ordered, R1,055.76
--      B fixed (cycle_weeks 2, delivery 2026-09-15, cover 14d): 24 lines, 19 ordered, R8,305.83
--    +R7,250.07, x7.9 -- and B lands 10116 on exactly 80175's derived answer on
--    every field. It is a CORRECTION, not a blow-out: the desk's own receipts
--    run R16,748 a fortnight, so the corrected order is about half its
--    demonstrated rate. The live state is offering 2026-09-08, which on the true
--    fortnightly cadence is not a delivery day at all, and an order of R1,055.76
--    against the desk's own R5,000 supplier minimum, which it cannot reach.
--
-- 2. DO NOT run refresh_supplier_calendar('10116') UNSCOPED. The full-refresh
--    dry read shows a SECOND desk moves: 10116 DIRECT_MONDELEZ, cycle_weeks
--    2 -> 3 (median gap 21 days). That is outside the ENG-154 ruling and needs
--    its own before/after in rands.
--
-- 3. SCHEDULING the cadence refresh weekly beside job 40 -- only after (b) is
--    live, and it inherits the same quantity-moving property, so it wants its
--    own ruling rather than landing unattended on a Sunday night.
--
-- 4. SIX DESKS ARE BELOW THE dow_confidence_min FLOOR (60) and none surfaces
--    VERIFY, which SSA5 requires: 10116 CLOVER 50.0, NATBRANDS 57.1;
--    80175 CLOVER 52.4, DANONE 52.2, MONDELEZ 50.0, NATBRANDS 57.1.
--    Separate finding, separate id.
--
-- 5. TWO STORED DELIVERY DOWS DIVERGE from the ledger (surfaced by the
--    derivation, never written): 10116 DIRECT_COCACOLA stored Friday against a
--    derived Thursday at 69.2% confidence -- this is BUG-LOG ENG-110,
--    re-confirmed live today; and 80175 DIRECT_MONDELEZ stored Wednesday
--    against a derived Thursday at 50.0%, below the floor.
-- ============================================================================
