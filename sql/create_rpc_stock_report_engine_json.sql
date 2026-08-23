-- =============================================================================
-- create_rpc_stock_report_engine_json.sql
-- ENG-093 SWEEP, catch 1. CC, 2026-08-23.
-- =============================================================================
-- THE DEFECT, measured at source before anything was built:
--   rpc_stock_report_engine is a SETOF reader served through the live 1,000-row
--   PostgREST cap, and its call site in src/app/page.jsx is a bare .rpc() with
--   no .range(). All five stores:
--
--     slowmovers  4,637 rows   <- OVER. 3,637 silently dropped.
--     oos         2,218 rows   <- OVER. 1,218 silently dropped.
--     negsoh        781        under
--     stale         410        under
--     ghost          71        under
--
--   So the Slow Movers drawer has been showing 22% of the real population and
--   presenting it as the whole. That is not slowness. It is a report that lies
--   by omission -- the R22 §3 breach this project treats as worse than the
--   vulnerability, because nobody is watching for it.
--
--   It was a KNOWN defect left live in a sibling: twelve lines below that call
--   site sits a comment describing the identical fix being applied to
--   mv_rate_of_sale ("PostgREST silently capped at 1 000 rows ... left Velocity
--   tiers and Signal C computing on <1% of the range").
--
-- THE FIX, and why it is additive:
--   ONE jsonb row, which a row cap cannot truncate -- the pattern rpc_report_rows
--   and rpc_bloom_order_cached already prove here. The SETOF original is left
--   untouched so every existing caller keeps working (R30, no breaking changes);
--   consumers move over one at a time.
--
--   `served` is computed FROM THE PAYLOAD, so a consumer compares it against
--   the array length and refuses a short read rather than rendering one. That is
--   the R22 tripwire, the same shape as the cached order's served vs line_count.
--
-- SECURITY DEFINER is deliberate and load-bearing: l2_soh_daily and
--   sigma_movements carry RLS with zero policies, so an invoker build returns a
--   confident permanent EMPTY as anon (the ENG-068 / ENG-074 / ENG-100 shape,
--   now four firings of one mechanism). Prove any change to this behaviourally,
--   as the role, never by reading a grant.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_stock_report_engine_json(
  p_store_codes text[], p_signal text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH r AS (
    SELECT * FROM public.rpc_stock_report_engine(p_store_codes, p_signal)
  )
  SELECT jsonb_build_object(
    'signal',      p_signal,
    'stores',      to_jsonb(p_store_codes),
    -- served IS the row count of the payload, computed from the payload itself.
    -- A consumer compares it to rows->>length and refuses a short read.
    'served',      (SELECT count(*) FROM r),
    'rows',        COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM r), '[]'::jsonb),
    'generated_at', clock_timestamp()
  );
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_stock_report_engine_json(text[],text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_stock_report_engine_json(text[],text) TO anon, authenticated;
