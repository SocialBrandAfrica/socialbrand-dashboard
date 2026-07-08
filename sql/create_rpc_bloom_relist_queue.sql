-- =============================================================================
-- create_rpc_bloom_relist_queue.sql
-- SB-CC-BLOOM-003 Ship 2/3 task 6. First-class scope per the Phase 3 backtest
-- verdict (binding condition #2) and BLOOM-003 s2b backtest-added scope --
-- NOT a footnote, NOT folded into the order-quantity formula. Sized by the
-- backtest at 80175: 950 lines with no stock, only 126 (R36k, 13%) pass the
-- life gate -- the other 824 lines (R231k, 87%) need THIS queue, a relist
-- DECISION, not a bigger order formula.
--
-- SCOPE: reads l2_kvi_profile.passes_life_gate (already computed, canon s14
-- addendum v3 life gate) -- lines the life gate CORRECTLY refuses (dead
-- >56d/thin 91d selling history). CONSUMABLE_CARVE band excluded (packaging,
-- not a merchandise relisting decision).
--
-- RELIST EVIDENCE (either signal, OR'd):
-- (a) DF-1 sibling evidence: the SAME real-GS1 EAN (v_ean_bridge, R20) is a
--     live seller (passes_life_gate=true) at the SAME-FORMAT sibling store.
--     SPAR pair only (10116<->80175) for this ship -- TOPS trio deliberately
--     excluded until the stockout-corrected read lands there (SB-STRAT-001
--     s8, same discipline as l2_kvi_profile's cross-store step).
-- (b) Cascade phantom/ambiguous signature: latest l2_classification bucket
--     IN ('PHANTOM_ZERO','AMBIGUOUS') -- a documented, engine-flagged
--     candidate for "this looks dead but the ledger doesn't fully explain
--     why" (canon s8.5, DF-7 spirit -- the full DF-7 statistical detector is
--     not re-implemented here, this reads the cascade's own existing verdict
--     instead of re-deriving it, R21: never recompute what the engine
--     already decided).
--
-- COST_ERROR EXCLUDED (caught live, 2026-07-08: CLOVER CONDENSED MILK, a
-- KVI-Critical line, landed here via sibling evidence while its bucket was
-- COST_ERROR -- its problem is broken cost data, not dead demand, and it
-- already has its own worklist, rpc_cost_error_worklist. A line whose ONLY
-- reason for failing the life gate is a cost-data fault is a repair job, not
-- a relisting decision -- excluded from this queue entirely, same "raise
-- issues, never bake them in" discipline as s2's guiding principles.
--
-- OUTPUT: a REVIEW queue, never an auto-decision (R21). Each row states which
-- evidence fired and, for the sibling case, the sibling's own numbers so the
-- buyer can judge "would this sell here too." Feeds the Desk "doors board"
-- (BLOOM-003 s3). The buyer's decision to relist is a floor action outside
-- this RPC -- once relisted (a real order goes through and sales resume),
-- the life gate naturally re-admits the line on its own next refresh.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_relist_queue(p_store_code text)
RETURNS TABLE (
  product_code        bigint,
  description          text,
  dept_name            text,
  soh                  numeric,
  capital_value        numeric,
  value_13m            numeric,
  kvi_band             text,
  bucket               text,
  sibling_store        text,
  sibling_alive        boolean,
  sibling_value_13m    numeric,
  cascade_flag         boolean,
  reason               text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET statement_timeout = '20s'
AS $function$
DECLARE
  v_sibling text;
BEGIN
  v_sibling := CASE p_store_code WHEN '10116' THEN '80175' WHEN '80175' THEN '10116' ELSE NULL END;

  RETURN QUERY
  WITH latest_bucket AS (
    SELECT DISTINCT ON (lc.product_code) lc.product_code, lc.bucket
    FROM public.l2_classification lc
    WHERE lc.store_code = p_store_code
    ORDER BY lc.product_code, lc.snapshot_date DESC
  ),
  dead_pool AS (
    SELECT k.product_code, k.kvi_band, k.value_13m
    FROM public.l2_kvi_profile k
    WHERE k.store_code = p_store_code AND k.passes_life_gate = false
      AND k.kvi_band <> 'CONSUMABLE_CARVE'
  ),
  sibling_check AS (
    SELECT dp.product_code,
      (v_sibling IS NOT NULL AND sk.passes_life_gate IS TRUE) AS sibling_alive,
      sk.value_13m AS sibling_value_13m
    FROM dead_pool dp
    LEFT JOIN public.v_ean_bridge b ON b.store_code = p_store_code AND b.product_code = dp.product_code
    LEFT JOIN public.v_ean_bridge sb ON sb.ean = b.ean AND sb.store_code = v_sibling
    LEFT JOIN public.l2_kvi_profile sk ON sk.store_code = v_sibling AND sk.product_code = sb.product_code
  )
  SELECT dp.product_code, sp.description, sp.dept_name, sp.soh, sp.capital_value,
    dp.value_13m, dp.kvi_band, lb.bucket,
    v_sibling, COALESCE(sc.sibling_alive, false), sc.sibling_value_13m,
    (COALESCE(lb.bucket, '') IN ('PHANTOM_ZERO', 'AMBIGUOUS')) AS cascade_flag,
    CASE
      WHEN COALESCE(sc.sibling_alive, false) AND COALESCE(lb.bucket, '') IN ('PHANTOM_ZERO', 'AMBIGUOUS')
        THEN 'Sibling ' || v_sibling || ' sells this EAN AND engine flags ' || lb.bucket
      WHEN COALESCE(sc.sibling_alive, false)
        THEN 'Sibling ' || v_sibling || ' sells this EAN -- likely a ranging gap here, not dead demand'
      WHEN COALESCE(lb.bucket, '') IN ('PHANTOM_ZERO', 'AMBIGUOUS')
        THEN 'Engine flags ' || lb.bucket || ' -- SOH claim unverified, count before writing this off'
      ELSE NULL
    END AS reason
  FROM dead_pool dp
  JOIN public.l2_stock_position sp ON sp.store_code = p_store_code AND sp.product_code = dp.product_code
  LEFT JOIN latest_bucket lb ON lb.product_code = dp.product_code
  LEFT JOIN sibling_check sc ON sc.product_code = dp.product_code
  WHERE (COALESCE(sc.sibling_alive, false) OR COALESCE(lb.bucket, '') IN ('PHANTOM_ZERO', 'AMBIGUOUS'))
    AND COALESCE(lb.bucket, '') <> 'COST_ERROR'
  ORDER BY sp.capital_value DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_bloom_relist_queue(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_relist_queue(text) TO anon, authenticated;
