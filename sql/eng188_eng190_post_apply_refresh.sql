-- eng188_eng190_post_apply_refresh.sql
--
-- Run AFTER sql/eng188_on_order_landing_estimate_expires.sql and
-- sql/eng190_dc_promo_current_only.sql have applied. Nothing here changes a function.
-- It rebuilds the facts the two functions write and the DC order sheets that read them.
--
-- The Supabase SQL editor stops a request at 60 s, so run ONE STEP AT A TIME
-- (select the step's lines, then Run). Every step is safe to run again.

-- STEP 0, the pins. Both rows must read the NEW md5 before any step below runs.
SELECT p.proname, md5(pg_get_functiondef(p.oid)) AS md5, length(pg_get_functiondef(p.oid)) AS len
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('refresh_l2_on_order', 'rpc_bloom_promo_for_delivery');
-- expected: refresh_l2_on_order          d6655346f5d8c6cf889161fbbc031b7c / 10042
--           rpc_bloom_promo_for_delivery eb8e9e6d47451c9902532775689104cd / 3227

-- STEP 1, in transit and the budget week, all five stores (seconds).
SELECT public.refresh_l2_on_order(s) FROM unnest(ARRAY['10116','80175','21355','80176','80579']) AS s;
SELECT public.refresh_order_budget_ledger_needs(s) FROM unnest(ARRAY['10116','80175','21355','80176','80579']) AS s;

-- STEP 2, the SPAR DC ambient sheets at 10116 and 80175, fit off and fit on. The next delivery
-- resolves exactly as the nightly build resolves it (about 45 s on the 14-09 timings).
SELECT public.refresh_bloom_order_cache_all(ARRAY['DC_AMBIENT']);

-- STEP 3, the TOPS DC sheets at 21355, 80176 and 80579. If the editor times out, leave it:
-- the 01:30 SAST nightly build rebuilds them on the new functions.
SELECT public.refresh_bloom_order_cache_all(ARRAY['DC_TOPS']);

-- STEP 4, the check on the 10116 Thursday 17-09 sheet.
SELECT
  (SELECT o.on_order_qty FROM public.l2_on_order o
    WHERE o.store_code = '10116' AND o.product_code = 1674)                       AS milk_1674_in_transit,  -- expected 0 (was 1,800)
  (SELECT count(*) FROM public.rpc_bloom_promo_for_delivery('10116', 'DC_AMBIENT', DATE '2026-09-17'))
                                                                                  AS promo_rows_thu,        -- expected 969 on 15-09 (was 2,443)
  (SELECT to_jsonb(b) -> 'in_transit_into_this_week'
     FROM public.rpc_bloom_delivery_budget('10116', 'DC_AMBIENT', DATE '2026-09-17') b)
                                                                                  AS in_transit_into_week;  -- no longer the R96,455.74 phantom
