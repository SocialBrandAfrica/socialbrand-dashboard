-- create_rpc_channel_valuation_test.sql
--
-- J7 / ORDERING-CANON-BUDGETS §D7 part 2 — THE GENERAL CHANNEL VALUATION TEST.
--
-- WHAT IT IS. For any movement channel admitted to a money base, reconcile
-- SUM(cost_value) against SUM(qty x the store's own demonstrated till unit cost)
-- over the same window, per store, and report the RATIO.
--
-- WHY IT IS GENERAL AND NOT AN S/L FIX (R21, R26). S/L was found by accident.
-- The reusable half is the test, not the finding: it runs over every channel and
-- reports what it sees. Never hardcode 24, never hardcode a pack, never hardcode
-- a store (R25) -- the pack factor and the store list are both READ, never typed.
--
-- HOW TO READ THE RATIO.
--   ~0.90 to 1.10  = HEALTHY. Receipt cost drifting slightly below later selling
--                    cost is normal.
--   at or near an integer (6, 12, 24) = the §D7 signature: qty booked in SINGLES
--                    while cost_value is priced at the CASE.
--   materially below 0.90 = the opposite defect, an UNDERSTATEMENT, and it is not
--                    the same thing. Do not read it as the pack signature.
--
-- MEASURED ON FIRST RUN, week 2026-08-29 -> 2026-09-04, all five stores:
--   S/L 80176 12.94x, 80579 10.61x, 80175 2.67x  -- the only pack-shaped channel
--   R/W 80176 1.01, 80175 0.99, 80579 0.99, 10116 0.97 -- healthy
--   R/W 21355 0.59  -- OUTSIDE the band on the very channel §D7 clears as the
--                      purchase base. Group-wide R/W reads 0.93x and hides it.
--                      Thin (100 priced lines, one week). NAMED, not ruled.
--
-- WINDOW NOTE, and it is a real design finding rather than a default. The till
-- unit cost is measured over the SAME window as the movements, per §D7 part 2.
-- A 90-day till window was tested and does NOT sharpen the signature: exact
-- integer-pack agreement went 30/48 -> 29/51 at 80176 and 28/29 -> 26/34 at
-- 80579, and the wider window surfaced implied packs of 9, 13 and 21 at 80176,
-- which are not pack sizes. The one-week window is kept deliberately.
--
-- §0i: this object is the ENACTMENT of §D7 part 2. Placement in the pantry is
-- PM's call per that section; this file is the buildable form.
--
-- Grants: read-only, no writes, safe for anon + authenticated.

CREATE OR REPLACE FUNCTION public.rpc_channel_valuation_test(
  p_from   date,
  p_to     date,
  p_stores text[] DEFAULT NULL
)
RETURNS TABLE (
  channel        text,
  store_code     text,
  priced_lines   integer,
  booked_cost    numeric,
  true_cost      numeric,
  ratio          numeric,
  implied_pack   integer,
  pack_exactness numeric,
  verdict        text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH till AS (
    -- the store's OWN demonstrated till unit cost, same window (§D7 part 2)
    SELECT s.store_code, s.product_code,
           SUM(s.cost_value) / NULLIF(SUM(s.qty), 0) AS tuc
    FROM public.sigma_sales s
    WHERE s.period_kind = 'T' AND s.txn_kind = 1
      AND s.sale_date BETWEEN p_from AND p_to
      AND (p_stores IS NULL OR s.store_code = ANY(p_stores))
    GROUP BY 1, 2
    HAVING SUM(s.qty) > 0
  ),
  mv AS (
    SELECT m.store_code,
           m.movement_type || '/' || COALESCE(m.movement_process, '-') AS ch,
           m.product_code,
           SUM(m.qty)        AS qty,
           SUM(m.cost_value) AS booked
    FROM public.sigma_movements m
    WHERE m.movement_date BETWEEN p_from AND p_to
      AND (p_stores IS NULL OR m.store_code = ANY(p_stores))
    GROUP BY 1, 2, 3
    HAVING SUM(m.qty) > 0 AND SUM(m.cost_value) <> 0   -- inbound and priced
  ),
  j AS (
    SELECT mv.ch, mv.store_code, mv.qty, mv.booked, t.tuc,
           (mv.booked / NULLIF(mv.qty, 0)) / NULLIF(t.tuc, 0) AS line_ratio
    FROM mv
    LEFT JOIN till t
      ON t.store_code = mv.store_code AND t.product_code = mv.product_code
  )
  SELECT
    j.ch,
    j.store_code,
    COUNT(j.tuc)::integer                                              AS priced_lines,
    ROUND(SUM(j.booked) FILTER (WHERE j.tuc IS NOT NULL), 2)           AS booked_cost,
    ROUND(SUM(j.qty * j.tuc) FILTER (WHERE j.tuc IS NOT NULL), 2)      AS true_cost,
    ROUND(SUM(j.booked) FILTER (WHERE j.tuc IS NOT NULL)
          / NULLIF(SUM(j.qty * j.tuc) FILTER (WHERE j.tuc IS NOT NULL), 0), 2) AS ratio,
    -- the pack is DERIVED from the measured ratio, never typed
    NULLIF(ROUND(SUM(j.booked) FILTER (WHERE j.tuc IS NOT NULL)
          / NULLIF(SUM(j.qty * j.tuc) FILTER (WHERE j.tuc IS NOT NULL), 0))::integer, 1)
                                                                        AS implied_pack,
    -- what share of priced lines sit within 2% of an INTEGER multiple. High =
    -- the §D7 case/single defect. Low with a high ratio = something else.
    ROUND(
      COUNT(*) FILTER (WHERE j.line_ratio IS NOT NULL
                         AND ABS(j.line_ratio - ROUND(j.line_ratio)) <= 0.02)::numeric
      / NULLIF(COUNT(j.tuc), 0), 2)                                     AS pack_exactness,
    CASE
      WHEN COUNT(j.tuc) = 0 THEN 'NO PRICED LINE -- cannot test'
      WHEN SUM(j.booked) FILTER (WHERE j.tuc IS NOT NULL)
           / NULLIF(SUM(j.qty * j.tuc) FILTER (WHERE j.tuc IS NOT NULL), 0)
           BETWEEN 0.90 AND 1.10 THEN 'HEALTHY'
      WHEN SUM(j.booked) FILTER (WHERE j.tuc IS NOT NULL)
           / NULLIF(SUM(j.qty * j.tuc) FILTER (WHERE j.tuc IS NOT NULL), 0) > 1.10
        THEN 'OVERSTATED -- check for the case/single signature (§D7)'
      ELSE 'UNDERSTATED -- not the pack signature, a different question'
    END                                                                 AS verdict
  FROM j
  GROUP BY 1, 2
  HAVING COUNT(j.tuc) > 0
  ORDER BY 6 DESC NULLS LAST, 1, 2;
$function$;

COMMENT ON FUNCTION public.rpc_channel_valuation_test(date, date, text[]) IS
'GRADE: VERDICT. ORDERING-CANON-BUDGETS §D7 part 2. Per channel per store, reconciles booked cost_value against qty x the store''s own demonstrated till unit cost and reports the ratio. A ratio at an integer pack is the case/single valuation defect; ~0.9-1.1 is health; materially below 0.9 is an understatement and a different question. Nothing hardcoded: the pack and the store list are read, never typed (R25).';

REVOKE EXECUTE ON FUNCTION public.rpc_channel_valuation_test(date, date, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_channel_valuation_test(date, date, text[]) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_channel_valuation_test(date, date, text[]) TO authenticated;
