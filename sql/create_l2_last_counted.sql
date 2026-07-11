-- =============================================================================
-- create_l2_last_counted.sql
-- BUG-LOG ENG-006 (found 2026-07-10, fixed 2026-07-11). L2 pantry fact.
-- =============================================================================
-- PROBLEM: l2_stock_position.last_inv_date / last_inv_soh are Sigma summary
--   fields (DBStAr-side), not ledger-derived -- exactly the class canon s8.3
--   warns about (summary fields are cross-checks only, never inputs). Proof:
--   max last_inv_date at 10116 = 2023-06-22 while the sigma_movements
--   I-channel (DIWAINV, stocktake/adjustment events) runs current, with 6,669
--   distinct products counted in the trailing 91 days at that store alone. Any
--   consumer trusting the summary field concludes nothing was counted in 3
--   years.
--
-- FIX: a nightly precompute of the SAME ledger-true fact the Forge toolkit
--   (2026-07-10 build) was already computing ad hoc, per request, per store
--   (~1s/store x 5 = the named Forge perf debt): DISTINCT ON (store,product)
--   sigma_movements WHERE movement_type='I' ORDER BY movement_date DESC. This
--   object precomputes it once nightly instead. Two consumers repointed to
--   read it in the SAME migration this table was created in (R22 -- a fact
--   with no reader is dead weight, and building without repointing would
--   leave the perf debt in place): `rpc_forge_count_list`'s `counted` CTE and
--   `rpc_forge_integrity`'s `counted` CTE (the count_coverage_91d instrument).
--   Verified identical output before/after repoint: count_coverage_91d totals
--   byte-identical bank-wide (10116=2807, 21355=500, 80175=4123, 80176=596,
--   80579=421); rpc_forge_count_list's daily-mode strata unchanged in size,
--   one line's last-counted-date presence shifted at 10116 (427->426, real
--   trading activity between the baseline and post-migration calls, not a
--   defect -- the countable pool a stocktake can post to any minute the store
--   trades).
--
-- NOT IN SCOPE (named, not built here): repointing l2_stock_position's own
--   last_inv_date/last_inv_soh columns to the ledger, or retiring them with
--   lineage -- that is a larger L2 rebuild with CASCADE implications
--   (CLEANUP-ENGINE-CANON s13, 31 named dependents) properly left for the
--   next l2_stock_position rebuild, not bundled into this narrower fix.
--
-- counted_91d is a point-in-time flag (movement_date >= CURRENT_DATE - 91 AT
--   REFRESH TIME), same convention as every other nightly L2 object in this
--   codebase (l2_stock_band, l2_kvi_profile, etc.) -- "as of last night",
--   refreshed daily, never claimed to be live-current mid-day.
--
-- WIRED into refresh_l2_pipeline (same migration/session, ENG-006 rides the
--   ENG-002/perf-debt wiring session). Depends only on sigma_movements (L1,
--   always fresh pre-pipeline), not on the L2 chain -- placement in the
--   pipeline is not load-bearing.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_last_counted CASCADE;

CREATE TABLE public.l2_last_counted (
  store_code          text NOT NULL,
  product_code        bigint NOT NULL,
  last_counted_date   date,
  last_counted_soh    numeric,
  counted_91d         boolean NOT NULL DEFAULT false,
  refreshed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

GRANT SELECT ON public.l2_last_counted TO anon, authenticated;

COMMENT ON TABLE public.l2_last_counted IS
  'BUG-LOG ENG-006. Ledger-true last-count fact: sigma_movements I-channel (DIWAINV), '
  'never the stale l2_stock_position.last_inv_date/last_inv_soh summary fields (max '
  '2023-06-22 at 10116 while the ledger runs current). Nightly per-store precompute of '
  'what Forge previously scanned ad hoc per request.';

CREATE OR REPLACE FUNCTION public.refresh_l2_last_counted(p_store text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
BEGIN
  DELETE FROM public.l2_last_counted WHERE store_code = p_store;

  INSERT INTO public.l2_last_counted (store_code, product_code, last_counted_date, last_counted_soh, counted_91d)
  SELECT DISTINCT ON (m.store_code, m.product_code)
    m.store_code, m.product_code, m.movement_date, m.new_soh,
    (m.movement_date >= CURRENT_DATE - 91)
  FROM public.sigma_movements m
  WHERE m.store_code = p_store AND m.movement_type = 'I'
  ORDER BY m.store_code, m.product_code, m.movement_date DESC;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('store_code', p_store, 'rows', v_rows,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_l2_last_counted(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_last_counted(text) TO authenticated;
