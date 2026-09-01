-- ============================================================================
-- ENG-160 -- a derivation must not overwrite an attested fact, and where it
--            disagrees it SURFACES rather than silently yielding.
--
-- Ref:      BUG-LOG ENG-160 (next free READ FROM THE TABLE 2026-09-01: 157, 158 and 159 are
--           all occupied; ENG-154 is the cutoff dow-floor and ENG-159 is
--           PM's renumbered row -- next-free read from the table, not assumed,
--           after the ENG-101/103 and ENG-154 collisions)
-- Author:   CC (Claude Code), on PM's hand-off of 2026-09-01
-- Date:     2026-09-01 SAST
-- Applies:  one function body. NO schema change. NO new config key.
-- Pre-change live pin: refresh_supplier_calendar_cutoff
--                      25d899f1d8472dc580613fbb701f212f / 1437 chars, 0 backslashes.
--                      Both anchors below occur EXACTLY ONCE (asserted at apply).
--
-- ---------------------------------------------------------------------------
-- THE LOOP, in PM's words: "We settle it, the machine forgets, we re-open it."
-- ---------------------------------------------------------------------------
-- refresh_supplier_calendar (cadence) already gets this right -- it PRESERVES
-- delivery_dows and only surfaces a divergence note. refresh_supplier_calendar_cutoff
-- does the opposite: it overwrites order_cutoff_days, order_cutoff_basis and
-- order_cutoff_anomaly UNCONDITIONALLY from the derivation. So a floor
-- attestation has a shelf life of exactly one refresh.
--
-- THE EXPOSURE IS THREE ROWS, NOT TWO -- verified at source 2026-09-01 before
-- writing. PM's hand-off named the two beer desks; the third is the largest
-- SPAR desk in the estate and its own source_note already predicts the loss:
--   * 21355 DIRECT_BEER  cutoff 1  floor_attested (Pieter 2026-09-01)
--   * 80176 DIRECT_BEER  cutoff 1  floor_attested (Pieter 2026-09-01)
--   * 10116 DC_AMBIENT   cutoff 2  floor_attested_modal_lead (Pieter 2026-08-31)
--     -- its note reads "Job 40 will re-derive this back to 3 on Sunday until
--     the statistic is fixed."
--
-- BOUNDED, so the exposure is not overstated: all three values are safe TODAY,
-- because the derivation independently returns the attested number on each
-- (beer 1 via the dow branch, DC_AMBIENT 2 since ENG-125 replaced the median
-- with the smallest lead demonstrated more than once). What churns today is the
-- RECORD -- the basis string that says a human settled this, and why. What
-- churns tomorrow is the VALUE, the first time evidence drifts.
--
-- ---------------------------------------------------------------------------
-- WHY A SILENT SKIP IS NOT ENOUGH (this is the half beyond the WHERE clause)
-- ---------------------------------------------------------------------------
-- Guarding by WHERE alone protects the attestation and teaches nobody anything.
-- An attested fact can go stale against the ledger, and a guard that skips in
-- silence is how it would stay stale forever -- the same forgetting, pointed the
-- other way. So attested rows still get a NOTE when the derivation disagrees,
-- carrying both numbers and the date. That is R29, and it is exactly the shape
-- refresh_supplier_calendar already uses for a dow divergence.
--
-- FORWARD RISK CLOSED, and it is one I introduced. ENG-154 patch (a) put
-- GREATEST(order_cutoff_floor_days, dow_lead) on the dow branch. Beer sits on
-- the ELSE branch today, so the floor does not reach it -- but if a beer desk
-- ever accumulates 5 placements at 60% confidence it lands on the dow branch and
-- the floor would silently raise an attested 1 to 2, which Pieter has now ruled
-- wrong for this route. With this guard the derivation may still RETURN 2; it can
-- no longer be WRITTEN. The derivation is deliberately left alone: it should keep
-- saying what the evidence says, the attestation overrides it, and the divergence
-- note records both. Making the derivation attestation-aware is a second change
-- and wants its own ruling rather than being bundled here.
-- ============================================================================

