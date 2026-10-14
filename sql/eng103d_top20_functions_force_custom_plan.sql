-- =============================================================================
-- eng103d_top20_functions_force_custom_plan.sql   (migration eng103d_top20_functions_force_custom_plan)
-- ENG-103 (dashboard lane, 14-10-2026): PostgREST reuses pooled sessions, so after five calls Postgres switches the statements of a
-- plpgsql / sql function to a GENERIC plan. A generic plan cannot see p_dept / p_subdept / p_eans, and for the filtered branch it picked
-- the join order that reads every sale of every product of the department. MEASURED in one session, SPAR Roosville, 15 dates, BAKERY:
-- custom plan 122 and 182 ms, generic plan 3,123 ms. After this migration, with the SESSION forced to generic plans, three calls took
-- 130, 114 and 125 ms: the function's own setting wins inside it. Both functions, so the labels call cannot fall into the same trap.
-- (eng103c, the date-first rewrite of the filtered branch, is the other half: it removed the plan that read the whole history.)
-- Rollback: ALTER FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) RESET plan_cache_mode;
--           ALTER FUNCTION public.rpc_ean_labels(text[], text[], text[], text, text) RESET plan_cache_mode;
-- =============================================================================
SET LOCAL lock_timeout = '5s';
ALTER FUNCTION public.rpc_top20_totals(text[], text[], text, text, text[]) SET plan_cache_mode = 'force_custom_plan';
ALTER FUNCTION public.rpc_ean_labels(text[], text[], text[], text, text) SET plan_cache_mode = 'force_custom_plan';
