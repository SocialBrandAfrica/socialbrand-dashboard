-- =============================================================================
-- BLOOM-035 item 1b follow-up: THE DC FRESH COVER CAP. Pieter 14-10-2026 16:3x SAST (corrected PM's 16:13 wording): "fresh is actually wrong for cover. it's delivery to delivery
-- same as perishables". PM section 30 (16:29): "For fresh: build the cover cap, pass a proof sheet, and release it into the nightly build."
--
--   RULE (canon ORDERING-CANON DEPTH: "Perishables use the minimum band when in doubt (the spoilage guard)"; the min band is rate x (drop gap + KVI safety days)):
--   the fresh desk never builds and never carries a review period. After the order the position at arrival covers the days from this delivery to the NEXT
--   delivery of the desk's own cadence, plus the KVI safety days the engine already adds, and nothing more.
--
--   WHAT CHANGES, for route DC_FRESH only (every other route reads the same SQL it read before, R22):
--     (1) mode is always 'minimum' (no month-end or early-month build);
--     (2) the demand is the stable 56-day rate in every week of the month (the build-window short rate is a payday spike, wrong for a spoilage guard);
--     (3) review_days_ot is 0, so max_band_ot = min_band_ot and the hard ceiling of the band is the minimum band.
--   The one-pack minimum-presence first pack and the pack round-up to reach the min band (ENG-229) still apply, so a slow line can still sit above the band by up to one pack.
--
--   PROOF: scratch/proof_fresh_cover.sql builds the proof sheet and reads the median cover per department against the delivery-to-delivery days.
--   RELEASE: only after the proof passes, cron job 26 stops excluding DC_FRESH.
--
-- Asserted replace on the live definition, pinned on md5 f2fb054fbf7f06943171c490abd51b5b. One count assertion per anchor.
-- REVERSE: remove the three route conditions (the same three anchors, swapped).
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

  -- (2) the demand: the stable 56-day branch for the fresh desk in every week of the month
  def := pg_temp.rp(def, $a$CASE WHEN %10$L = 'standard' AND NOT (
               (g.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s)
            OR (g.archetype = 'EARLY_MONTH' AND %4$s >= %7$s))
             THEN GREATEST($a$,
                         $b$CASE WHEN %10$L = 'standard' AND (%15$L = 'DC_FRESH' OR NOT (
               (g.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s)
            OR (g.archetype = 'EARLY_MONTH' AND %4$s >= %7$s)))
             THEN GREATEST($b$, 1, 'fresh demand');

  -- (1) the mode: always minimum for the fresh desk
  def := pg_temp.rp(def, $a$WHEN d.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'$a$,
                         $b$WHEN %15$L = 'DC_FRESH' THEN 'minimum'
          WHEN d.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'$b$, 1, 'fresh mode');

  -- (3) the cap: no review period, so the max band is the min band
  def := pg_temp.rp(def, $a$(CASE WHEN m.gmroi_capped THEN %9$s * 0.5 ELSE %9$s END) AS review_days_ot$a$,
                         $b$(CASE WHEN %15$L = 'DC_FRESH' THEN 0 WHEN m.gmroi_capped THEN %9$s * 0.5 ELSE %9$s END) AS review_days_ot$b$, 1, 'fresh cap');

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
