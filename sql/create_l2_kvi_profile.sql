-- =============================================================================
-- create_l2_kvi_profile.sql
-- SB-CC-BLOOM-003 Ship 2. L2 pantry object #1 of 5 (BLOOM-003 s2/s2b).
-- R28: effective_from 2026-07-07. Formula GENERAL, weights/counts/skew
-- DEMO_CALIBRATION (config keys kvi_w_value / kvi_w_penetration /
-- kvi_w_consistency / kvi_critical_count / kvi_important_count), values per
-- BLOOM-003 s2b #1-2, backtest-proven at 80175 (SB-STRAT-002-PHASE3-BACKTEST
-- 2026-07-07: this exact blend held a top-200 KVI set at -0.5% YoY through a
-- -11.2% store month).
--
-- ARCHITECTURE: persistent TABLE + refresh_<name>(p_store) per-store
-- function, idempotent (DELETE store rows + re-INSERT) -- the proven pattern
-- in this codebase (l2_classification, l2_anomaly_daily, l2_bloom_ros_pantry)
-- for anything too heavy for a single platform-wide materialized view.
--
-- SCOPE: l2_stock_position WHERE class='NORMAL' at the store (canon s8.2 --
-- this already carves virtual/production/non-stock lines per canon s12b, so
-- no separate virtual-line filter is needed here).
--
-- FORMULA (BLOOM-003 s2b #1):
--   kvi_score = w_value * percent_rank(13-month rand value)
--             + w_penetration * percent_rank(13-month selling days)
--             + w_consistency * percent_rank(consistency_score)
--   v1 weights: 0.6 / 0.4 / 0.0 -- consistency is computed and stored as its
--   own field but not weighted into the score (the rhythm archetype, built
--   next in l2_rhythm_profile, carries that job; double-counting it here
--   would muddy both facts, per BLOOM-003 s2b #1).
--   consistency_score = 1 - LEAST(stddev(daily qty)/avg(daily qty), 1) over
--   the same 13-month window, on selling days only. A crude but auditable
--   evenness measure -- higher = steadier daily demand. Informational only
--   in v1 (weight 0.0).
--
-- PENETRATION: selling days over the FULL 13-month calendar (not in-stock
-- days). BLOOM-003 s2b #1 names the in-stock-day correction as a named
-- sharpener owed once the stockout-corrected read exists -- not built here,
-- not silently assumed away (R23: a named gap, not a zero).
--
-- BANDS (BLOOM-003 s2b #2 -- rank-based, NOT percentile, NOT score
-- threshold): KVI_CRITICAL = top `p_critical_count` (200) by kvi_score.
-- KVI_IMPORTANT = ranks (p_critical_count, p_important_count] (201-500).
-- STANDARD = the rest of the LIFE-GATED pool (canon s14 addendum v3 life
-- gate: bucket not in DEAD_ZERO/PHANTOM_ZERO/COST_ERROR/NON_STOCK, >=1 sale
-- in 56d, >=3 distinct selling days in 91d). LONG_TAIL = NORMAL-class lines
-- that do NOT pass the life gate -- present in the pool (never silently
-- dropped, R21 s5) but outside the contribution scope STRAT-002 s3 scopes
-- the full recipe treatment to.
--
-- CROSS-STORE RECONCILIATION (BLOOM-003 s2b #6): NOT computed here. NO
-- averaging, ever -- each store's score/band is final on its own data. The
-- cross-store exception layer (format_kvi_flag + the ranging-gap review
-- queue) is a separate pass, refresh_l2_kvi_cross_store() below, run AFTER
-- both SPAR stores have been (re)profiled. TOPS trio deliberately excluded
-- from that pass until the stockout-corrected read lands there (SB-STRAT-001
-- s8: "erratic availability poisons a raw skew read").
--
-- CONSUMABLE/PACKAGING CARVE (PM correction to s2b #1, 2026-07-08 -- caught
-- live: SPAR CARRIER BAG ranked #2 KVI-Critical at 80175). Widening the
-- carve alongside virtuals (STRAT-001 s8 finding 1): any NORMAL-class line
-- whose l2_classification.area_class = 'CONSUMABLE' (packaging/consumable
-- areas -- carrier bags, till rolls, cups; the "sells + receives falls
-- through the consumable check" case, STOCK-TRIAGE-TOOL sA.3) is excluded
-- from ranking and banding entirely -- never a KVI_CRITICAL/IMPORTANT/
-- STANDARD floor slot. Its value_13m/selling_days_13m/consistency_score
-- STAY on the row (never dropped, R21 s5) as a traffic-signal reference
-- only; band = 'CONSUMABLE_CARVE', kvi_score=0 / kvi_rank=NULL so it can
-- never win a rank comparison. area_class = 'SERVICE' (production/service depts,
-- e.g. in-house bakery bread) is NOT carved -- those are real bought-and-sold
-- KVIs per STRAT-001's own gut-list (Sasko brown, Blue Ribbon), the carve is
-- CONSUMABLE only.
--
-- KNOWN LIMIT, logged not fixed (PM, 2026-07-08): COCA COLA PET holds two of
-- the top-3 ranks at 80175 on two separate product codes (likely genuine
-- different sizes). KVI banding currently reads by product_code, not by
-- product family. When the parent-child/family roll-up lands (canon s14 v5,
-- BLOOM-003 s2 "Sibling/family roll-up" row, still PARTIAL) KVI banding
-- should roll up to the family the same way stock bands will. Tracked
-- refinement, not a Ship 2 blocker.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_kvi_profile (
  client_id           text NOT NULL DEFAULT 'socialbrand',
  store_code          text NOT NULL,
  product_code        bigint NOT NULL,
  value_13m           numeric NOT NULL DEFAULT 0,
  selling_days_13m    int NOT NULL DEFAULT 0,
  consistency_score   numeric,
  passes_life_gate    boolean NOT NULL DEFAULT false,
  kvi_score           numeric NOT NULL DEFAULT 0,
  kvi_rank            int,
  kvi_band            text NOT NULL DEFAULT 'LONG_TAIL',
  format_group        text,
  format_kvi_flag     text,
  w_value             numeric NOT NULL,
  w_penetration       numeric NOT NULL,
  w_consistency       numeric NOT NULL,
  critical_count      int NOT NULL,
  important_count     int NOT NULL,
  engine_version      text NOT NULL DEFAULT 'v1.0',
  profiled_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX IF NOT EXISTS idx_l2_kvi_profile_band ON public.l2_kvi_profile (store_code, kvi_band);
CREATE INDEX IF NOT EXISTS idx_l2_kvi_profile_rank ON public.l2_kvi_profile (store_code, kvi_rank);

REVOKE ALL ON public.l2_kvi_profile FROM PUBLIC;
GRANT SELECT ON public.l2_kvi_profile TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_kvi_profile(
  p_store            text,
  p_w_value          numeric DEFAULT 0.6,
  p_w_penetration    numeric DEFAULT 0.4,
  p_w_consistency    numeric DEFAULT 0.0,
  p_critical_count   int DEFAULT 200,
  p_important_count  int DEFAULT 500
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

  DELETE FROM public.l2_kvi_profile WHERE store_code = p_store;

  WITH daily AS (
    SELECT product_code, sale_date, SUM(qty) AS day_qty
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - INTERVAL '13 months' AND sale_date <= v_anchor
    GROUP BY product_code, sale_date
  ),
  agg_13m AS (
    SELECT product_code,
           COUNT(*) AS selling_days_13m,
           AVG(day_qty) AS mean_day_qty,
           STDDEV(day_qty) AS sd_day_qty
    FROM daily
    GROUP BY product_code
  ),
  value_13m AS (
    SELECT product_code, SUM(sales_incl_vat) AS value_13m
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - INTERVAL '13 months' AND sale_date <= v_anchor
    GROUP BY product_code
  ),
  sold_56 AS (
    SELECT DISTINCT product_code FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - 56 AND sale_date <= v_anchor
  ),
  days_91 AS (
    SELECT product_code, COUNT(DISTINCT sale_date) AS days_91
    FROM public.sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date > v_anchor - 91 AND sale_date <= v_anchor
    GROUP BY product_code
  ),
  latest_class AS (
    SELECT DISTINCT ON (product_code) product_code, bucket, area_class
    FROM public.l2_classification
    WHERE store_code = p_store
    ORDER BY product_code, snapshot_date DESC
  ),
  pool AS (
    SELECT sp.product_code
    FROM public.l2_stock_position sp
    WHERE sp.store_code = p_store AND sp.class = 'NORMAL'
  ),
  scored AS (
    SELECT p.product_code,
           COALESCE(v.value_13m, 0) AS value_13m,
           COALESCE(a.selling_days_13m, 0) AS selling_days_13m,
           CASE WHEN a.mean_day_qty > 0
                THEN 1 - LEAST(COALESCE(a.sd_day_qty, 0) / a.mean_day_qty, 1)
                ELSE NULL END AS consistency_score,
           (s56.product_code IS NOT NULL
             AND COALESCE(d91.days_91, 0) >= 3
             AND COALESCE(lc.bucket, '') NOT IN ('DEAD_ZERO','PHANTOM_ZERO','COST_ERROR','NON_STOCK')
           ) AS passes_life_gate,
           (COALESCE(lc.area_class, '') = 'CONSUMABLE') AS is_consumable_carve
    FROM pool p
    LEFT JOIN agg_13m a ON a.product_code = p.product_code
    LEFT JOIN value_13m v ON v.product_code = p.product_code
    LEFT JOIN sold_56 s56 ON s56.product_code = p.product_code
    LEFT JOIN days_91 d91 ON d91.product_code = p.product_code
    LEFT JOIN latest_class lc ON lc.product_code = p.product_code
  ),
  rankable AS (
    SELECT * FROM scored WHERE NOT is_consumable_carve
  ),
  carved AS (
    SELECT * FROM scored WHERE is_consumable_carve
  ),
  pctd AS (
    SELECT *,
           PERCENT_RANK() OVER (ORDER BY value_13m) AS pct_value,
           PERCENT_RANK() OVER (ORDER BY selling_days_13m) AS pct_penetration,
           PERCENT_RANK() OVER (ORDER BY COALESCE(consistency_score, 0)) AS pct_consistency
    FROM rankable
  ),
  ranked AS (
    SELECT *,
           (p_w_value * pct_value + p_w_penetration * pct_penetration + p_w_consistency * pct_consistency) AS kvi_score
    FROM pctd
  ),
  final AS (
    SELECT *,
           RANK() OVER (ORDER BY kvi_score DESC) AS kvi_rank
    FROM ranked
  )
  INSERT INTO public.l2_kvi_profile (
    client_id, store_code, product_code, value_13m, selling_days_13m, consistency_score,
    passes_life_gate, kvi_score, kvi_rank, kvi_band,
    w_value, w_penetration, w_consistency, critical_count, important_count,
    engine_version, profiled_at
  )
  SELECT 'socialbrand', p_store, product_code, value_13m, selling_days_13m, consistency_score,
         passes_life_gate, kvi_score, kvi_rank,
         CASE WHEN kvi_rank <= p_critical_count THEN 'KVI_CRITICAL'
              WHEN kvi_rank <= p_important_count THEN 'KVI_IMPORTANT'
              WHEN passes_life_gate THEN 'STANDARD'
              ELSE 'LONG_TAIL' END,
         p_w_value, p_w_penetration, p_w_consistency, p_critical_count, p_important_count,
         'v1.0', now()
  FROM final
  UNION ALL
  SELECT 'socialbrand', p_store, product_code, value_13m, selling_days_13m, consistency_score,
         passes_life_gate, 0::numeric AS kvi_score, NULL::int AS kvi_rank, 'CONSUMABLE_CARVE',
         p_w_value, p_w_penetration, p_w_consistency, p_critical_count, p_important_count,
         'v1.0', now()
  FROM carved;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('store_code', p_store, 'anchor', v_anchor, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_kvi_profile(text, numeric, numeric, numeric, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_kvi_profile(text, numeric, numeric, numeric, int, int) TO authenticated;

-- -----------------------------------------------------------------------------
-- Cross-store exception layer (BLOOM-003 s2b #6). NO averaging -- run AFTER
-- both SPAR stores are profiled. Matches on v_ean_bridge (real GS1 EAN only,
-- R20). Sets format_kvi_flag on BOTH sides of an agreeing/disagreeing pair;
-- never mutates kvi_score/kvi_rank/kvi_band, which stay final per-store facts.
-- TOPS trio (21355/80176/80579) deliberately NOT run here (SB-STRAT-001 s8).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_kvi_cross_store()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_flagged int;
BEGIN
  UPDATE public.l2_kvi_profile SET format_kvi_flag = NULL
  WHERE store_code IN ('10116','80175');

  WITH bridged AS (
    SELECT k.store_code, k.product_code, k.kvi_band, k.kvi_rank, b.ean
    FROM public.l2_kvi_profile k
    JOIN public.v_ean_bridge b ON b.store_code = k.store_code AND b.product_code = k.product_code
    WHERE k.store_code IN ('10116','80175')
  ),
  paired AS (
    SELECT a.store_code AS store_a, a.product_code AS product_a, a.kvi_band AS band_a,
           b.store_code AS store_b, b.product_code AS product_b, b.kvi_band AS band_b
    FROM bridged a
    JOIN bridged b ON b.ean = a.ean AND b.store_code <> a.store_code
  ),
  flags AS (
    SELECT store_a AS store_code, product_a AS product_code,
      CASE
        WHEN band_a IN ('KVI_CRITICAL','KVI_IMPORTANT') AND band_b IN ('KVI_CRITICAL','KVI_IMPORTANT')
          THEN 'SIBLING_AGREE'
        WHEN band_a IN ('STANDARD','LONG_TAIL') AND band_b = 'KVI_CRITICAL'
          THEN 'RANGING_GAP_SIBLING_CRITICAL'
        ELSE NULL
      END AS flag
    FROM paired
  )
  UPDATE public.l2_kvi_profile k
  SET format_kvi_flag = f.flag
  FROM flags f
  WHERE k.store_code = f.store_code AND k.product_code = f.product_code AND f.flag IS NOT NULL;

  GET DIAGNOSTICS v_flagged = ROW_COUNT;
  RETURN jsonb_build_object('pair', ARRAY['10116','80175'], 'rows_flagged', v_flagged);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_kvi_cross_store() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_kvi_cross_store() TO authenticated;

-- -----------------------------------------------------------------------------
-- The ranging-gap review queue (BLOOM-003 s2b #6) -- never auto-promoted into
-- the local floor, surfaced for a human ranging decision (feeds Roosville's
-- +10% push, SB-ORD-DESK-001 s3/s5).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_l2_kvi_ranging_gap AS
SELECT k.store_code, k.product_code, sp.description, sp.dept_name, sp.subdept_name,
       k.kvi_band AS local_band, k.kvi_rank AS local_rank, k.format_kvi_flag
FROM public.l2_kvi_profile k
JOIN public.l2_stock_position sp ON sp.store_code = k.store_code AND sp.product_code = k.product_code
WHERE k.format_kvi_flag = 'RANGING_GAP_SIBLING_CRITICAL';

GRANT SELECT ON public.v_l2_kvi_ranging_gap TO anon, authenticated;
