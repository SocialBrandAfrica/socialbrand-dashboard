-- =============================================================================
-- BLOOM-035 item 3b (ENG-012): DAYS TO THE TRUCK. WRITTEN 14-10-2026, NOT APPLIED. Simulate first (scratch/sim_item3b_days_to_truck.sql, 20:00 to 22:00 SAST only).
--
--   The brief (v2.0 item 3b, Pieter's blueprint of 06-10): "projected position = stock now (never below 0) - rate x days from the stock reading to this delivery
--   + stock on the way. Cover = days to the truck + drop cover."
--
--   TODAY (rpc_bloom_order_recipe, md5 f2fb054fbf7f06943171c490abd51b5b): v_lead is the DROP GAP (next delivery less this delivery). It is used for the
--   band (min_band_ot = ros x lead + safety x ros, review days) and ALSO as the depletion before the delivery (proj = soh - ros x lead + on order). The days
--   from the stock reading to the truck are not modelled. Named lines (sql/create_rpc_bloom_order_recipe.sql, md5-equal to live): 450 and 454 set v_lead,
--   648 and 649 the band, 712 and 715 the projected position and the need, 809 and 811 the same for the geared (promo) branch, 947 and 965 the output.
--   ENG-228 to ENG-230 (05-10) changed the open-order expiry, the min-band round-up (line 728, reads n.proj against the band) and the 3-unit floor.
--   None of them touch the depletion days.
--
--   WHAT THIS CHANGES: ONLY the depletion. New variable v_days_to_truck = GREATEST(delivery_date - the stock reading date, 0), default v_lead where there
--   is no reading. It replaces v_lead in the four depletion sites (t.ros_final, wg.ros_final x gear: 712, 715, 809, 811). The band keeps v_lead: the band
--   is the level wanted AT ARRIVAL (drop cover plus safety), so it is the drop gap by definition. (Cover = days to the truck + drop cover is the same
--   quantity as target at arrival minus position at arrival, so applying both to the band would count the truck days twice.) The story names the days:
--   "truck in N days, cover N + drop days". lead_days_used keeps meaning the drop gap and the output columns do not change (no signature change).
--
--   NOT in this file: the nightly stored band (refresh_l2_stock_band) builds per store and product, with no delivery date, on fixed constants. The recipe
--   re-derives the band at order time with the calendar drop (line 648), which is the half of ENG-012 that acts on the order. The nightly band is the
--   standing fact. See BUG-LOG ENG-012 addendum.
--
-- Asserted replace on the live definition, pinned on md5 f2fb054fbf7f06943171c490abd51b5b (46,427 chars). One count assertion per anchor.
-- REVERSE: swap the four %32$s back to %9$s and remove the argument. The story text changes only.
-- =============================================================================

SET lock_timeout = '5s';

CREATE FUNCTION pg_temp.rp(p_def text, p_from text, p_to text, p_expect int, p_what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
  n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  IF n <> p_expect THEN
    RAISE EXCEPTION '%: anchor [%] found % time(s), expected %', p_what, left(p_from, 70), n, p_expect;
  END IF;
  RETURN replace(p_def, p_from, p_to);
END $f$;

DO $mig$
DECLARE
  def text; v_live text;
BEGIN
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_bloom_order_recipe';
  IF v_live IS DISTINCT FROM 'f2fb054fbf7f06943171c490abd51b5b' THEN RAISE EXCEPTION 'pin failed: live md5 % is not f2fb054f', v_live; END IF;

  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);

  def := pg_temp.rp(def, $a$v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int;$a$,
                         $b$v_anchor date; v_soh_dt date; v_lead int; v_lead_source text; v_dom int; v_days_to_truck int;$b$, 1, 'declare');

  def := pg_temp.rp(def, $a$    v_lead_source := 'fallback_anchor_gap';
  END IF;
$a$,
                         $b$    v_lead_source := 'fallback_anchor_gap';
  END IF;

  -- BLOOM-035 item 3b (ENG-012): the days from the stock reading to this delivery. The depletion before the truck uses these, never the drop gap.
  v_days_to_truck := COALESCE(GREATEST(p_delivery_date - v_soh_dt, 0), v_lead);
$b$, 1, 'days to truck');

  def := pg_temp.rp(def, $a$t.ros_final * %9$s$a$, $b$t.ros_final * %32$s$b$, 2, 'depletion normal');
  def := pg_temp.rp(def, $a$(wg.ros_final*wg.gear) * %9$s$a$, $b$(wg.ros_final*wg.gear) * %32$s$b$, 2, 'depletion geared');

  def := pg_temp.rp(def, $a$v_relevant_min_cover_days, v_tf_units, v_tf_pack_days);$a$,
                         $b$v_relevant_min_cover_days, v_tf_units, v_tf_pack_days, v_days_to_truck);$b$, 1, 'format argument 32');

  def := pg_temp.rp(def, $a$SOH %%s, lead %%s(%%s) -> proj %%s,$a$,
                         $b$SOH %%s, drop %%s(%%s), truck in %%s days, cover %%s days -> proj %%s,$b$, 1, 'story format');
  def := pg_temp.rp(def, $a$pk.soh_raw, %9$s, %17$L::text, ROUND(pk.proj,1)$a$,
                         $b$pk.soh_raw, %9$s, %17$L::text, %32$s, (%32$s + %9$s), ROUND(pk.proj,1)$b$, 1, 'story args');

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
