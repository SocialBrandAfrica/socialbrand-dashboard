-- =============================================================================
-- BLOOM-035 / ENG-013: THE BEER BUDGET READS THE FAMILY, NOT THE ORDER CODE. PM 14-10-2026 16:29 (handover section 30): "for beer, budget need on the family, not the order
-- code (80176: 39 of 173 pool codes have history, projection about R34k a week against R70k of SAB purchases). Then re-check the beer protected lines."
--
--   FOUND (ENG-013 addendum 1, 14-10 16:3x): the projection of the DIRECT_BEER route sums last year's weekly cost over the ORDER codes the store buys from the SAB accounts. A beer
--   family sells through more codes than it is ordered under (a case, a six-pack, the singles from the fridge). At 80176 the 175 pool codes sit in 38 families, and the family members
--   OUTSIDE the pool sold R18,131 at cost in the LY week of 11-10-2025 against R35,447 for the pool, a further 51 per cent. The projection reads the pool only.
--
--   WHAT THIS CHANGES, for route DIRECT_BEER only (every other route reads the same SQL it read before, R22): after the pool is built, the other members of every family that holds a pool
--   code join the pool (l2_family_ros, one family_key per family, 38 families at 80176). Each member keeps its own rhythm and seasonality profile row. The 56-day trend reads the wider pool.
--   Nothing is counted twice: a member already in the pool is skipped.
--
--   NOT in this file: rpc_backtest_l2_sales_budget keeps its own pool (a diagnostic). The stock-ledger depletion (K) against scans question is in BUG-LOG ENG-013 addendum 1 and is NOT touched.
--
-- Asserted replace on the live definition of rpc_project_route_sales_budget, pinned on md5 8897619ef15c4af5eb420d019c8a45b7 (4,903 chars of body).
-- REVERSE: remove the IF block (one anchor).
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
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpc_project_route_sales_budget';
  IF v_live IS DISTINCT FROM '8897619ef15c4af5eb420d019c8a45b7' THEN RAISE EXCEPTION 'pin failed: live md5 % is not 8897619e', v_live; END IF;

  def := pg_get_functiondef('public.rpc_project_route_sales_budget(text, text, date, integer)'::regprocedure);

  def := pg_temp.rp(def, $a$  SELECT LEAST(GREATEST($a$,
                         $b$  -- BLOOM-035 (PM 14-10-2026 16:29): the beer budget reads the FAMILY, not the order code. The other members of every family that holds a pool code join the pool.
  IF p_route_key = 'DIRECT_BEER' THEN
    INSERT INTO _sb_pool (product_code)
    SELECT DISTINCT fr.product_code
      FROM l2_family_ros fr
     WHERE fr.store_code = p_store_code
       AND fr.family_key IN (SELECT fr2.family_key FROM l2_family_ros fr2
                              WHERE fr2.store_code = p_store_code AND fr2.product_code IN (SELECT product_code FROM _sb_pool))
       AND fr.product_code NOT IN (SELECT product_code FROM _sb_pool);
  END IF;

  SELECT LEAST(GREATEST($b$, 1, 'beer family pool');

  EXECUTE def;
END
$mig$;

SELECT pg_notify('pgrst', 'reload schema');
