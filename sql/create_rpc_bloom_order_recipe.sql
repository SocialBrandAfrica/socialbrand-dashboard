-- =============================================================================
-- RECONCILED TO LIVE 2026-09-11 by CC. THE BODY BELOW IS THE LIVE BODY, BYTE FOR BYTE.
--     LIVE  c085128d9b767e471bf4d4d05924db22  / 45,221 chars
--     (ENG-183 (B), migration eng183b_desk_split_recipe, 2026-09-11 11:47 SAST)
-- Exported from pg_get_functiondef through the MCP result file as base64, md5-proven on
-- disk with the hash-gate extraction, all 13 backslashes intact. That removes the channel
-- reason every stamp below gives for leaving this file ROTTED. The stamps stay as history
-- (R28). Test: the text from the line starting CREATE OR REPLACE FUNCTION to the closing
-- dollar-quote, plus one newline, hashes to the md5 above.
-- Prior live bodies: 70d99c33906f4e69fc243d1de9fbfeb0 (ENG-082, 2026-09-10, retired
-- 2026-09-11) and 49960b1265f3bad8839d763cd0088eef (kept whole at
-- sql/_archive/rpc_bloom_order_recipe_49960b12_pre-ENG-082.sql).
--
-- Prior top line, retired 2026-09-11 (R28):
-- !!! THIS FILE'S BODY IS ROTTED AGAINST LIVE. DO NOT RECONCILE ANYTHING TO IT. !!!
--
-- RE-STAMPED AGAIN by CC 2026-09-10. THE PIN MOVED A FOURTH TIME (ENG-082).
--     OLD  49960b1265f3bad8839d763cd0088eef  / 44,371 chars
--     NEW  70d99c33906f4e69fc243d1de9fbfeb0  / 44,828 chars
-- The move is +457 chars and it is exactly the six asserted replaces in
-- sql/eng082_promo_close_thursday_of_end_week.sql: promo_geared (the shelf promo
-- still runs on the delivery date) is split from promo_active (promo sheet
-- membership), so a line matched after its shelf end, under the Thursday rule
-- (Pieter ruling 2026-09-10), rides the promo sheet at its NORMAL quantity and is
-- never geared. R22 in DEPLOY-LOG 2026-09-10. Same channel reason as below: the
-- body was patched by asserted replace, so this file is re-stamped, not re-copied.
--
-- Prior stamp: RE-STAMPED AGAIN by CC 2026-09-02 11:0x SAST. THE PIN MOVED A THIRD TIME.
--     OLD  6204ae7bf6b12f1a17e8bcb3d72028ea  / 44,251 chars
--     NEW  49960b1265f3bad8839d763cd0088eef  / 44,371 chars   (ENG-102)
-- The move is +120 chars and it is exactly the two ENG-102 clauses, one on the
-- DELETE gate and one on the RETURN gate, widening the keep condition so a
-- CORE/HERO line at or below its own min_band is RETAINED at zero quantity
-- instead of deleted. R22 across all 20 desks: rows 3,020 -> 3,489, value
-- R1,466,857.16 -> R1,466,857.16 to the cent, packs 5,889 -> 5,889, added rows
-- carrying quantity 0, rows lost 0. Migration sql/eng102_surface_covered_lines.sql.
--
-- 🔴 AND THE REGENERATION IS STILL NOT DONE, FOR THE REASON ALREADY MEASURED
-- BELOW, NOT A NEW ONE. ENG-102 was applied by the same asserted-replace method
-- the 2026-08-30 note describes, so this seat never held the full body either.
-- Re-transcribing it through the session channel remains UNSAFE on the measured
-- 13-backslash finding. The debt is unchanged in kind and is not claimed closed.
--
-- Prior stamp: RE-STAMPED by CC 2026-08-30 20:2x SAST, after the A3 bundled pass
-- moved the live body. Clock settled three ways at +2 in that session.
--
-- ⚠ THE PIN MOVED TODAY. The A3 bundled pass (ENG-142 sites 9+10 + ENG-147
-- residual) repointed two blocks to their one homes:
--     OLD  48bdc629c142f68e7342e3ae15444ab8  / 44,383 chars
--     NEW  6204ae7bf6b12f1a17e8bcb3d72028ea  / 44,251 chars
-- R22 was exact: 2,679 lines across all 20 desks, before vs after, ZERO rows
-- differing in either direction, 4,161 packs = 4,161 packs, R1,180,357.11 =
-- R1,180,357.11, delta R0.00. Both repoints were proven neutral BEFORE they were
-- made (1,095-date exhaustive equality; 23,583 promo rows, 0 diffs).
--
-- 🔴 AND THE FILE IS STILL ROTTED. THE 2026-08-19 CLOSE PLAN BELOW IS
-- STRUCTURALLY UNREACHABLE, WHICH IS THE REAL FINDING AND IT IS NEW.
-- That plan said: the debt closes on the next recipe-touching ship, because at
-- that moment CC will have authored the full new body as text. **Today WAS that
-- ship and the plan did not work, for a reason that will recur every single
-- time.** PRE-FLIGHT forbids hand-transcribing a 44KB body into a migration, so
-- the pass was applied by ASSERTED replace() on the live body -- ten anchor
-- assertions, raise-or-nothing. That is the correct and safer method for the
-- DATABASE, and it structurally means CC NEVER HOLDS THE FULL TEXT. The two
-- disciplines are in direct tension: the method that protects the live function
-- is the method that cannot produce this file. No future recipe ship closes this
-- debt either, unless the channel changes.
--
-- ⚠ THE TRANSCRIPTION ROUTE IS NOT MERELY TEDIOUS, IT IS UNSAFE, AND THAT IS NOW
-- MEASURED RATHER THAN ASSERTED. The live body contains EXACTLY 13 backslashes
-- (counted at source, 2026-08-30). They live in `LIKE 'DIRECT\_%' ESCAPE '\'`
-- clauses on the route branch. The session channel that carries the body to a
-- seat re-escapes backslashes ambiguously -- two displayed lines alone imply
-- eight, against a true whole-body total of thirteen. A wrong count yields a
-- file that LOOKS right, APPLIES cleanly, and silently changes LIKE-pattern
-- semantics on the DC/DIRECT split of the money function. A known-rotted file is
-- safer than a quietly-wrong one, so nothing was written.
--
-- ⭐ THE ACTUAL FIX IS A CHANNEL, NOT A DISCIPLINE. Give the repo a mechanical
-- dump path and this closes in seconds, forever, for every object and not just
-- this one: a service_role-scoped script (`npm run dump-sql <proname>`) writing
-- pg_get_functiondef straight to sql/, or a paste from the Supabase SQL editor
-- (browser to file, no lossy hop). The service key must NOT come into
-- .env.local, which correctly carries only the anon key. Owner: needs Pieter's
-- word on where the key lives. Until then this debt cannot be closed by effort.
--
-- THE AUTHORITY IS THE LIVE BODY, reached by:
--     SELECT pg_get_functiondef(oid) FROM pg_proc
--     WHERE proname = 'rpc_bloom_order_recipe';
--
-- LIVE PIN, verified at source 2026-08-30 AFTER the A3 bundled pass:
--     md5    = 6204ae7bf6b12f1a17e8bcb3d72028ea
--     length = 44,251 chars
--     (superseding 48bdc629c142f68e7342e3ae15444ab8 / 44,383, which every
--      brief and BUG-LOG row written before 2026-08-30 cites. R28: that pin is
--      `retired_on` 2026-08-30, `superseded_by` this one.)
-- THIS FILE below the header: 48,747 bytes of body, hand-authored, DRIFTED.
-- The two are NOT the same function. Every figure, CTE name and guard in the
-- body below must be checked against live before it is believed or quoted.
--
-- WHY IT IS STILL ROTTED, stated rather than hidden (R28 / SS0i -- a named debt,
-- never a silent one). PM asked for a regen from live so recipe changes become a
-- git diff instead of archaeology (SB-PRIORITY v1.4, no-divergence). That regen
-- needs the 44,383-char body moved byte-exactly into this file. This seat has no
-- channel that can do that safely: there is no psql and no DATABASE_URL, .env.local
-- carries only the public anon key (no service_role), and the recipe body is not
-- reachable through PostgREST. The only remaining route is hand-transcription
-- through the session, on SQL carrying nested $q$ dollar-quoting and
-- LIKE 'DIRECT\_%' ESCAPE '\' -- where a single wrong character produces a file
-- that is SILENTLY wrong. A known-rotted file is safer than a quietly-wrong one.
--
-- THE FIX, and it costs nothing when taken at the right moment: the next change to
-- this recipe is authored as a migration BY CC, so at that moment the full new body
-- exists as text CC wrote. Write THIS file from that text in the same commit, and
-- from then on every recipe change is a real git diff. SB-CC-BLOOM-026 part (a)
-- (the wider-window in-stock pantry read) and part (e) (the receipts tiebreak,
-- ORDERING-CANON SSH8) both rewrite this function, so the debt closes on the next
-- recipe-touching ship. Owner CC. Do not close it by transcription.
--
-- GATE for whoever does it: after writing, prove it rather than assert it --
--     md5(pg_get_functiondef(oid)) on live  ==  md5 of the body written here,
-- both normalised the same way. No hash, no claim.
-- =============================================================================
-- create_rpc_bloom_order_recipe.sql
-- SB-CC-BLOOM-004 item 5 -- the profile-driven Recipe RPC.
--
-- ============== ENG-033: THE SAB DESK IS ACCOUNT-SCOPED (2026-07-21) ==========
-- Pieter ruling relayed by PM 2026-07-21: "re-scope the SAB desk to the supplier
-- account like every other desk, no manual skip-lists, fix once not twice."
-- DIRECT_BEER loses its own branch and joins the DIRECT_* code path: its pool is
-- the products carrying an active link to its receipt-proven supplier ACCOUNT
-- (bloom_route_config.direct_supplier_nrs -- 21355/80579 = 555, 80176 = 590, all
-- type F, all receipt-proven; the link-only 1392 "SAB BREWERIES" with zero receipts
-- ever is excluded, canon SS14 v9 7d, same pattern as CLOVER 1611 at 10116).
--
-- RETIRED WITH LINEAGE (R28, retired_on 2026-07-21, superseded_by this pass), never
-- deleted: (a) merch_group_nrs {201..205,401} as the DIRECT_BEER pool scope, and
-- (b) the ENG-029 "must have SOME non-Z direct receipt in 182d" gate bolted onto it.
-- Account scope subsumes both. ENG-029 existed to stop link-only DC-supplied beer
-- (Distell/Diageo/Heineken/DGB/Isicebi) riding the desk; those products are simply
-- not linked to the SAB account, so they cannot enter. It also settles A2 (merch
-- groups 301/302): the SAB-supplied 301/302 lines enter on their own account while
-- the DC-dominated ones never do -- which is why the merch-group ADD was refused
-- and this re-scope was ruled instead.
--
-- Identity-independent by construction: keys on product_code / supplier_nr /
-- receipts via v_supplier_class, touches no EAN and no TLX zeroing, so it sits
-- OUTSIDE the Track-B Phase-1 identity freeze (PM sequencing ruling, same day).
-- The ledger key is UNCHANGED -- v_ledger_route still returns 'DIRECT_BEER', so
-- the SAB budget rail (ENG-013) is untouched.
--
-- =========================== BLOOM-008 POST-WALK RECOVERY (v10, 2026-07-12) ==
-- CLEANUP-ENGINE-CANON SS14 ADDENDUM v10 (Pieter's floorwalk, WALK-FINDINGS
-- W1-W33) -- recovers BLOOM-008 items 1-4, the redefinition that was
-- CANONISED (SS14 v8) and PM-tested at 10116 on 2026-07-12 BEFORE this
-- build, but never actually wired into the recipe. The live recipe was
-- frozen at BLOOM-007 (the flat 21-day essentials build) the whole time,
-- so essentials breached its own max band on 558/558 ordered lines
-- (W20 root-cause finding). This is RECOVERY of already-ruled logic, not a
-- rewrite of the engine's own demand/promo/band machinery below (ENG-012
-- through ENG-018, the demand-window resolution, the promo-uplift ladder --
-- all UNCHANGED, reused exactly as they were, per R21/R27's own "the
-- pantry stocks it, the recipe picks" discipline and this session's
-- explicit instruction: "reuse, do not reinvent").
--
-- ITEM 1 -- RANGE STATE (W27, canon v10). Every pool line now carries one
--   of HERO/CORE/SLOW/MARKDOWN/DERANGE/VERIFY from the new l2_range_state
--   pantry table (sql/create_l2_range_state.sql) -- assembled from signals
--   that already exist (l2_bt_heroes, l2_kvi_profile.passes_life_gate,
--   l2_classification buckets). This fact now DRIVES depth and scope,
--   replacing the old flat-day-cover preset system entirely.
--
-- ITEM 2 -- DEPTH + THE UNIVERSAL MAX-BAND CEILING (W22, W31a). HERO always
--   targets max_band (never empty, ordered to the order-up-to level, budget
--   permitting). CORE targets "the band" (min_band in minimum mode,
--   max_band in build/month-end mode -- UNCHANGED archetype mechanism,
--   ENG-012's order-time recompute untouched). SLOW/MARKDOWN/DERANGE/VERIFY
--   NEVER order (target = current SOH, need = 0) -- they still RETURN in
--   the result set with their range_state + reason (R21 SS5, never hidden),
--   just at zero depth. max_band is now a HARD CEILING IN EVERY SCENARIO,
--   no exception: a line whose minimum ONE pack would push stock past its
--   own max_band is not ordered at all -- `pack_forced_review=true`,
--   `suggested_packs=0`, routes to a human review flag instead (closes the
--   461-line pack-forced breach W30 red-team found; retires the old
--   canon v9 items 2/3 "pack-size exception", superseded with lineage --
--   v10 makes the ceiling universal). A HERO tripping this same edge gets
--   its own `hero_pack_over_max=true` flag (never silently under-served,
--   never silently forced over cap -- a genuine collision between
--   hero-never-empty and never-over-max that only a human can resolve:
--   smaller pack, loose unit, or a deliberate one-pack call).
--
-- ITEM 3 -- SCENARIOS AS SCOPE OVER STATES (W23, W24, W31b, canon v10).
--   The scope/depth split retires every old preset-specific flat-day
--   override:
--     FULL      (p_preset NULL, p_fit_to_budget=false) -- HERO + CORE,
--       whole selling range, each at its own normal band depth.
--     FITTED    (p_preset NULL, p_fit_to_budget=true)  -- FULL's own order,
--       then item 4's cash fit (below).
--     ESSENTIALS (p_preset='order_essentials') -- HERO always to max; CORE
--       lines that are KVI (kvi_band CRITICAL/IMPORTANT) OR promo_active
--       get their NORMAL band depth (same as full); every other CORE line
--       gets MIN-BAND PRESENCE ONLY (never build-mode max), regardless of
--       archetype. No tail (SLOW/MARKDOWN/DERANGE/VERIFY) ever orders. The
--       old flat 21-day/10-day cash-gated essentials cover (canon v7 item 3)
--       RETIRES WITH LINEAGE here -- `order_budget_ledger.cash_constrained`
--       stays live for any other reader, just no longer consulted by this
--       preset.
--     CATCH_UP  (p_preset='catch_up') -- the STORE-LEVEL restore program
--       (W23/W31b, pin closed: "standard order-up-to level, not the bare
--       reorder trigger"). Eligible pool = HERO union CORE with real demand
--       (ros_final>0). HERO is unconditionally filled first (never subject
--       to the cutoff, per HERO's own never-empty rule). CORE lines rank
--       (kvi_band priority, then gmroi_rank ASC) and fill top-down to their
--       own max_band, walking down the range until the FIRST of: (a) the
--       cumulative aggregate stock-days-of-cover across the whole eligible
--       pool reaches `p_store_target_days` (21, DEMO_CALIBRATION), using
--       the SAME stock-at-cost / daily-cost-demand formula as
--       rpc_bloom_stock_state (item 7) for a consistent reading between the
--       instrument and the order; or (b) the cumulative committed value
--       reaches this week's budget. Lines beyond the cutoff return at 0
--       packs, reason 'catchup_below_cutoff', never silently dropped from
--       the result set. GEARED = the identical order with promo-active
--       lines' quantities lifted (unchanged dual normal/geared mechanism,
--       item 5/6 stretch -- not touched this pass).
--
-- ITEM 4 -- FIT-TO-CASH, PROPORTIONAL, FLOOR-PROTECTED (W25, W30 red-team
--   fix #1, canon v10). p_fit_to_budget=true (FULL->FITTED; CATCH_UP has
--   its OWN budget-aware walk above and does not run this branch a second
--   time): compute the scenario's own order first (unchanged), then
--   PROTECT every HERO line and every KVI_CRITICAL/KVI_IMPORTANT CORE line
--   at its full computed quantity (`budget_fit_reason='protected_kvi_hero'`,
--   the W30 fix -- the OLD GMROI-waterfall trim that could shave a KVI line
--   to zero is RETIRED WITH LINEAGE), then scale ONLY the remaining
--   (non-KVI CORE) quantities DOWN proportionally, in the same ratios, so
--   their combined value fits the cash remaining after the protected spend
--   (never scales UP past 1.0 -- fit only trims). Manual budget overrides
--   (W5/W14, `order_budget_ledger.budget_manual_override`, already shipped)
--   need no change here -- they only change how `v_weekly_budget` itself
--   was seeded, which this function already reads verbatim.
--
-- ITEMS 5/6 -- gearing law cap (band headroom / 1.5x) + the buy-in-for-
--   profit toy -- STRETCH, explicitly NOT built this pass (W33 priority:
--   items 1-4 tonight, 5-6 tomorrow). The existing promo-uplift gear
--   mechanism is UNCHANGED, but geared quantities now ALSO respect the
--   same universal max_band ceiling as everything else (never silently
--   MORE permissive than the ungeared path while the buy-in-for-profit
--   exception that would justify exceeding it does not exist yet) --
--   geared_packs is capped at the maximum whole packs that fit under
--   max_band, never force-zeroed like a breached NORMAL/HERO minimum.
--
-- =========================== PRE-v10 HISTORY (UNCHANGED MECHANISM, kept for
-- provenance -- ENG-012 order-time band recompute, ENG-013 SAB ledger
-- route, ENG-014 count_first claim-sign split, ENG-015 tiered demand
-- resolution (scan/draw GREATEST, the ENG-005 family-draw precedent),
-- ENG-016 budget-week attribution, ENG-017 promo buy-in window + naming,
-- ENG-019 NULL-guard on the three build-day params. Full narrative in prior
-- commits of this file (git history) -- not restated here since none of
-- these formulas changed in the v10 pass, only WHERE their output feeds
-- (target_level, scope) changed.
--
-- =========================== v12 (2026-07-20, SB-CC-BLOOM-014, canon SS14 v12,
-- amends v10 DEPTH with lineage) -- MINIMUM PRESENCE + LIKELY-TO-DERANGE.
-- The 80175 DC_AMBIENT Full audit left 387 empty, still-selling lines at zero
-- (343 CORE, 41 SLOW, 2 HERO) because v10's universal ceiling zeroed any line
-- whose single supplier pack breaches it -- the DF-7 phantom-death spiral, the
-- opposite of Full's own availability job. v12 (all in the packs_mp/
-- packs_ceiled/geared_ceiled/resolved CTEs, %8$L IS NULL guarding it to REAL
-- scenarios so the yardstick/stock_state diagnostic path is untouched):
--   1. A life-gate line (range_state HERO/CORE) whose PROJECTED soh at
--      delivery is below its own min_band gets at least one pack; that FIRST
--      pack is exempt from the 35-day ceiling; the ceiling still caps pack 2+.
--      Trigger is the projection below min_band, so it fires above soh 0 too.
--   2. A SLOW line earns the same one-pack minimum ONLY where one pack turns
--      within relevant_min_cover_days (forge_config, DEMO_CALIBRATION, 60);
--      a slower SLOW pack is likely-to-derange -> keep_or_delist=true, NOT
--      ordered, surfaced for a keep-or-delist range decision.
--   3. MARKDOWN/DERANGE/VERIFY unchanged (never order). HERO never silently
--      zeroed -- it orders its one exempt pack and carries hero_pack_over_max.
-- New output columns min_presence_forced / keep_or_delist (additive, name-safe
-- for every caller). R32 clean: config + recipe + labels, no schema change.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb);
DROP FUNCTION IF EXISTS public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text);

