-- =====================================================================
-- rpc_bloom_hidden_demand -- SB-CC-BLOOM-026 PART (b), THE SURFACING SAFETY NET
--
-- Ref:      Bloom/SB-CC-BLOOM-026_Order-Population-Completeness.md, part 5(b)
-- Date:     2026-08-19
-- Owner:    Claude Code
-- Canon:    R21 SS5 (every exclusion earned and surfaced) - R22 - R25/SS0h
--           (config only, no store or desk list) - R28 SS5 (the evidence class
--           travels on the row) - R29 (the reason travels with the number) -
--           R32 (the applet reads, it never computes) - ORDERING-CANON SSA2,
--           SSB2, SSB4, SSB5, SSF1
-- Class:    read-only, quantity-neutral, additive, reversible
--
-- THE DEFECT (brief SS1 / SS2a)
-- A line only reaches the buyer if the engine computes a positive need. Need is
-- computed off a rate the observable-day floor can WITHHOLD, in which case the
-- recipe falls back to the stockout-SUPPRESSED raw rate. The line then reads as
-- well-stocked, need computes at or below zero, and it is dropped from the list
-- with no reason shown. Worked case EXCELLA S/FLOWER OIL 2LT (3765 @ 80175):
-- on its own TOP_1000 28-day window the corrector measured 6.455/day, the floor
-- withheld it, the recipe read raw 2.536/day, and the line vanished.
--
-- WHY IT KEYS ON THE WITHHELD FLAG AND NEVER ON BAND POSITION (brief SS6)
-- ORDERING-CANON SSB5 claimed a withheld correction is safe because v12 minimum
-- presence orders the pack anyway on any life-gate-pass HERO/CORE below band.
-- That is FALSE. min_band = demand x (safety_days + lead_days) reads the SAME
-- suppressed rate the correction was withheld from, so both halves of the
-- "paired" guard fail on one corrupted input rather than covering each other.
-- A net keyed on band position inherits the corruption. This one keys on the
-- guard flag itself. Proven 2026-08-19, canon corrected in the brief.
--
-- THE BUYABILITY GATE (brief SS5b)
-- The net must never show a line the buyer cannot buy on THIS desk, or it
-- destroys its own credibility the first time it is opened. The population is
-- therefore the RECIPE'S OWN POOL GATE, reproduced from the live function body
-- (read at source 2026-08-19, never from prose): a link that is not status 'S'
-- and is inside its valid_to window, supplier_type 'Z' for a DC route or a
-- named direct account, department in dc_cycle_dept_nrs for DC, range_state not
-- EXCLUDED. A suspended link, an expired link, a dropship line or another
-- desk's line CANNOT appear here -- those are brief parts (d) and (e).
--
-- THE WINDOW IS THE LINE'S OWN (ORDERING-CANON SSB2)
-- TOP_100 -> 14d, TOP_1000 -> 28d, else 56d. Never a cross-window maximum, and
-- never a single window applied to every tier. NOTE when comparing counts: a
-- figure quoted on 56d for every line will not equal a figure quoted on the
-- tier window, and both are legitimate. State which.
--
-- R28 SS5 ON THE SURFACE
-- Every row carries days_removed / observable_days / observable_share, so a
-- rate resting on six observable days SHOWS that it does and the buyer judges
-- the uncertainty in front of him. The corrected rate is an ESTIMATE, not
-- ground truth -- that is exactly why part (a) of the brief is held behind a
-- derived threshold rather than wired.
--
-- ⚠️ TRACKED DUPLICATION DEBT (R25 SS2 -- a derivative is a tracked debt, never
-- an architecture). This reproduces the recipe's pool gate rather than sharing
-- it, because rpc_bloom_order_recipe is under a PM hold and may not be touched.
-- The gate now exists in TWO places and CAN drift. When the recipe is next
-- opened, extract the gate into one object and repoint both (SS0g write-forward,
-- one fact one home). Recorded so the debt is visible, not discovered later.
--
-- ⚠️ ALSO CARRIED FORWARD FROM THE RECIPE, AND IT IS A DEFECT IN ITS OWN RIGHT:
-- the link tiebreak `ORDER BY ... (sl.supplier_nr = 1339) DESC` hardcodes a
-- STORE-LOCAL supplier number in engine code. supplier_nr is store-local and
-- collides across stores (canon SSA1), so store #6 inherits a preference that
-- means nothing at its DC. Reproduced here ONLY so this object's population is
-- identical to the recipe's; it must be fixed in both, not in one. Logged for
-- the brief's part (e).
--
-- ⚠️ SECURITY DEFINER IS LOAD-BEARING, NOT BOILERPLATE.
-- l2_soh_daily has RLS ENABLED WITH ZERO POLICIES, so an invoker-rights read as
-- `anon` returns ZERO rows and this card would report a confident, permanent
-- "nothing hidden" -- the ENG-068 / ENG-074 failure shape, already named twice
-- in DB-SCHEMA. Proven BEHAVIOURALLY after create (postgres count == anon count,
-- both non-zero), never by reading the grant.
--
-- ⚠️ DELIBERATELY NOT STABLE. It issues SET LOCAL statement_timeout, and
-- Postgres rejects SET inside a non-volatile function. Same note as
-- rpc_dept_summary and rpc_kpi_stock_by_date -- third instance of one trap.
--
-- MEASURED AT BUILD (2026-08-19), DC desks, hidden / >=2 per day / at SOH 0:
--   10116 609 / 25 / 75 - 80175 415 / 12 / 45 - 80579 48 / 9 / 23
--   21355  47 / 10 /  7 - 80176  24 /  1 /  2      group 1,143 / 57 / 152
-- 161 of the 1,143 rest on six observable days or fewer. The actionable head is
-- small; the tail is long. The card ranks by corrected rate and lets the buyer
-- scroll (brief SS3 point 2), it does not dump 1,143 rows at him.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_hidden_demand(
  p_store_code text,
  p_route      text,
  p_soh_date   date DEFAULT NULL
)
RETURNS TABLE (
  product_code        bigint,
  description         text,
  dept_name           text,
  tier                text,
  kvi_band            text,
  range_state         text,
  soh                 numeric,
  pack_size           smallint,
  pack_cost           numeric,
  window_days         smallint,
  rate_raw            numeric,
  rate_corrected      numeric,
  rate_multiple       numeric,
  guard               text,
  days_removed        smallint,
  observable_days     smallint,
  observable_share    numeric,
  cover_days_on_raw   numeric,
  cover_days_on_corr  numeric,
  reason              text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_dept_nrs  smallint[];
  v_direct    bigint[];
  v_is_dc     boolean;
  v_soh_dt    date;
  v_floor     numeric;
BEGIN
  SET LOCAL statement_timeout = '25s';

  IF p_route IS NULL OR p_store_code IS NULL THEN
    RAISE EXCEPTION 'p_store_code and p_route are both required (a call without a route scope is a defect, ORDERING-CANON A1)';
  END IF;

  SELECT d.is_dc INTO v_is_dc FROM public.rpc_bloom_desks(p_store_code) d
   WHERE d.route_key = p_route;
  IF v_is_dc IS NULL THEN
    RAISE EXCEPTION 'no desk % at store % (no supplier_calendar row) -- see rpc_bloom_desks', p_route, p_store_code;
  END IF;

  IF v_is_dc THEN
    SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs
      FROM public.bloom_dc_config dc
     WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
    IF v_dept_nrs IS NULL THEN
      RAISE EXCEPTION 'no RULED bloom_dc_config row for store %', p_store_code;
    END IF;
  ELSE
    SELECT rc.direct_supplier_nrs INTO v_direct
      FROM public.bloom_route_config rc
     WHERE rc.store_code = p_store_code AND rc.route_key = p_route;
  END IF;

  SELECT COALESCE(p_soh_date, MAX(sd.snapshot_date)) INTO v_soh_dt
    FROM public.l2_soh_daily sd WHERE sd.store_code = p_store_code;

  SELECT fc.value_num INTO v_floor
    FROM public.forge_config fc
   WHERE fc.config_key = 'corrector_min_observable_share'
     AND fc.store_format = '*' AND fc.retired_on IS NULL LIMIT 1;
  v_floor := COALESCE(v_floor, 0.5);

  RETURN QUERY
  WITH lnk AS (
    SELECT DISTINCT ON (sl.product_code)
           sl.product_code,
           GREATEST(COALESCE(sl.pack_size,1),1)::smallint AS ps,
           sl.list_cost AS pack_cost
      FROM public.sigma_supplier_link sl
      LEFT JOIN public.sigma_supplier_master sm
        ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
     WHERE sl.store_code = p_store_code
       AND COALESCE(sl.status,'') <> 'S'
       AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
       AND ( (v_is_dc AND sm.supplier_type = 'Z')
             OR ((NOT v_is_dc) AND sl.supplier_nr = ANY(v_direct)) )
     ORDER BY sl.product_code, (sl.supplier_nr = 1339) DESC, sl.cost_date DESC NULLS LAST
  ),
  soh AS (
    SELECT sd.product_code, sd.soh
      FROM public.l2_soh_daily sd
     WHERE sd.store_code = p_store_code AND sd.snapshot_date = v_soh_dt
  ),
  rs AS (
    SELECT r.product_code, r.range_state
      FROM public.l2_range_state r WHERE r.store_code = p_store_code
  ),
  pool AS MATERIALIZED (
    SELECT b.product_code, b.kvi_band,
           sp.description, sp.dept_name, sp.tier,
           COALESCE(so.soh, 0) AS soh_raw,
           COALESCE(rs.range_state, 'SLOW') AS range_state,
           lnk.ps, lnk.pack_cost,
           rop.ros_14d, rop.ros_28d, rop.ros_56d,
           rop.ros_14d_corrected, rop.ros_28d_corrected, rop.ros_56d_corrected,
           rop.ros_14d_published, rop.ros_28d_published, rop.ros_56d_published,
           rop.ros_14d_guard, rop.ros_28d_guard, rop.ros_56d_guard,
           rop.correction_days_removed_14d, rop.correction_days_removed_28d,
           rop.correction_days_removed_56d
      FROM public.l2_stock_band b
      JOIN lnk ON lnk.product_code = b.product_code
      LEFT JOIN public.l2_stock_position sp
             ON sp.store_code = b.store_code AND sp.product_code = b.product_code
      LEFT JOIN soh so ON so.product_code = b.product_code
      LEFT JOIN rs      ON rs.product_code = b.product_code
      LEFT JOIN public.l2_bloom_ros_pantry rop
             ON rop.store_code = b.store_code AND rop.product_code = b.product_code
     WHERE b.store_code = p_store_code
       AND COALESCE(rs.range_state,'') <> 'EXCLUDED'
       AND ( (v_is_dc AND sp.department_nr = ANY(v_dept_nrs)) OR (NOT v_is_dc) )
  ),
  tiered AS (
    SELECT p.*,
           CASE p.tier WHEN 'TOP_100' THEN 14 WHEN 'TOP_1000' THEN 28 ELSE 56 END::smallint AS win,
           CASE p.tier WHEN 'TOP_100' THEN p.ros_14d      WHEN 'TOP_1000' THEN p.ros_28d      ELSE p.ros_56d      END AS w_raw,
           CASE p.tier WHEN 'TOP_100' THEN p.ros_14d_corrected WHEN 'TOP_1000' THEN p.ros_28d_corrected ELSE p.ros_56d_corrected END AS w_corr,
           CASE p.tier WHEN 'TOP_100' THEN p.ros_14d_published WHEN 'TOP_1000' THEN p.ros_28d_published ELSE p.ros_56d_published END AS w_pub,
           CASE p.tier WHEN 'TOP_100' THEN p.ros_14d_guard     WHEN 'TOP_1000' THEN p.ros_28d_guard     ELSE p.ros_56d_guard     END AS w_guard,
           CASE p.tier WHEN 'TOP_100' THEN p.correction_days_removed_14d WHEN 'TOP_1000' THEN p.correction_days_removed_28d ELSE p.correction_days_removed_56d END AS w_removed
      FROM pool p
  )
  SELECT t.product_code,
         t.description,
         t.dept_name,
         t.tier,
         t.kvi_band,
         t.range_state,
         ROUND(t.soh_raw, 2),
         t.ps,
         ROUND(t.pack_cost, 2),
         t.win,
         ROUND(t.w_raw::numeric, 3),
         ROUND(t.w_corr::numeric, 3),
         CASE WHEN COALESCE(t.w_raw,0) > 0 THEN ROUND((t.w_corr / t.w_raw)::numeric, 1) END,
         t.w_guard,
         COALESCE(t.w_removed,0)::smallint,
         (t.win - COALESCE(t.w_removed,0))::smallint,
         ROUND(((t.win - COALESCE(t.w_removed,0))::numeric / NULLIF(t.win,0)), 3),
         CASE WHEN COALESCE(t.w_raw,0)  > 0 THEN ROUND((GREATEST(t.soh_raw,0) / t.w_raw)::numeric,  1) END,
         CASE WHEN COALESCE(t.w_corr,0) > 0 THEN ROUND((GREATEST(t.soh_raw,0) / t.w_corr)::numeric, 1) END,
         format(
           'Correction withheld: %s of %s days in this line''s own %sd window were removed as presumed stockout, leaving %s observable (%s%% against the %s floor). The order read %s/day; the corrector measured %s/day. Cover %s days on the rate used, %s days on the corrected rate. JUDGE THE UNCERTAINTY: a rate resting on few observable days is thin evidence (R28 S5).',
           COALESCE(t.w_removed,0), t.win, t.win,
           (t.win - COALESCE(t.w_removed,0)),
           ROUND(((t.win - COALESCE(t.w_removed,0))::numeric / NULLIF(t.win,0)) * 100, 0),
           v_floor,
           ROUND(t.w_raw::numeric,2), ROUND(t.w_corr::numeric,2),
           CASE WHEN COALESCE(t.w_raw,0)  > 0 THEN ROUND((GREATEST(t.soh_raw,0)/t.w_raw)::numeric,1)  END,
           CASE WHEN COALESCE(t.w_corr,0) > 0 THEN ROUND((GREATEST(t.soh_raw,0)/t.w_corr)::numeric,1) END
         )
    FROM tiered t
   WHERE t.range_state IN ('HERO','CORE')
     AND t.w_guard = 'withheld_observable_floor'
     AND t.w_pub IS NULL
     AND COALESCE(t.w_corr,0) > COALESCE(t.w_raw,0)
   ORDER BY t.w_corr DESC NULLS LAST, t.product_code;
END $fn$;

-- A READ rpc. Grants stated explicitly -- a create_*.sql without its grants is
-- incomplete (R30 addendum). anon-executable by design; the R30 addendum
-- extension's mandatory anon REVOKE is scoped to MUTATING functions.
REVOKE ALL ON FUNCTION public.rpc_bloom_hidden_demand(text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_hidden_demand(text,text,date) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
