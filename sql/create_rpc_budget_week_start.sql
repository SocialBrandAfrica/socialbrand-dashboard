-- create_rpc_budget_week_start.sql
--
-- GENERATED FROM LIVE 2026-08-30 via pg_get_functiondef, hash-gated in the same
-- pass. Migration: eng142_budget_week_start_dow_key_and_helper.
--
-- ENG-142 PREP. THE ONE HOME for the budget-week anchor.
--
-- ⚠️ §0i STAMP: PARKED. This object is LIVE and CORRECT but has NO READER YET.
-- The 13 consuming sites across 7 functions are not repointed, because two of
-- them (recipe lines 117 and 128) sit inside `rpc_bloom_order_recipe`, which is
-- pinned and opens only under the A3 gate as ONE bundled pass. A key with no
-- reader is honest debt; a key that does not exist is the §0h hole store #6
-- inherits. This is the half that could be built without opening the pinned money
-- function on the eve of a placement day.
--
-- WHAT IT REPLACES. The anchor was a DUPLICATED LITERAL at 13 live sites with no
-- config key behind it. The recipe's two sites read, identically:
--     v_week_start := p_delivery_date - ((EXTRACT(ISODOW FROM p_delivery_date)::int + 1) % 7);
-- which is the Saturday anchor written as a magic `+ 1`. The general form is
--     d - ((EXTRACT(ISODOW FROM d)::int - dow + 7) % 7)
-- and at dow = 6 the two are algebraically identical: (isodow - 6 + 7) % 7 = (isodow + 1) % 7.
--
-- ⚠️ QUANTITY-NEUTRALITY IS PROVEN, NOT ASSERTED, AND PROVEN BEFORE THE RECIPE
-- OPENS. Exhaustive equality against the exact inline expression over
-- 2025-01-01 → 2027-12-31: **1,095 dates tested, 1,095 agree, 0 disagree**, all
-- seven isodows present as input, every result landing on isodow 6. So when the
-- bundled pass lands, its R22 ("re-run the recipe before and after, every line
-- identical") is a formality confirming a proof, not an experiment hoping for one.
--
-- ⚠️ STABLE, NOT IMMUTABLE -- it reads `forge_config`. Marking a config-reading
-- function IMMUTABLE would let the planner fold a stale value into a cached plan.
--
-- ⚠️ THE SEED IS DERIVED, NOT FITTED (§0h). 6 is not a chosen constant: it is the
-- anchor the 13 sites already implement, recovered from them and verified by the
-- date equality above. It therefore needs no `SEED, UNDERIVED` stamp.
--
-- anon HOLDS EXECUTE here, unlike the mutating objects in this folder: this is a
-- pure read with no table exposure beyond one config row, and desk surfaces that
-- render a budget week need it. PUBLIC is still revoked so the default-privilege
-- trap cannot re-open it.

CREATE OR REPLACE FUNCTION public.rpc_budget_week_start(p_date date)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT p_date - ((EXTRACT(ISODOW FROM p_date)::int
                    - (SELECT fc.value_num::int FROM forge_config fc
                        WHERE fc.config_key='budget_week_start_dow'
                          AND fc.store_format='*' AND fc.retired_on IS NULL)
                    + 7) % 7);
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_budget_week_start(date) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_budget_week_start(date) TO anon;
GRANT  EXECUTE ON FUNCTION public.rpc_budget_week_start(date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_budget_week_start(date) TO service_role;

-- The key this reads, for a store #6 rebuilding from source:
--   INSERT INTO forge_config (config_key, store_format, value_num, scope, effective_from, notes)
--   VALUES ('budget_week_start_dow', '*', 6, 'DEMO_CALIBRATION', <date>, '...');
-- Without the row this function returns NULL, which is the correct loud failure:
-- a missing anchor must not silently fall back to a guessed day.