CREATE OR REPLACE FUNCTION public.rpc_bloom_order_recipe(p_store_code text, p_delivery_date date, p_next_delivery date DEFAULT NULL::date, p_soh_date date DEFAULT NULL::date, p_preset text DEFAULT NULL::text, p_days_cover_override numeric DEFAULT NULL::numeric, p_fit_to_budget boolean DEFAULT false, p_month_end_build_start_day integer DEFAULT 15, p_month_end_build_end_day integer DEFAULT 24, p_early_month_build_start_day integer DEFAULT 25, p_catchup_band_cap_multiple numeric DEFAULT 3.0, p_route text DEFAULT NULL::text, p_soh_override jsonb DEFAULT NULL::jsonb, p_store_target_days integer DEFAULT 21, p_max_order_stock_days numeric DEFAULT 35)
 RETURNS TABLE(store_code text, product_code bigint, ean text, description text, dept_name text, route text, kvi_band text, archetype text, tier text, mode text, mode_reason text, range_state text, range_state_reason text, demand_source text, ros_window_used text, rhythm_adjusted_demand numeric, min_band numeric, max_band numeric, target_level numeric, soh numeric, lead_days_used integer, lead_days_source text, projected_soh numeric, count_first boolean, band_blocked_reason text, pack_forced_review boolean, hero_pack_over_max boolean, min_presence_forced boolean, keep_or_delist boolean, need_units numeric, pack_size smallint, pack_cost numeric, normal_packs integer, promo_active boolean, promo_nr bigint, promo_start date, promo_end date, promo_uplift numeric, promo_uplift_source text, promo_suffix text, promo_naming_gap boolean, geared_packs integer, packs_before_fit integer, suggested_packs integer, value numeric, gmroi_quartile integer, gmroi_capped boolean, gmroi_rank integer, budget_fit_applied boolean, budget_fit_reason text, budget_week_start date, budget_week_source text, is_bt_hero boolean, preset_applied text, frozen_focus_pending boolean, story text, promo_in_window boolean, promo_band_demand numeric, promo_uplift_band numeric, promo_uplift_band_source text, promo_uplift_band_basis text, promo_floor_units numeric, promo_shortfall_units numeric, promo_shortfall_packs integer, promo_shortfall_rand numeric, promo_gap_reason text, in_transit_qty numeric, in_transit_cost numeric, in_transit_landing date, in_transit_counted boolean, in_transit_routes text, in_transit_lead_basis text, in_transit_landing_state text, in_transit_stale_qty numeric, in_transit_stale_age_days integer, in_transit_reason text, pack_content text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int;
  v_override numeric;
  v_preset_essentials boolean;
  v_preset_catchup boolean;
  v_preset_applied text;
  v_fit_to_budget boolean;
  v_weekly_budget numeric;
  v_next_delivery date;
  v_format_group text;
  v_dept_nrs smallint[];
  v_ledger_route text;
  v_week_start date;
  v_week_source text;
  v_dows smallint[];
  v_buyin_lead_days int;
  v_band_violations int;
  v_sql text;
  v_direct_supplier_nrs bigint[];
  v_relevant_min_cover_days numeric;
  v_build_start_dom int;
  v_build_end_dom int;
  v_payday_dom int;
BEGIN
  SET LOCAL statement_timeout = '30s';

  p_month_end_build_start_day := COALESCE(p_month_end_build_start_day, 15);
  p_month_end_build_end_day := COALESCE(p_month_end_build_end_day, 24);
  p_early_month_build_start_day := COALESCE(p_early_month_build_start_day, 25);
  p_store_target_days := COALESCE(p_store_target_days, 21);
  p_max_order_stock_days := COALESCE(p_max_order_stock_days, 35);

  SELECT fc.value_num INTO v_relevant_min_cover_days
  FROM forge_config fc
  WHERE fc.config_key = 'relevant_min_cover_days' AND fc.store_format = '*' AND fc.retired_on IS NULL
  LIMIT 1;
  v_relevant_min_cover_days := COALESCE(v_relevant_min_cover_days, 60);

  IF p_route IS NULL THEN
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk (canon SS14 v7 item 1 / v9 item 7)';
  END IF;

  IF p_route IN ('DC_AMBIENT','DC_TOPS') THEN
    SELECT dc.dc_cycle_dept_nrs, dc.format_group INTO v_dept_nrs, v_format_group
    FROM bloom_dc_config dc WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
    IF v_dept_nrs IS NULL THEN
      RAISE EXCEPTION 'no RULED bloom_dc_config row for store %', p_store_code;
    END IF;
    IF (p_route = 'DC_AMBIENT' AND v_format_group <> 'SPAR')
       OR (p_route = 'DC_TOPS' AND v_format_group <> 'TOPS') THEN
      RAISE EXCEPTION 'p_route % does not match store % (format %)', p_route, p_store_code, v_format_group;
    END IF;
  ELSIF p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN
    -- ENG-033 (Pieter ruling via PM, 2026-07-21): the SAB desk is scoped by its
    -- receipt-proven supplier ACCOUNT like every later direct desk. One code path
    -- now serves every DIRECT_* route.
    SELECT rc.direct_supplier_nrs INTO v_direct_supplier_nrs
    FROM bloom_route_config rc WHERE rc.store_code = p_store_code AND rc.route_key = p_route AND rc.status = 'RULED';
    IF v_direct_supplier_nrs IS NULL THEN
      RAISE EXCEPTION 'no RULED bloom_route_config row for store % route %', p_store_code, p_route;
    END IF;
  ELSE
    RAISE EXCEPTION 'p_route is required: DC_AMBIENT, DC_TOPS, DIRECT_BEER or a RULED DIRECT_<brand> desk (canon SS14 v7 item 1 / v9 item 7)';
  END IF;

  v_ledger_route := CASE
    WHEN p_route = 'DIRECT_BEER' THEN 'DIRECT_BEER'
    WHEN p_route LIKE 'DIRECT\_%' ESCAPE '\' THEN 'DIRECT'
    ELSE 'DC'
  END;

  SELECT sc.delivery_dows, sc.promo_buyin_lead_days INTO v_dows, v_buyin_lead_days
  FROM supplier_calendar sc WHERE sc.store_code = p_store_code AND sc.route_key = p_route;
  v_dows := COALESCE(v_dows, ARRAY[1,2,3,4,5,6,7]::smallint[]);
  v_buyin_lead_days := COALESCE(v_buyin_lead_days, 7);

  SELECT MAX(ss.sale_date) INTO v_anchor FROM sigma_sales ss WHERE ss.store_code=p_store_code AND ss.period_kind='T' AND ss.txn_kind=1;
  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt FROM l2_soh_daily sd WHERE sd.store_code=p_store_code;
  v_dom := EXTRACT(DAY FROM p_delivery_date)::int;

  -- Bug 2 (ENG-083 / canon 14 v16 build-timing + 16.7 leg 2, Pieter 2026-08-13): the
  -- month-end DC build window is DERIVED from the route own delivery days around the
  -- community payday, never a fixed day-of-month. Standard preset + real DC calendar only.
  IF p_route IN ('DC_AMBIENT','DC_TOPS') AND COALESCE(p_preset,'standard')='standard'
     AND EXISTS (SELECT 1 FROM supplier_calendar sc2 WHERE sc2.store_code=p_store_code AND sc2.route_key=p_route) THEN
    SELECT fc.value_num::int INTO v_payday_dom FROM forge_config fc
      WHERE fc.config_key='month_end_build_anchor_dom' AND fc.store_format='*' AND fc.retired_on IS NULL LIMIT 1;
    IF v_payday_dom IS NOT NULL THEN
      SELECT MAX(CASE WHEN rk=2 THEN dom END), MAX(CASE WHEN rk=1 THEN dom END)
        INTO v_build_start_dom, v_build_end_dom
      FROM (
        SELECT EXTRACT(DAY FROM d)::int AS dom, row_number() OVER (ORDER BY d DESC) AS rk
        FROM generate_series(date_trunc('month', p_delivery_date)::date,
                             (date_trunc('month', p_delivery_date) + interval '1 month - 1 day')::date,
                             interval '1 day') g(d)
        WHERE EXTRACT(ISODOW FROM d)::smallint = ANY(v_dows)
          AND EXTRACT(DAY FROM d)::int < v_payday_dom
      ) ranked;
    END IF;
  END IF;

  IF p_next_delivery IS NOT NULL THEN
    v_next_delivery := p_next_delivery;
    v_lead := GREATEST(p_next_delivery - p_delivery_date, 0);
    v_lead_source := 'calendar';
  ELSE
    v_next_delivery := p_delivery_date + 7;
    v_lead := GREATEST(p_delivery_date - v_anchor, 0);
    v_lead_source := 'fallback_anchor_gap';
  END IF;

  v_week_start := public.rpc_budget_week_start(p_delivery_date);

  SELECT obl.year_month INTO v_week_start
  FROM order_budget_ledger obl
  WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
    AND obl.year_month = v_week_start
  LIMIT 1;

  IF v_week_start IS NOT NULL THEN
    v_week_source := 'delivery_week_exact';
  ELSE
    v_week_start := public.rpc_budget_week_start(p_delivery_date);
    SELECT obl.year_month INTO v_week_start
    FROM order_budget_ledger obl
    WHERE obl.store_code = p_store_code AND obl.route_key = v_ledger_route AND obl.grain = 'weekly'
      AND obl.year_month <= v_week_start
    ORDER BY obl.year_month DESC LIMIT 1;
    v_week_source := CASE WHEN v_week_start IS NOT NULL THEN 'nearest_past_week_fallback' ELSE 'no_ledger_row' END;
  END IF;

  v_preset_essentials := COALESCE(p_preset = 'order_essentials', false);
  v_preset_catchup := COALESCE(p_preset = 'catch_up', false);
  v_preset_applied := COALESCE(p_preset, 'standard');

  v_override := p_days_cover_override;
  v_fit_to_budget := COALESCE(p_fit_to_budget, false);

  SELECT COALESCE(obl.budget_amount,0) - COALESCE(obl.committed_amount,0) INTO v_weekly_budget
  FROM order_budget_ledger obl
  WHERE obl.store_code=p_store_code AND obl.route_key=v_ledger_route AND obl.grain='weekly'
    AND obl.year_month = v_week_start;
  v_weekly_budget := COALESCE(v_weekly_budget, 0);

  v_sql := format($q$
    WITH lnk AS (
      SELECT DISTINCT ON (sl.product_code) sl.product_code,
        GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps, sl.list_cost AS pack_cost
      FROM sigma_supplier_link sl
      LEFT JOIN sigma_supplier_master sm ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr
      WHERE sl.store_code=%1$L AND COALESCE(sl.status,'')<>'S' AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sm.supplier_type='Z')
          OR (%15$L::text LIKE 'DIRECT\_%%' ESCAPE '\' AND sl.supplier_nr = ANY(%25$L::bigint[]))
        )
      ORDER BY sl.product_code, (sl.supplier_nr=1339) DESC, sl.cost_date DESC NULLS LAST
    ),
    soh AS (SELECT sd.product_code, sd.soh FROM l2_soh_daily sd WHERE sd.store_code=%1$L AND sd.snapshot_date=%2$L::date),
    soh_override AS (
      SELECT (kv.key)::bigint AS product_code, (kv.value)::numeric AS soh
      FROM jsonb_each_text(COALESCE(%26$L::jsonb, '{}'::jsonb)) kv
    ),
    cost28 AS (
      SELECT s.product_code, SUM(s.cost_value) AS cost28
      FROM sigma_sales s
      WHERE s.store_code=%1$L AND s.period_kind='T' AND s.txn_kind=1
        AND s.sale_date > %2$L::date - 28 AND s.sale_date <= %2$L::date
      GROUP BY s.product_code
    ),
    sales AS (
      SELECT s.product_code,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 14) AS q14,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 28) AS q28,
        SUM(s.qty) FILTER (WHERE s.sale_date > %2$L::date - 56) AS q56
      FROM sigma_sales s
      WHERE s.store_code = %1$L AND s.period_kind='T' AND s.txn_kind=1
        AND s.sale_date > %2$L::date - 56 AND s.sale_date <= %2$L::date
      GROUP BY s.product_code
    ),
    rs AS (SELECT product_code, range_state, state_reason FROM l2_range_state WHERE store_code=%1$L),
    pool AS MATERIALIZED (
      SELECT b.store_code, b.product_code,
        b.kvi_band, b.gmroi_quartile, b.gmroi_capped, b.band_blocked, b.band_blocked_reason,
        r.archetype,
        lnk.ps, lnk.pack_cost,
        sp.description, sp.dept_name, sp.tier, sp.department_nr, sp.merch_group_nr,
        COALESCE(sov.soh, so.soh, 0) AS soh_raw,
        COALESCE(rs.range_state, 'SLOW') AS range_state,
        COALESCE(rs.state_reason, 'no l2_range_state row -- defaulted to SLOW, no depth') AS range_state_reason,
        (COALESCE(rs.range_state,'') = 'HERO') AS is_bt_hero,
        COALESCE(sa.q14,0) AS q14, COALESCE(sa.q28,0) AS q28, COALESCE(sa.q56,0) AS q56,
        COALESCE(c28.cost28,0)/28.0 AS daily_cost_demand,
        rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected, rop.ros_56d_published,
        rop.ros_draw_14d_corrected, rop.ros_draw_28d_corrected, rop.ros_draw_56d_corrected,
        rop.ros_draw_14d_published, rop.ros_draw_28d_published, rop.ros_draw_56d_published,
        rop.ros_draw_14d_guard, rop.ros_draw_28d_guard, rop.ros_draw_56d_guard,
        rop.ros_draw_14d AS draw_raw_14d, rop.ros_draw_28d AS draw_raw_28d, rop.ros_draw_56d AS draw_raw_56d,
        rop.draw_regime_divergence_28d, rop.draw_regime_divergence_56d,
        pmp.promo_uplift AS pantry_promo_uplift, pmp.uplift_ros_basis AS pantry_uplift_basis,
        pmp.promo_uplift_source AS pantry_uplift_source,
        b.promo_uplift_used AS band_promo_uplift, b.promo_uplift_basis AS band_promo_basis,
        b.promo_in_buyin_window AS band_promo_in_window,
        rop.p_sell_estimate AS p_sell_scan, rop.p_sell_estimate_draw AS p_sell_draw,
        COALESCE(rop.unit_incommensurable, true) AS unit_incommensurable
      FROM l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN l2_rhythm_profile r ON r.store_code=b.store_code AND r.product_code=b.product_code
      LEFT JOIN l2_stock_position sp ON sp.store_code=b.store_code AND sp.product_code=b.product_code
      LEFT JOIN soh so ON so.product_code=b.product_code
      LEFT JOIN soh_override sov ON sov.product_code=b.product_code
      LEFT JOIN rs ON rs.product_code=b.product_code
      LEFT JOIN sales sa ON sa.product_code=b.product_code
      LEFT JOIN cost28 c28 ON c28.product_code=b.product_code
      LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code=b.store_code AND rop.product_code=b.product_code
      LEFT JOIN l2_bloom_promo_pantry pmp ON pmp.store_code=b.store_code AND pmp.product_code=b.product_code
      WHERE b.store_code=%1$L
        AND COALESCE(rs.range_state,'') <> 'EXCLUDED'
        -- ENG-183 (ORDERING-CANON SSA2): a product linked on more than one desk rides ONLY the desk the
        -- population verdict assigned it by receipts. No verdict row, no change (R33 clause 3).
        AND NOT EXISTS (SELECT 1 FROM l2_population_verdict pv WHERE pv.store_code=%1$L AND pv.product_code=b.product_code AND pv.route_overlap AND pv.route_key IS DISTINCT FROM %15$L::text)
        AND (
          (%15$L::text IN ('DC_AMBIENT','DC_TOPS') AND sp.department_nr = ANY(%16$L::smallint[]))
          -- ENG-033 supersedes ENG-029's merch-group + any-direct-receipt gate for
          -- DIRECT_BEER (retired with lineage, R28). Account scope removes link-only
          -- DC-supplied beer by construction -- it is not linked to the SAB account.
          OR (%15$L::text LIKE 'DIRECT\_%%' ESCAPE '\')
        )
    ),
    tiered AS (
      SELECT p.*,
        CASE p.tier WHEN 'TOP_100' THEN (CASE WHEN p.q14=0 THEN p.q28/28.0 ELSE p.q14/14.0 END)
          WHEN 'TOP_1000' THEN p.q28/28.0 ELSE p.q56/56.0 END AS scan_raw,
        (CASE
          WHEN p.tier = 'TOP_100' AND p.q14 <> 0 THEN COALESCE(
            p.ros_draw_14d_published,
            CASE WHEN p.ros_draw_28d_published IS NOT NULL AND p.draw_regime_divergence_28d IS NOT NULL
                  AND p.draw_regime_divergence_28d <= rgm.mx THEN p.ros_draw_28d_published END,
            CASE WHEN p.ros_draw_56d_published IS NOT NULL AND p.draw_regime_divergence_56d IS NOT NULL
                  AND p.draw_regime_divergence_56d <= rgm.mx THEN p.ros_draw_56d_published END,
            p.draw_raw_14d)
          WHEN p.tier IN ('TOP_100','TOP_1000') THEN COALESCE(
            p.ros_draw_28d_published,
            CASE WHEN p.ros_draw_56d_published IS NOT NULL AND p.draw_regime_divergence_56d IS NOT NULL
                  AND p.draw_regime_divergence_56d <= rgm.mx THEN p.ros_draw_56d_published END,
            p.draw_raw_28d)
          ELSE COALESCE(p.ros_draw_56d_published, p.draw_raw_56d)
        END) AS draw_corrected,
        (CASE
          WHEN p.tier = 'TOP_100' AND p.q14 <> 0 THEN
            CASE WHEN p.ros_draw_14d_published IS NOT NULL THEN 'ros_14d (own window, guard=' || COALESCE(p.ros_draw_14d_guard,'none') || ')'
                 WHEN p.ros_draw_28d_published IS NOT NULL AND p.draw_regime_divergence_28d IS NOT NULL
                       AND p.draw_regime_divergence_28d <= rgm.mx THEN 'ros_28d (widened, regime-clean)'
                 WHEN p.ros_draw_56d_published IS NOT NULL AND p.draw_regime_divergence_56d IS NOT NULL
                       AND p.draw_regime_divergence_56d <= rgm.mx THEN 'ros_56d (widened, regime-clean)'
                 ELSE 'ros_14d RAW (corrected withheld, no regime-clean window)' END
          WHEN p.tier IN ('TOP_100','TOP_1000') THEN
            CASE WHEN p.ros_draw_28d_published IS NOT NULL THEN 'ros_28d (own window, guard=' || COALESCE(p.ros_draw_28d_guard,'none') || ')'
                 WHEN p.ros_draw_56d_published IS NOT NULL AND p.draw_regime_divergence_56d IS NOT NULL
                       AND p.draw_regime_divergence_56d <= rgm.mx THEN 'ros_56d (widened, regime-clean)'
                 ELSE 'ros_28d RAW (corrected withheld, no regime-clean window)' END
          ELSE
            CASE WHEN p.ros_draw_56d_published IS NOT NULL THEN 'ros_56d (own window, guard=' || COALESCE(p.ros_draw_56d_guard,'none') || ')'
                 ELSE 'ros_56d RAW (corrected withheld)' END
        END) AS ros_window_used
      FROM pool p CROSS JOIN (SELECT COALESCE(MAX(value_num),2.0) AS mx FROM public.forge_config
                               WHERE config_key='regime_divergence_max' AND retired_on IS NULL) rgm
    ),
    guarded AS (
      SELECT t.*,
        ROUND(COALESCE(t.p_sell_draw,0) * 182) AS draw_selling_days,
        (NOT t.unit_incommensurable
          AND (t.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR COALESCE(t.p_sell_draw,0)*182 >= 8)) AS draw_eligible
      FROM tiered t
    ),
    demand_resolved AS (
      SELECT g.*,
        (CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END) AS draw_used,
        CASE WHEN %10$L = 'standard' AND NOT (
               (g.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s)
            OR (g.archetype = 'EARLY_MONTH' AND %4$s >= %7$s))
             THEN GREATEST(
                    COALESCE(g.ros_56d_published, g.q56/56.0),
                    COALESCE((CASE WHEN g.draw_eligible THEN COALESCE(g.ros_draw_56d_published, g.draw_raw_56d) ELSE NULL END),0))
             ELSE GREATEST(g.scan_raw, COALESCE((CASE WHEN g.draw_eligible THEN g.draw_corrected ELSE NULL END),0))
        END AS ros_final,
        (g.draw_eligible AND COALESCE(g.draw_corrected,0) > g.scan_raw) AS demand_from_draw
      FROM guarded g
    ),
    moded AS (
      SELECT d.*,
        CASE
          WHEN d.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'
          WHEN d.archetype = 'EARLY_MONTH' AND %4$s >= %7$s THEN 'build'
          ELSE 'minimum'
        END AS mode,
        CASE d.kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END AS safety_days
      FROM demand_resolved d
    ),
    banded AS (
      SELECT m.*,
        (m.ros_final * %9$s) + (m.safety_days * m.ros_final) AS min_band_ot,
        (CASE WHEN m.gmroi_capped THEN %9$s * 0.5 ELSE %9$s END) AS review_days_ot
      FROM moded m
    ),
    banded2 AS (
      SELECT b.*, (b.min_band_ot + (b.ros_final * b.review_days_ot)) AS max_band_ot
      FROM banded b
    ),
    promo_match AS (
      -- ENG-147 residual closed: promo membership reads THE ONE HOME (R33), never
      -- a second inline copy. The one home was lifted from THIS block verbatim, and
      -- the repoint was proven identical on 23,583 rows across all 20 desks before
      -- it was made. promo_description is still returned so the downstream
      -- promo_suffix_calc regex is untouched -- the diff stops at this CTE.
      SELECT f.product_code, f.promo_nr, f.start_date, f.end_date, f.status,
        f.promo_unit_cost, f.promo_description
      FROM banded2 pk
      JOIN public.rpc_bloom_promo_for_delivery(%1$L, %15$L, %23$L::date) f
        ON f.product_code = pk.product_code
    ),
    with_promo_flag AS (
      SELECT b.*, (pm.promo_nr IS NOT NULL) AS promo_active, pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end,
        pm.promo_unit_cost, pm.promo_description,
        COALESCE(
          substring(pm.promo_description from '\(([A-Za-z0-9]+)\)\s*$'),
          substring(pm.promo_description from 'DC Promotion Number\s+(\S+)')
        ) AS promo_suffix_calc,
        (pm.promo_nr IS NOT NULL AND pm.end_date >= %23$L::date) AS promo_geared
      FROM banded2 b LEFT JOIN promo_match pm ON pm.product_code=b.product_code
    ),
    depthed AS (
      SELECT w.*,
        (CASE
           WHEN w.range_state = 'HERO' THEN w.max_band_ot
           WHEN w.range_state = 'CORE' AND %11$L::boolean THEN w.max_band_ot
           WHEN w.range_state = 'CORE' AND %24$L::boolean THEN
             (CASE WHEN w.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR w.promo_geared
                   THEN (CASE WHEN w.mode='build' THEN w.max_band_ot ELSE w.min_band_ot END)
                   ELSE w.min_band_ot END)
           WHEN w.range_state = 'CORE' THEN
             (CASE WHEN w.mode='build' THEN w.max_band_ot ELSE w.min_band_ot END)
           ELSE GREATEST(w.soh_raw, 0)
         END) AS target_level_v10,
        (CASE
           WHEN w.range_state IN ('HERO','CORE') THEN 'range_state=' || w.range_state
                || CASE WHEN w.range_state='CORE' AND %24$L::boolean AND NOT (w.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT') OR w.promo_geared) THEN ' (essentials: min-band presence only)'
                        WHEN w.range_state='CORE' AND %11$L::boolean THEN ' (catch-up: order-up-to, subject to the aggregate-days walk)'
                        ELSE format(' (%%s mode)', w.mode) END
           ELSE 'range_state=' || w.range_state || ': ' || w.range_state_reason
         END) AS target_reason
      FROM with_promo_flag w
    ),
    targeted AS (
      SELECT d.*,
        CASE WHEN %8$L IS NOT NULL THEN LEAST(d.ros_final * %8$L::numeric, d.max_band_ot)
             ELSE d.target_level_v10 END AS target_level,
        CASE WHEN %8$L IS NOT NULL THEN format('flat %%s-day cover override (diagnostic)', %8$L::text)
             ELSE d.target_reason END AS mode_reason
      FROM depthed d
    ),
    needc AS (
      SELECT t.*,
        t.band_blocked AS count_first,
        (CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END) AS soh_used,
        GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s + COALESCE(oo.on_order_qty,0) AS proj,
        (CASE WHEN t.range_state NOT IN ('HERO','CORE') THEN 0
         ELSE GREATEST(t.target_level - (GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s + COALESCE(oo.on_order_qty,0)), 0)
         END) AS needu
      FROM targeted t
      LEFT JOIN l2_on_order oo
        ON oo.store_code = %1$L AND oo.product_code = t.product_code
       AND oo.on_order_qty > 0
       AND oo.expected_landing_date IS NOT NULL
       AND oo.expected_landing_date <= %23$L::date
    ),
    packs AS (
      SELECT n.*,
        (CASE WHEN n.ros_final<=0 THEN 0
              WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1)
              ELSE 0 END)::int AS normal_packs_raw
      FROM needc n
    ),
    packs_mp AS (
      SELECT p.*,
        (%8$L IS NULL AND p.range_state IN ('HERO','CORE') AND p.proj < p.min_band_ot AND p.ros_final > 0) AS mp_life,
        (%8$L IS NULL AND p.range_state = 'SLOW' AND p.proj < p.min_band_ot AND p.ros_final > 0
           AND NOT %24$L::boolean AND NOT %11$L::boolean) AS slow_candidate,
        (CASE WHEN p.ros_final > 0
              THEN GREATEST(FLOOR((%28$s * p.ros_final - GREATEST(p.soh_used,0)) / p.ps), 0)
              ELSE 0 END)::int AS packs_under_ceiling,
        (p.ros_final > 0 AND (GREATEST(p.soh_used,0) + p.ps) / p.ros_final > %28$s) AS first_pack_over_ceiling,
        (p.ros_final > 0 AND (p.ps / p.ros_final) <= %29$s) AS pack_relevant
      FROM packs p
    ),
    packs_ceiled AS (
      SELECT m.*,
        (m.range_state IN ('HERO','CORE') AND NOT m.mp_life AND m.normal_packs_raw >= 1 AND m.ros_final > 0
          AND (GREATEST(m.soh_used,0) + m.normal_packs_raw * m.ps) / m.ros_final > %28$s) AS pack_forced_review,
        ((m.mp_life OR (m.slow_candidate AND m.pack_relevant)) AND m.first_pack_over_ceiling) AS min_presence_forced,
        (m.slow_candidate AND NOT m.pack_relevant) AS keep_or_delist,
        (CASE
           WHEN m.slow_candidate AND m.pack_relevant THEN 1
           WHEN m.slow_candidate THEN 0
           WHEN m.range_state NOT IN ('HERO','CORE') THEN 0
           WHEN m.normal_packs_raw < 1 THEN 0
           WHEN m.mp_life THEN LEAST(m.normal_packs_raw, GREATEST(1, m.packs_under_ceiling))
           WHEN m.ros_final > 0 AND (GREATEST(m.soh_used,0) + m.normal_packs_raw * m.ps) / m.ros_final > %28$s THEN LEAST(m.normal_packs_raw, m.packs_under_ceiling)
           ELSE m.normal_packs_raw
         END)::int AS normal_packs_calc
      FROM packs_mp m
    ),
    gear_source AS (
      SELECT DISTINCT ON (pk.product_code) pk.product_code, pa.start_date, pa.end_date
      FROM packs_ceiled pk JOIN public.sigma_promotion_articles pa ON pa.store_code=%1$L AND pa.product_code=pk.product_code
        AND pa.status='2' AND pa.end_date < %2$L::date AND pa.start_date >= DATE '2025-06-01'
      ORDER BY pk.product_code, pa.end_date DESC
    ),
    gear_calc AS (
      SELECT gs.product_code,
        COALESCE(SUM(ss.qty) FILTER (WHERE ss.sale_date BETWEEN gs.start_date AND gs.end_date),0)/GREATEST(gs.end_date-gs.start_date+1,1) AS promo_ros,
        COALESCE(SUM(ss.qty) FILTER (WHERE ss.sale_date BETWEEN gs.start_date-28 AND gs.start_date-1),0)/28.0 AS base_ros
      FROM gear_source gs LEFT JOIN public.sigma_sales ss ON ss.store_code=%1$L AND ss.product_code=gs.product_code
        AND ss.period_kind='T' AND ss.txn_kind=1 AND ss.sale_date BETWEEN (gs.start_date-28) AND gs.end_date
      GROUP BY gs.product_code, gs.start_date, gs.end_date
    ),
    with_gear AS (
      SELECT pk.*, GREATEST(COALESCE(pk.pantry_promo_uplift, 1.0), 1.0) AS gear,
        (COALESCE(pk.pantry_uplift_source,'') = 'own_promo') AS gear_from_own_promo
      FROM packs_ceiled pk
    ),
    geared_calc AS (
      SELECT wg.*,
        GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s AS proj_geared,
        (CASE WHEN wg.range_state NOT IN ('HERO','CORE') THEN 0
         ELSE GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s), 0)
         END) AS needu_geared
      FROM with_gear wg
    ),
    geared AS (
      SELECT g.*,
        (CASE WHEN g.ros_final<=0 THEN 0
              WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1)
              ELSE 0 END)::int AS geared_packs_raw
      FROM geared_calc g
    ),
    geared_ceiled AS (
      SELECT g.*,
        (CASE
           WHEN g.geared_packs_raw < 1 THEN g.geared_packs_raw
           WHEN g.mp_life THEN LEAST(g.geared_packs_raw, GREATEST(1, g.packs_under_ceiling))
           WHEN g.ros_final > 0
             AND (GREATEST(g.soh_used,0) + g.geared_packs_raw * g.ps) / g.ros_final > %28$s
           THEN LEAST(g.geared_packs_raw, g.packs_under_ceiling)
           ELSE g.geared_packs_raw
         END)::int AS geared_packs_calc
      FROM geared g
    ),
    resolved AS (
      SELECT g.*,
        CASE
          WHEN %24$L::boolean THEN g.normal_packs_calc
          WHEN g.range_state = 'SLOW' THEN g.normal_packs_calc
          WHEN g.promo_geared THEN g.geared_packs_calc
          ELSE g.normal_packs_calc
        END AS resolved_packs_calc
      FROM geared_ceiled g
    ),
    gmroi AS (
      SELECT g.product_code, g.gmroi_rank FROM l2_gmroi_profile g WHERE g.store_code=%1$L
    ),
    ranked AS (
      SELECT r.*, gm.gmroi_rank,
        (r.range_state = 'HERO' OR r.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')) AS is_protected,
        (CASE r.kvi_band WHEN 'KVI_CRITICAL' THEN 1 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 3 END) AS kvi_priority
      FROM resolved r LEFT JOIN gmroi gm ON gm.product_code=r.product_code
    ),
    catchup_ranked AS (
      SELECT r.*,
        (r.range_state = 'HERO') AS cu_always_in,
        (r.range_state IN ('HERO','CORE') AND r.ros_final > 0) AS cu_eligible,
        ROW_NUMBER() OVER (
          ORDER BY (CASE WHEN r.range_state='HERO' THEN 0 ELSE 1 END), r.kvi_priority, r.gmroi_rank NULLS LAST, r.product_code
        ) AS cu_rank
      FROM ranked r
    ),
    catchup_totals AS (
      SELECT
        SUM(GREATEST(soh_used,0) * (pack_cost / NULLIF(ps,0))) FILTER (WHERE cu_eligible) AS baseline_stock_cost_raw,
        SUM(resolved_packs_calc * pack_cost) FILTER (WHERE cu_always_in) AS hero_added_value,
        SUM(daily_cost_demand) FILTER (WHERE cu_eligible) AS total_daily_cost_demand
      FROM catchup_ranked
    ),
    catchup_walk AS (
      SELECT c.*,
        (c.resolved_packs_calc * c.pack_cost) AS cu_added_value,
        COALESCE(SUM(CASE WHEN c.cu_eligible AND NOT c.cu_always_in THEN c.resolved_packs_calc * c.pack_cost ELSE 0 END)
          OVER (ORDER BY c.cu_rank ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cu_value_before,
        (COALESCE(ct.baseline_stock_cost_raw,0) + COALESCE(ct.hero_added_value,0)) AS baseline_stock_cost,
        COALESCE(ct.hero_added_value,0) AS hero_added_value,
        ct.total_daily_cost_demand
      FROM catchup_ranked c CROSS JOIN catchup_totals ct
    ),
    catchup_decided AS (
      SELECT w.*,
        (CASE WHEN COALESCE(w.total_daily_cost_demand,0) > 0
              THEN (COALESCE(w.baseline_stock_cost,0) + w.cu_value_before) / w.total_daily_cost_demand
              ELSE NULL END) AS cu_days_before,
        (w.cu_always_in
          OR (w.cu_eligible
              AND (COALESCE(w.total_daily_cost_demand,0) = 0
                   OR (COALESCE(w.baseline_stock_cost,0) + w.cu_value_before) / w.total_daily_cost_demand < %27$s)
              AND w.cu_value_before < GREATEST(%14$s - w.hero_added_value, 0))
        ) AS cu_include
      FROM catchup_walk w
    ),
    fit_ranked AS (
      SELECT b.*,
        (CASE
           WHEN b.is_protected THEN b.resolved_packs_calc
           WHEN b.resolved_packs_calc >= 1 AND (b.mp_life OR (b.slow_candidate AND b.pack_relevant)) THEN 1
           ELSE 0
         END)::int AS fit_floor_packs
      FROM catchup_decided b
    ),
    fit_walk AS (
      SELECT f.*,
        GREATEST(f.resolved_packs_calc - f.fit_floor_packs, 0) AS fit_depth_packs,
        GREATEST(f.resolved_packs_calc - f.fit_floor_packs, 0) * f.pack_cost AS fit_depth_value,
        SUM(f.fit_floor_packs * f.pack_cost) OVER () AS fit_floor_spend,
        COALESCE(SUM(GREATEST(f.resolved_packs_calc - f.fit_floor_packs, 0) * f.pack_cost)
          OVER (ORDER BY f.cu_rank ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS fit_depth_before
      FROM fit_ranked f
    ),
    fit_decided AS (
      SELECT w.*,
        (w.fit_depth_packs > 0
         AND w.fit_depth_before + w.fit_depth_value <= GREATEST(%14$L::numeric - w.fit_floor_spend, 0)) AS fit_depth_funded
      FROM fit_walk w
    ),
    finalp AS (
      SELECT b.*,
        (%13$L::boolean OR %11$L::boolean) AS fit_applied,
        CASE
          WHEN %11$L::boolean THEN
            (CASE WHEN b.cu_include THEN b.resolved_packs_calc ELSE 0 END)
          WHEN NOT %13$L::boolean THEN b.resolved_packs_calc
          WHEN b.fit_depth_funded THEN b.resolved_packs_calc
          ELSE b.fit_floor_packs
        END::int AS final_packs,
        CASE
          WHEN %11$L::boolean THEN (CASE WHEN b.cu_include THEN 'catchup_priority_fill' ELSE 'catchup_below_cutoff' END)
          WHEN NOT %13$L::boolean THEN NULL
          WHEN b.is_protected THEN 'protected_kvi_hero'
          WHEN b.fit_depth_packs <= 0 THEN (CASE WHEN b.fit_floor_packs > 0 THEN 'min_presence_floor' ELSE 'fits' END)
          WHEN b.fit_depth_funded THEN 'ranked_fill'
          WHEN b.fit_floor_packs > 0 THEN 'below_cutoff_held_at_floor'
          ELSE 'below_cutoff_not_funded'
        END AS fit_reason
      FROM fit_decided b
    )
    SELECT
      %1$L::text AS store_code, pk.product_code AS product_code,
      COALESCE(eb.ean, lpad(%1$L,5,'0')||lpad(pk.product_code::text,8,'0')) AS ean,
      pk.description AS description, pk.dept_name AS dept_name, %15$L::text AS route,
      pk.kvi_band AS kvi_band, pk.archetype AS archetype, pk.tier AS tier, pk.mode AS mode, pk.mode_reason AS mode_reason,
      pk.range_state AS range_state, pk.range_state_reason AS range_state_reason,
      (CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'stable_56d' WHEN pk.demand_from_draw THEN 'family_draw' ELSE 'scan' END) AS demand_source, (CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'ros_56d STABLE (v16 std-min)' ELSE pk.ros_window_used END) AS ros_window_used,
      ROUND(pk.ros_final,4) AS rhythm_adjusted_demand,
      ROUND(pk.min_band_ot,2) AS min_band, ROUND(pk.max_band_ot,2) AS max_band, ROUND(pk.target_level,2) AS target_level,
      pk.soh_raw AS soh, %9$s::int AS lead_days_used, %17$L::text AS lead_days_source, ROUND(pk.proj,2) AS projected_soh,
      pk.count_first AS count_first, pk.band_blocked_reason AS band_blocked_reason,
      pk.pack_forced_review AS pack_forced_review,
      ((pk.min_presence_forced OR pk.pack_forced_review) AND pk.range_state='HERO') AS hero_pack_over_max,
      pk.min_presence_forced AS min_presence_forced, pk.keep_or_delist AS keep_or_delist,
      ROUND(pk.needu,2) AS need_units, pk.ps AS pack_size, ROUND(pk.pack_cost,2) AS pack_cost,
      pk.normal_packs_calc AS normal_packs, pk.promo_active AS promo_active, pk.promo_nr AS promo_nr, pk.promo_start AS promo_start, pk.promo_end AS promo_end,
      (CASE WHEN pk.promo_active AND NOT pk.promo_geared THEN 1.0 ELSE ROUND(pk.gear,4) END) AS promo_uplift, (CASE WHEN pk.gear_from_own_promo THEN 'own_promo' ELSE 'default' END) AS promo_uplift_source,
      pk.promo_suffix_calc AS promo_suffix, (pk.promo_active AND pk.promo_suffix_calc IS NULL) AS promo_naming_gap,
      (CASE WHEN pk.promo_active AND NOT pk.promo_geared THEN pk.normal_packs_calc ELSE pk.geared_packs_calc END)::int AS geared_packs,
      pk.resolved_packs_calc AS packs_before_fit, pk.final_packs AS suggested_packs, ROUND((pk.final_packs*pk.pack_cost)::numeric,2) AS value,
      pk.gmroi_quartile AS gmroi_quartile, pk.gmroi_capped AS gmroi_capped, pk.gmroi_rank AS gmroi_rank,
      pk.fit_applied AS budget_fit_applied, pk.fit_reason AS budget_fit_reason,
      %19$L::date AS budget_week_start, %20$L::text AS budget_week_source,
      pk.is_bt_hero AS is_bt_hero, %10$L::text AS preset_applied, false AS frozen_focus_pending,
      format('%%s [%%s] tier KVI=%%s, archetype=%%s -> %%s, window=%%s demand=%%s, band [%%s|%%s], SOH %%s, lead %%s(%%s) -> proj %%s, need %%s = %%s packs%%s%%s%%s%%s%%s%%s',
        COALESCE(pk.tier,'-'), pk.range_state, COALESCE(pk.kvi_band,'-'), COALESCE(pk.archetype,'EVERYDAY(default)'), pk.mode_reason,
        CASE WHEN %10$L = 'standard' AND pk.mode = 'minimum' THEN 'ros_56d STABLE (v16 std-min)' ELSE pk.ros_window_used END, ROUND(pk.ros_final,2),
        ROUND(pk.min_band_ot,1), ROUND(pk.max_band_ot,1), pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1), ROUND(pk.needu,1), pk.resolved_packs_calc,
        CASE WHEN pk.pack_forced_review THEN format(' | PACK_FORCED_REVIEW: one pack alone (%%s units) exceeds max_band (%%s) -- not ordered, %%s',
               pk.ps, ROUND(pk.max_band_ot,1), CASE WHEN pk.range_state='HERO' THEN 'HERO: needs a human call (smaller pack/loose unit)' ELSE 'route to derange/review' END) ELSE '' END,
        CASE WHEN pk.count_first THEN format(' | COUNT_FIRST: %%s', CASE WHEN pk.soh_raw < 0 THEN 'negative claim, SOH treated as 0' ELSE 'positive claim, ordered on it, count still rides' END) ELSE '' END,
        CASE WHEN pk.promo_nr IS NOT NULL AND NOT pk.promo_geared THEN format(' | promo %%s->%%s ended before this delivery and is ordered in its closing week at promo: normal quantity, no gear', pk.promo_start, pk.promo_end) WHEN pk.promo_nr IS NOT NULL THEN format(' | promo %%s->%%s gear %%s', pk.promo_start, pk.promo_end, ROUND(pk.gear,2)) ELSE '' END,
        CASE WHEN pk.fit_applied THEN format(' | budget fit: %%s (%%s -> %%s packs)', pk.fit_reason, pk.resolved_packs_calc, pk.final_packs) ELSE '' END,
        CASE WHEN pk.min_presence_forced THEN format(' | MIN_PRESENCE: %%s projected below min_band (%%s), first pack exempt from max band', pk.range_state, ROUND(pk.min_band_ot,1)) ELSE '' END,
        CASE WHEN pk.keep_or_delist THEN format(' | KEEP_OR_DELIST: likely to derange, one pack = %%s days cover (over %%s), range decision', ROUND(pk.ps/NULLIF(pk.ros_final,0),0), %29$s) ELSE '' END) AS story
    FROM finalp pk
    LEFT JOIN v_ean_bridge eb ON eb.store_code=%1$L AND eb.product_code=pk.product_code
  $q$, p_store_code, v_soh_dt, NULL::boolean, v_dom,
       COALESCE(v_build_start_dom, p_month_end_build_start_day), COALESCE(v_build_end_dom, p_month_end_build_end_day), p_early_month_build_start_day,
       v_override, v_lead, v_preset_applied,
       v_preset_catchup, p_catchup_band_cap_multiple, v_fit_to_budget, v_weekly_budget,
       p_route, v_dept_nrs, v_lead_source, v_next_delivery, v_week_start, v_week_source,
       v_dows, v_buyin_lead_days, p_delivery_date, v_preset_essentials, v_direct_supplier_nrs, p_soh_override,
       p_store_target_days, p_max_order_stock_days, v_relevant_min_cover_days);

  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
  EXECUTE format('CREATE TEMP TABLE _bloom_recipe_out AS %s', v_sql);

  -- ENG-088 (2026-08-16), second pass: measured at source, the first attempt (filtering
  -- only the final RETURN) did not fix it -- EXPLAIN ANALYZE showed 52.7s regardless,
  -- because the three surfacing passes below (promo/in-transit/pack_content) each ran a
  -- full UPDATE over the whole ~12,700-line pool BEFORE any filter applied. Deleting the
  -- non-actionable rows HERE, before those three passes, means they touch only the
  -- surviving actionable rows. Same keep condition as the final filter (kept there too,
  -- redundant but cheap on an already-small table) -- moving WHEN it applies, not WHAT
  -- survives, so the returned rows are unchanged.
  EXECUTE 'DELETE FROM _bloom_recipe_out
    WHERE NOT (suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced OR (range_state IN (''CORE'',''HERO'') AND soh <= min_band))';

  /* ===== SB-CC-BLOOM-018 SURFACING. Appended AFTER the recipe has computed, so these
     columns are structurally incapable of moving a suggested quantity (item 2's own rule:
     surface the gap, do not change the number). Item 2 = the promo floor gap, canon 14
     v14 rule 4 / ENG-052. Item 1 = the buyer sees the truck, canon 14 v15 rule 6a.
     R29 throughout: the reason travels with the number. ===== */
  EXECUTE 'ALTER TABLE _bloom_recipe_out
      ADD COLUMN promo_in_window boolean, ADD COLUMN promo_band_demand numeric,
      ADD COLUMN promo_uplift_band numeric, ADD COLUMN promo_uplift_band_source text,
      ADD COLUMN promo_uplift_band_basis text, ADD COLUMN promo_floor_units numeric,
      ADD COLUMN promo_shortfall_units numeric, ADD COLUMN promo_shortfall_packs integer,
      ADD COLUMN promo_shortfall_rand numeric, ADD COLUMN promo_gap_reason text,
      ADD COLUMN in_transit_qty numeric, ADD COLUMN in_transit_cost numeric,
      ADD COLUMN in_transit_landing date, ADD COLUMN in_transit_counted boolean,
      ADD COLUMN in_transit_routes text, ADD COLUMN in_transit_lead_basis text,
      ADD COLUMN in_transit_landing_state text, ADD COLUMN in_transit_stale_qty numeric,
      ADD COLUMN in_transit_stale_age_days integer, ADD COLUMN in_transit_reason text';

  EXECUTE format($w18p$
    UPDATE _bloom_recipe_out o SET
      promo_in_window          = COALESCE(b.promo_in_buyin_window,false),
      promo_band_demand        = b.rhythm_adjusted_demand,
      promo_uplift_band        = b.promo_uplift_used,
      promo_uplift_band_source = b.promo_uplift_source,
      promo_uplift_band_basis  = b.promo_uplift_basis,
      promo_floor_units        = b.min_band,
      promo_shortfall_units    = GREATEST(b.min_band - (COALESCE(o.soh,0) + o.suggested_packs*o.pack_size), 0),
      promo_shortfall_packs    = CEIL(GREATEST(b.min_band - (COALESCE(o.soh,0) + o.suggested_packs*o.pack_size),0) / NULLIF(o.pack_size,0))::int,
      promo_shortfall_rand     = ROUND(CEIL(GREATEST(b.min_band - (COALESCE(o.soh,0) + o.suggested_packs*o.pack_size),0) / NULLIF(o.pack_size,0))::numeric * COALESCE(o.pack_cost,0), 2),
      promo_gap_reason = CASE
        WHEN NOT COALESCE(b.promo_in_buyin_window,false) THEN NULL
        WHEN (COALESCE(o.soh,0) + o.suggested_packs*o.pack_size) >= b.min_band
          THEN 'promo floor met: position ' || ROUND(COALESCE(o.soh,0) + o.suggested_packs*o.pack_size,0) || ' units vs floor ' || ROUND(b.min_band,0) || ' units'
        ELSE 'PROMO FLOOR GAP: band demand ' || ROUND(b.rhythm_adjusted_demand,2)
             || '/day at uplift ' || ROUND(COALESCE(b.promo_uplift_used,0),2)
             || ' (' || COALESCE(b.promo_uplift_source,'unknown') || ', basis ' || COALESCE(b.promo_uplift_basis,'unknown') || ')'
             || ' vs order demand ' || ROUND(o.rhythm_adjusted_demand,2)
             || '/day; floor ' || ROUND(b.min_band,0)
             || ' units, position ' || ROUND(COALESCE(o.soh,0) + o.suggested_packs*o.pack_size,0)
             || ', short ' || ROUND(GREATEST(b.min_band - (COALESCE(o.soh,0) + o.suggested_packs*o.pack_size),0),0) || ' units'
        END
    FROM l2_stock_band b
    WHERE b.store_code = %L AND b.product_code = o.product_code
  $w18p$, p_store_code);

  EXECUTE format($w18t$
    UPDATE _bloom_recipe_out o SET
      in_transit_qty            = NULLIF(t.on_order_qty,0),
      in_transit_cost           = NULLIF(t.on_order_cost,0),
      in_transit_landing        = t.expected_landing_date,
      in_transit_counted        = (COALESCE(t.on_order_qty,0) > 0 AND t.expected_landing_date IS NOT NULL AND t.expected_landing_date <= %L::date),
      in_transit_routes         = array_to_string(t.route_keys, ','),
      in_transit_lead_basis     = t.lead_basis,
      in_transit_landing_state  = t.landing_estimate_state,
      in_transit_stale_qty      = NULLIF(t.stale_qty,0),
      in_transit_stale_age_days = t.stale_oldest_age_days,
      in_transit_reason = CASE
        WHEN COALESCE(t.on_order_qty,0) <= 0 AND COALESCE(t.stale_qty,0) <= 0 THEN NULL
        WHEN COALESCE(t.on_order_qty,0) > 0 AND t.expected_landing_date IS NOT NULL AND t.expected_landing_date <= %L::date
          THEN 'IN TRANSIT, COUNTED: ' || ROUND(t.on_order_qty,0) || ' units land ' || t.expected_landing_date
               || ' on ' || COALESCE(array_to_string(t.route_keys,','),'route unknown')
               || ' (lead basis ' || COALESCE(t.lead_basis,'unknown') || '). This order was REDUCED by that quantity.'
        WHEN COALESCE(t.on_order_qty,0) > 0
          THEN 'IN TRANSIT, NOT COUNTED: ' || ROUND(t.on_order_qty,0) || ' units, landing '
               || COALESCE(t.expected_landing_date::text,'unknown') || ' falls after this delivery. Order NOT reduced.'
        ELSE 'STALE ORDER ONLY: ' || ROUND(COALESCE(t.stale_qty,0),0) || ' units on documents up to '
               || COALESCE(t.stale_oldest_age_days::text,'?') || ' days old. Worklisted, NOT counted as in transit.'
        END
    FROM l2_on_order t
    WHERE t.store_code = %L AND t.product_code = o.product_code
  $w18t$, p_delivery_date, p_delivery_date, p_store_code);

  /* SB-CC-BLOOM-018 v1.2 item 4: PACK CONTENT ON THE ROW.
     Pieter called a duplicate-order risk at 80175: five pairs of DIFFERENT
     products render as the same product under two codes, because the
     description alone does not separate them and pack_size does not either
     (GOLDI IQF MP 2KG pack 6 vs 5KG pack 3; SPAR EGGS LARGE 60'S vs 48'S;
     SPAR SUNFLOWER OIL 2LT vs 4LT; MAQ FLEXI 1KG vs 2KG; STORK 500GR vs 1KG).
     Measured: zero shared EANs -- the POOL is clean, the SCREEN is not.
     Same append-after-compute pattern: read-only, changes no quantity. */
  EXECUTE 'ALTER TABLE _bloom_recipe_out ADD COLUMN pack_content text';
  EXECUTE format($w18c$
    UPDATE _bloom_recipe_out o SET pack_content = NULLIF(TRIM(a.pack_content::text), '''')
    FROM sigma_articles a
    WHERE a.store_code = %L AND a.product_code = o.product_code
  $w18c$, p_store_code);

  EXECUTE format(
    'SELECT count(*) FROM _bloom_recipe_out WHERE suggested_packs > 0 AND rhythm_adjusted_demand > 0
       AND NOT min_presence_forced
       AND (soh + suggested_packs*pack_size) / rhythm_adjusted_demand > %s + 1',
    p_max_order_stock_days)
    INTO v_band_violations;
  IF v_band_violations > 0 THEN
    RAISE WARNING 'canon v12 item 1: % row(s) exceed the %-day order-stock ceiling WITHOUT the minimum-presence exemption (store=%, route=%, delivery=%, preset=%)',
      v_band_violations, p_max_order_stock_days, p_store_code, p_route, p_delivery_date, v_preset_applied;
  END IF;

  RETURN QUERY EXECUTE 'SELECT * FROM _bloom_recipe_out
    WHERE suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced OR (range_state IN (''CORE'',''HERO'') AND soh <= min_band)
    ORDER BY rhythm_adjusted_demand DESC, product_code';
  EXECUTE 'DROP TABLE IF EXISTS _bloom_recipe_out';
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_recipe(text,date,date,date,text,numeric,boolean,integer,integer,integer,numeric,text,jsonb,integer,numeric) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
