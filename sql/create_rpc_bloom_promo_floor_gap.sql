-- =============================================================================
-- rpc_bloom_promo_floor_gap  --  THE PROMO FLOOR GAP WORKLIST
-- SB-CC-BLOOM-018 item 2.  Effective 2026-07-29.  CC.
-- =============================================================================
-- WHAT IT IS
--   Promo-in-window lines that finish the order BELOW their own promo-lifted
--   floor, ranked HERO -> KVI_CRITICAL -> KVI_IMPORTANT -> rand, carrying the
--   packs and the rand it would take to close each one.
--
-- WHY IT EXISTS
--   The promo uplift reaches l2_stock_band and dies before the order: the
--   recipe recomputes its bands at order time from an UNLIFTED demand
--   (ENG-052, OPEN).  Measured 2026-07-29 across all five DC desks:
--   1,290 promo lines in window, 911 (70.6%) ordering ZERO, 634 units/day of
--   promotional demand unserved, 204 lines below their promo floor of which
--   69 are KVI or HERO, R236,762.85 to close.
--
-- THE RULE FOR THIS OBJECT: SURFACE THE GAP, DO NOT CHANGE THE NUMBER.
--   ENG-052 and the uplift re-derivation land together (PM ruling 2026-07-29)
--   and neither lands here.  This function READS rpc_bloom_order_recipe and
--   changes no quantity.  When ENG-052 lands, its rows simply go to zero.
--
-- uplift_at_cap -- READ THIS BEFORE TRUSTING AN UPLIFT
--   A line whose uplift sits on forge_config.promo_uplift_cap is reporting a
--   BOUND, not a measurement: the true uplift is >= that value and unknown.
--   Measured 2026-07-29: 154 of 1,436 promo-window lines group-wide (10.7%)
--   are censored this way -- 10116 10.6% / 21355 5.7% / 80175 13.0% /
--   80176 3.1% / 80579 10.8%.  A model fitted on censored inputs inherits the
--   cap and cannot know it did (PM ruling: measure the censoring rate before
--   any model work).  ENG-053's "5.00 at Roosville vs 1.12 at Delareyville" is
--   proven to be one censored bound beside one real measurement, on one EAN
--   (6001019912371) across five product codes -- not two stores disagreeing.
--
-- TRAP: FIGURES ARE GENERATE-SPECIFIC.
--   The buy-in window and the drop cover both move with the delivery date, so
--   line counts and rand totals change with the generate.  Any published
--   figure names its generate.  The stable number across measurements is the
--   KVI-and-HERO-below-floor count, not the pool count.
--
-- Grants: read RPC, anon-executable by design (R30 addendum extension scopes
-- the double-revoke to MUTATING functions only).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_promo_floor_gap(text,date,date,text);

CREATE FUNCTION public.rpc_bloom_promo_floor_gap(
  p_store_code    text,
  p_delivery_date date,
  p_next_delivery date,
  p_route         text
)
RETURNS TABLE (
  rank_order            integer,
  store_code            text,
  route                 text,
  product_code          bigint,
  ean                   text,
  description           text,
  kvi_band              text,
  is_bt_hero            boolean,
  range_state           text,
  priority_class        text,
  soh                   numeric,
  suggested_packs       integer,
  pack_size             smallint,
  pack_cost             numeric,
  position_units        numeric,
  promo_floor_units     numeric,
  order_demand_per_day  numeric,
  band_demand_per_day   numeric,
  promo_uplift_band     numeric,
  promo_uplift_source   text,
  promo_uplift_basis    text,
  uplift_at_cap         boolean,
  shortfall_units       numeric,
  shortfall_packs       integer,
  shortfall_rand        numeric,
  days_cover_now        numeric,
  days_cover_at_floor   numeric,
  reason                text
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $fn$
DECLARE
  v_cap numeric;
BEGIN
  -- canon SS14 v8 item 6 / the promo_uplift ladder cap. Config, never a literal (R25).
  SELECT value_num INTO v_cap
    FROM forge_config
   WHERE config_key = 'promo_uplift_cap' AND retired_on IS NULL
   ORDER BY store_format = '*' LIMIT 1;

  RETURN QUERY
  WITH r AS (
    SELECT * FROM public.rpc_bloom_order_recipe(
      p_store_code, p_delivery_date, p_next_delivery,
      NULL, NULL, NULL, false, 15, 24, 25, 3.0, p_route)
  ),
  gap AS (
    SELECT r.*,
           (COALESCE(r.soh,0) + r.suggested_packs * r.pack_size)::numeric AS pos_units,
           CASE WHEN r.is_bt_hero                THEN 'HERO'
                WHEN r.kvi_band = 'KVI_CRITICAL' THEN 'KVI_CRITICAL'
                WHEN r.kvi_band = 'KVI_IMPORTANT' THEN 'KVI_IMPORTANT'
                ELSE 'STANDARD' END              AS pri_class,
           CASE WHEN r.is_bt_hero                THEN 1
                WHEN r.kvi_band = 'KVI_CRITICAL' THEN 2
                WHEN r.kvi_band = 'KVI_IMPORTANT' THEN 3
                ELSE 4 END                       AS pri_rank
    FROM r
    WHERE r.promo_in_window
      AND r.promo_floor_units IS NOT NULL
      AND (COALESCE(r.soh,0) + r.suggested_packs * r.pack_size) < r.promo_floor_units
  )
  SELECT
    ROW_NUMBER() OVER (ORDER BY g.pri_rank, g.promo_shortfall_rand DESC NULLS LAST, g.product_code)::int,
    p_store_code, p_route, g.product_code, g.ean, g.description,
    g.kvi_band, g.is_bt_hero, g.range_state, g.pri_class,
    g.soh, g.suggested_packs, g.pack_size, g.pack_cost,
    g.pos_units, ROUND(g.promo_floor_units,1),
    ROUND(g.rhythm_adjusted_demand,3), ROUND(g.promo_band_demand,3),
    g.promo_uplift_band, g.promo_uplift_band_source, g.promo_uplift_band_basis,
    (v_cap IS NOT NULL AND g.promo_uplift_band >= v_cap),
    ROUND(g.promo_shortfall_units,1), g.promo_shortfall_packs, g.promo_shortfall_rand,
    ROUND(g.pos_units / NULLIF(g.promo_band_demand,0), 1),
    ROUND(g.promo_floor_units / NULLIF(g.promo_band_demand,0), 1),
    g.promo_gap_reason
  FROM gap g
  ORDER BY g.pri_rank, g.promo_shortfall_rand DESC NULLS LAST, g.product_code;
END;
$fn$;

COMMENT ON FUNCTION public.rpc_bloom_promo_floor_gap(text,date,date,text) IS
  'SB-CC-BLOOM-018 item 2. The PROMO FLOOR GAP worklist: promo-in-window lines finishing below their own promo-lifted floor, ranked HERO then KVI_CRITICAL then KVI_IMPORTANT then by rand, with the packs and rand to close. SURFACING ONLY - reads rpc_bloom_order_recipe and changes no quantity (ENG-052 stays open until the model lands). uplift_at_cap flags a line sitting on the promo_uplift_cap, which is the ENG-053 input-disagreement signal. Figures are generate-specific: the buy-in window and the drop cover both move with the delivery date, so a published figure names its generate.';

GRANT EXECUTE ON FUNCTION public.rpc_bloom_promo_floor_gap(text,date,date,text) TO anon, authenticated;