DO $do$
DECLARE
  v_src  text;
  v_new  text;
  v_hits int;

  -- (1) the guard: attested rows are never overwritten by the derivation
  a1_old text := $frag$WHERE c.store_code = d.store_code AND c.route_key = d.route_key;$frag$;
  a1_new text := $frag$WHERE c.store_code = d.store_code AND c.route_key = d.route_key
     -- ENG-160: an attested cutoff is a RULING (R28 evidence class), not a
     -- derivation, and a derivation may not overwrite it. Divergence is
     -- surfaced by the statement below, never enacted here.
     AND COALESCE(c.order_cutoff_basis, '') NOT LIKE 'floor_attested%';$frag$;

  -- (2) surface disagreement on the rows the guard just protected (R29)
  a2_old text := $frag$GET DIAGNOSTICS v_moved = ROW_COUNT;$frag$;
  a2_new text := $frag$GET DIAGNOSTICS v_moved = ROW_COUNT;

  -- ENG-160: the attested rows are skipped above. Where the derivation now
  -- DISAGREES with what was attested, say so on the row: both numbers, the
  -- basis the derivation reached, and the date. Never rewrite the value.
  UPDATE supplier_calendar c
     SET source_note = COALESCE(c.source_note,'')
           || format(' | %s DERIVATION DIVERGES from the attested cutoff: derived %s day(s) (basis %s) against the attested %s. Attestation STANDS and is not overwritten (ENG-160). Re-attest or clear the floor_attested basis if the ledger has genuinely moved.',
                     CURRENT_DATE, d.cutoff_days, d.basis, c.order_cutoff_days),
         updated_at = now()
    FROM public.rpc_derive_order_cutoff(p_store_code, p_route_key) d
   WHERE c.store_code = d.store_code AND c.route_key = d.route_key
     AND COALESCE(c.order_cutoff_basis, '') LIKE 'floor_attested%'
     AND d.cutoff_days IS DISTINCT FROM c.order_cutoff_days;$frag$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'refresh_supplier_calendar_cutoff';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'ENG-160 PRE-FLIGHT FAIL: refresh_supplier_calendar_cutoff not found';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, a1_old, ''))) / length(a1_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ENG-160 PRE-FLIGHT FAIL: anchor 1 found % times, expected 1', v_hits; END IF;

  v_hits := (length(v_src) - length(replace(v_src, a2_old, ''))) / length(a2_old);
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ENG-160 PRE-FLIGHT FAIL: anchor 2 found % times, expected 1', v_hits; END IF;

  v_new := replace(v_src, a1_old, a1_new);
  v_new := replace(v_new, a2_old, a2_new);

  IF position('ENG-160' in v_new) < 1 THEN
    RAISE EXCEPTION 'ENG-160 PRE-FLIGHT FAIL: replacement did not land';
  END IF;

  EXECUTE v_new;
END
$do$;


-- ============================================================================
-- R22 -- expected values stated so the gate can FAIL. Measured pre-change
-- 2026-09-01 at source.
-- ============================================================================
-- 1. THE THREE ATTESTED ROWS SURVIVE A RE-DERIVATION UNCHANGED.
--    Capture, run, compare:
--
--    SELECT store_code, route_key, order_cutoff_days, order_cutoff_basis
--    FROM supplier_calendar WHERE order_cutoff_basis LIKE 'floor_attested%'
--    ORDER BY store_code;                                   -- 3 rows, note them
--
--    SELECT public.refresh_supplier_calendar_cutoff('21355');
--    SELECT public.refresh_supplier_calendar_cutoff('80176');
--    SELECT public.refresh_supplier_calendar_cutoff('10116');
--
--    Re-run the first query. EXPECT: identical on all three rows --
--      21355 DIRECT_BEER 1, 80176 DIRECT_BEER 1, 10116 DC_AMBIENT 2,
--      and every basis string still beginning 'floor_attested'.
--    BEFORE this patch, all three bases are replaced by the derivation's own.
--
-- 2. NON-ATTESTED ROWS STILL REFRESH NORMALLY. The same three calls must still
--    write the other routes at those stores. EXPECT rows_written > 0 at 10116
--    (it carries 6 non-attested routes) and the 10116 DIRECT_NATBRANDS cutoff
--    that ENG-154 moved to 2 stays 2.
--
-- 3. NO DIVERGENCE NOTE TODAY, because nothing diverges today. EXPECT zero rows:
--
--    SELECT store_code, route_key FROM supplier_calendar
--    WHERE source_note LIKE '%DERIVATION DIVERGES%';
--
--    This one is the honest check on the whole patch: if it returns rows now,
--    an attested value already disagrees with its own ledger and that is a
--    finding, not a bug in this file.
--
-- 4. IDEMPOTENT. Run the three calls twice. The divergence note must not
--    duplicate on a second pass where nothing changed (it appends only on
--    IS DISTINCT FROM, so a matching row is never touched).
--
-- 5. JOB 40 STILL HAS NEVER RUN -- runs_ever = 0, verified at source
--    2026-09-01. Its first firing is the real test of this guard, and it is a
--    Sunday. Nothing here changes its schedule.
-- ============================================================================
