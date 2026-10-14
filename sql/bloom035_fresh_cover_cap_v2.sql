-- =============================================================================
-- BLOOM-035 item 1b follow-up: THE DC FRESH COVER CAP, v2 (Pieter 14-10 16:3x, PM section 32: "an order covers to the next delivery only", perishables).
--
--   v1 (sql/bloom035_fresh_cover_cap.sql, applied 16:38 SAST) took the build mode, the build-window demand and the review period out of the fresh desk. The proof sheet it built
--   FAILED the gate "median cover per department at or under the gap to the next delivery" (gap 2 days at 10116 and 80175 for the Saturday 17-10 delivery):
--   10116 bakery 7.1, butchery 6.0, produce 7.9. 80175 bakery 30.0, butchery 5.2, HMR 54.1, produce 7.9 (cover at arrival, ordered lines, 14-10 16:4x SAST).
--   Two causes, both read off the stored proof lines: (1) the KVI safety days (4 critical, 2 important) sit inside the min band, so a butchery KVI line aims at gap + 4 = 6 days,
--   (2) every line that needs anything is ROUNDED UP to a whole pack (ENG-229 rounds a minimum-mode line up to reach its band, and GREATEST(...,1) puts at least one pack on any need),
--   while the median pack on this desk is 4.4 days of sales for bakery and 6.4 for produce at 10116 and 27 and 56 days for bakery and HMR at 80175.
--
--   WHAT v2 CHANGES, for route DC_FRESH only (every other route reads the same SQL it read before, R22):
--     (1) safety days are 0: the band is the delivery-to-delivery days and nothing on top;
--     (2) the pack count ROUNDS DOWN: floor(need / pack), no forced first pack, no round-up to the band. A line whose need is under one pack gets no pack from this rule.
--         The shelf still gets its pack from the two rules that already guard the shelf and are not touched: the minimum-presence rule and Pieter's temporary 3-unit floor (ENG-230).
--   The geared (promo) branch takes the same rounding.
--
-- Asserted replace on the live definition, pinned on md5 e349515907839382dcf85456ef1af7ea (after v1). One count assertion per anchor.
-- REVERSE: remove the three route conditions.
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
  IF v_live IS DISTINCT FROM 'e349515907839382dcf85456ef1af7ea' THEN RAISE EXCEPTION 'pin failed: live md5 % is not e3495159', v_live; END IF;

  def := pg_get_functiondef('public.rpc_bloom_order_recipe(text, date, date, date, text, numeric, boolean, integer, integer, integer, numeric, text, jsonb, integer, numeric)'::regprocedure);

  def := pg_temp.rp(def, $a$CASE d.kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END AS safety_days$a$,
                         $b$(CASE WHEN %15$L = 'DC_FRESH' THEN 0 ELSE (CASE d.kvi_band WHEN 'KVI_CRITICAL' THEN 4 WHEN 'KVI_IMPORTANT' THEN 2 ELSE 0 END) END) AS safety_days$b$, 1, 'fresh safety days');

  def := pg_temp.rp(def, $a$WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1,$a$,
                         $b$WHEN n.needu>0 AND %15$L = 'DC_FRESH' THEN FLOOR(n.needu/n.ps)
              WHEN n.needu>0 THEN GREATEST(FLOOR(n.needu/n.ps),1,$b$, 1, 'fresh rounding normal');

  def := pg_temp.rp(def, $a$WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1,$a$,
                         $b$WHEN g.needu_geared>0 AND %15$L = 'DC_FRESH' THEN FLOOR(g.needu_geared/g.ps)
              WHEN g.needu_geared>0 THEN GREATEST(FLOOR(g.needu_geared/g.ps),1,$b$, 1, 'fresh rounding geared');

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
