-- =============================================================================
-- create_l2_gmroi_profile.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #4 of 5 (BLOOM-003 s2b, confirmed
-- formula: "GMROI = GP rand / average capital, cost-error-clean per s12c").
-- R28: effective_from 2026-07-07. Formula GENERAL, window DEMO_CALIBRATION.
--
-- ARCHITECTURE: same proven pattern (persistent TABLE, refresh_<name>(p_store),
-- idempotent).
--
-- WINDOW CHOICE (R27 s7 -- an obvious low-risk default, stated and proceeding,
-- not one of the six load-bearing confrontations): GP rand uses the 91-day
-- window, matching this codebase's established rate-of-sale convention
-- (l2_rate_of_sale, l2_ranging_tier) and the operational cadence GMROI serves
-- -- STRAT-002 s3 step 6 "GMROI fill" is a weekly ordering decision, not a
-- long-run profile like KVI/seasonality's 13 months.
--
-- FORMULA: gp_rand_91d = SUM(sales_incl_vat - vat_value - cost_value) over
-- sigma_sales (period_kind='T', txn_kind=1) trailing 91 days. average_capital
-- = l2_stock_position.capital_value (today's point-in-time snapshot -- NAMED
-- LIMIT, R23: a true 91-day trailing average would need l2_soh_daily history
-- deeper than currently exists (~1 month of real data), so this is the
-- honest v1 proxy, flagged via average_capital_basis='POINT_IN_TIME', never
-- silently presented as a real average). gmroi = gp_rand_91d / capital_value,
-- NULL when capital_value is 0 or NULL (cannot rank a line with no capital
-- tied up -- excluded from rank/quartile, never forced to a false rank).
--
-- COST-ERROR-CLEAN (s12c): excludes any product whose latest l2_classification
-- bucket = 'COST_ERROR' -- canon's own rule (capital and cost are fiction on
-- these lines until the floor repairs the Sigma cost, s8.5 line 0b).
--
-- RANKING: gmroi_rank = RANK() DESC (1 = best GMROI) among lines with a
-- computable GMROI. gmroi_quartile = NTILE(4) ASC, so quartile 1 = the
-- BOTTOM-GMROI quartile (worst performers) -- this is the exact input
-- l2_stock_band needs for its "bottom-GMROI-quartile Standard/Long-tail caps
-- at min" rule (BLOOM-003 s2b #4).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_gmroi_profile (
  client_id               text NOT NULL DEFAULT 'socialbrand',
  store_code              text NOT NULL,
  product_code            bigint NOT NULL,
  gp_rand_91d             numeric,
  capital_value           numeric,
  average_capital_basis   text NOT NULL DEFAULT 'POINT_IN_TIME',
  gmroi                   numeric,
  gmroi_rank              int,
  gmroi_quartile          int,
  cost_error_excluded     boolean NOT NULL DEFAULT false,
  window_days             int NOT NULL DEFAULT 91,
  engine_version          text NOT NULL DEFAULT 'v1.0',
  profiled_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_gmroi_profile_quartile ON public.l2_gmroi_profile (store_code, gmroi_quartile);

REVOKE ALL ON public.l2_gmroi_profile FROM PUBLIC;
GRANT SELECT ON public.l2_gmroi_profile TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_gmroi_profile(
  p_store       text,
  p_window_days int DEFAULT 91
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_anchor date;
  v_rows int;
BEGIN
  SELECT MAX(sale_date) INTO v_anchor
  FROM public.sigma_sales
  WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1;

  IF v_anchor IS NULL THEN
    RETURN jsonb_build_object('store_code', p_store, 'rows', 0, 'error', 'no sigma_sales rows for this store');
  END IF;

  DELETE FROM public.l2_gmroi_profile WHERE store_code = p_store;

  WITH gp AS (
    SELECT product_code, SUM(sales_incl_vat - vat_value - cost_value) AS gp_rand
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - p_window_days AND sale_date <= v_anchor
    GROUP BY product_code
  ),
  latest_bucket AS (
    SELECT DISTINCT ON (product_code) product_code, bucket
    FROM public.l2_classification
    WHERE store_code = p_store
    ORDER BY product_code, snapshot_date DESC
  ),
  pool AS (
    SELECT sp.product_code, sp.capital_value
    FROM public.l2_stock_position sp
    WHERE sp.store_code = p_store AND sp.class = 'NORMAL'
  ),
  scored AS (
    SELECT p.product_code,
           COALESCE(g.gp_rand, 0) AS gp_rand_91d,
           p.capital_value,
           (COALESCE(lb.bucket, '') = 'COST_ERROR') AS cost_error_excluded,
           CASE WHEN COALESCE(lb.bucket, '') = 'COST_ERROR' OR p.capital_value IS NULL OR p.capital_value = 0
                THEN NULL
                ELSE COALESCE(g.gp_rand, 0) / p.capital_value END AS gmroi
    FROM pool p
    LEFT JOIN gp g ON g.product_code = p.product_code
    LEFT JOIN latest_bucket lb ON lb.product_code = p.product_code
  ),
  rankable AS (SELECT * FROM scored WHERE gmroi IS NOT NULL),
  unrankable AS (SELECT * FROM scored WHERE gmroi IS NULL),
  ranked AS (
    SELECT *,
      RANK() OVER (ORDER BY gmroi DESC) AS gmroi_rank,
      NTILE(4) OVER (ORDER BY gmroi ASC) AS gmroi_quartile
    FROM rankable
  )
  INSERT INTO public.l2_gmroi_profile (
    client_id, store_code, product_code, gp_rand_91d, capital_value,
    gmroi, gmroi_rank, gmroi_quartile, cost_error_excluded, window_days,
    engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code, gp_rand_91d, capital_value,
         gmroi, gmroi_rank, gmroi_quartile, cost_error_excluded, p_window_days,
         'v1.0', now()
  FROM ranked
  UNION ALL
  SELECT 'socialbrand', p_store, product_code, gp_rand_91d, capital_value,
         NULL, NULL, NULL, cost_error_excluded, p_window_days,
         'v1.0', now()
  FROM unrankable;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_gmroi_profile(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_gmroi_profile(text, int) TO authenticated;
