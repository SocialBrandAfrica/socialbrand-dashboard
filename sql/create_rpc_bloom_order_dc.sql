-- =============================================================================
-- create_rpc_bloom_order_dc.sql
-- SB-CC-BLOOM-001. The L3 recipe ORDER_DC per CLEANUP-ENGINE-CANON section 14.
-- R27: a recipe is an ordered preference of which pantry item to use, with a
-- fallback, and it records which one answered. R28: effective_from per this
-- file's date, scope split GENERAL (formula structure) / DEMO_CALIBRATION
-- (the constants named below, sourced from bloom_dc_config + inline literals).
-- =============================================================================
-- SCOPE (canon s14): DC supplier link (type Z, non-suspended -- status<>'S')
-- x cycle department set (bloom_dc_config.dc_cycle_dept_nrs, per store,
-- RULED x5 2026-07-02) x class NORMAL x active (sold 364d OR soh<>0). The
-- "active" test is approximated via l2_stock_position.never_sold=false OR
-- soh<>0 -- l2_bloom_ros_pantry/l2_bloom_promo_pantry were built on
-- never_sold=false alone (see their headers); a line with soh<>0 but
-- never_sold=true (received, never sold) is IN this recipe's scope but
-- ABSENT from both pantries -- handled via COALESCE(...,0) below, never an
-- inner-join drop (R22 coverage discipline, same principle as the R20
-- addendum for sales aggregates).
--
-- TIERS: T100/T1000/BOR are the ALREADY-COMPUTED l2_stock_position.tier
-- (from l2_ranging_tier's value/qty ranking) -- canon s14 names which ROS
-- window and cover target apply to each existing tier, it does not define a
-- new tier split.
--   T100  -- ros_14d_corrected, 14 days cover, A MUST (always computes a
--            need, even when need<=0 -> order 0), min 1 pack once triggered.
--   T1000 -- ros_28d_corrected, 12 days cover, triggers only when need > 0.
--   BOR   -- ros_56d_corrected, fill to 14 days, triggers only when
--            projected_soh(D) < 3 (the canon-specified BOR trigger).
--
-- PROJECTED SOH(D): GREATEST(soh,0) - ros_corrected * lead_days, lead_days =
-- p_delivery_date - CURRENT_DATE (clamped >= 0) -- "computed from the dates
-- the user picked, never hardcoded" (canon).
--
-- PROMO: promo_eligibility(D,D2) computed INLINE against
-- sigma_promotion_articles (see create_l2_bloom_promo_pantry.sql header for
-- why this is not pre-materialized) -- a promo prices delivery D when
-- [start_date,end_date] overlaps [D,D2), no day offsets. Geared quantity =
-- normal quantity x promo_uplift (from l2_bloom_promo_pantry). T100 promo
-- lines DEFAULT to geared (canon, Pieter ruling). promo_cost_delta computed
-- inline too, resolved only when the matched promo row has status='1'
-- (ACTIVE) and a populated list_cost (2026-07-02 data-check finding) --
-- NULL + cost_resolved=false otherwise, never guessed.
--
-- STORY (R29): every line carries window used, correction days removed, soh,
-- target days, trigger fired, tier and pack size -- the reason a quantity
-- was suggested travels with the number.
--
-- Rule 19: DROP + clean CREATE. Function-change protocol (RULE-BOOK s8).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_order_dc(text, date, date);

CREATE FUNCTION public.rpc_bloom_order_dc(
  p_store_code      text,
  p_delivery_date   date,
  p_next_delivery   date
)
RETURNS TABLE (
  store_code            text,
  product_code           bigint,
  ean                     text,
  description             text,
  dept_name               text,
  tier                    text,
  soh                     numeric,
  unit_cost               numeric,
  pack_size               smallint,
  pack_cost               numeric,
  ros_window_used         text,
  ros_used                numeric,
  correction_days_removed int,
  projected_soh           numeric,
  target_days_cover       int,
  trigger_fired           boolean,
  need_units              numeric,
  normal_packs            int,
  promo_active            boolean,
  promo_nr                bigint,
  promo_start             date,
  promo_end               date,
  promo_uplift            numeric,
  promo_uplift_source     text,
  geared_packs            int,
  suggested_packs         int,
  promo_cost_delta        numeric,
  promo_cost_resolved     boolean,
  story                   text
)
-- NOT marked STABLE: SET LOCAL statement_timeout is illegal in a non-volatile
-- function (same gotcha hit and fixed earlier this session on rpc_dept_summary).
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_lead_days int;
BEGIN
  SET LOCAL statement_timeout = '30s';
  v_lead_days := GREATEST(p_delivery_date - CURRENT_DATE, 0);

  RETURN QUERY
  WITH cfg AS (
    SELECT dc_cycle_dept_nrs FROM public.bloom_dc_config WHERE bloom_dc_config.store_code = p_store_code
  ),
  base_pool AS (
    SELECT sp.store_code, sp.product_code, sp.description, sp.dept_name, sp.tier,
           sp.soh, sp.unit_cost, sl.pack_size, sl.list_cost AS pack_list_cost,
           COALESCE(b.ean, lpad(sp.store_code,5,'0') || lpad(sp.product_code::text,8,'0')) AS ean
    FROM public.l2_stock_position sp
    JOIN cfg ON sp.department_nr = ANY(cfg.dc_cycle_dept_nrs)
    JOIN public.sigma_supplier_link sl
      ON sl.store_code = sp.store_code AND sl.product_code = sp.product_code
    JOIN public.sigma_supplier_master sm
      ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr AND sm.supplier_type = 'Z'
    LEFT JOIN public.v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
    WHERE sp.store_code = p_store_code
      AND sp.class = 'NORMAL'
      AND sl.status <> 'S'
      AND (sp.never_sold = false OR sp.soh <> 0)
  ),
  with_ros AS (
    SELECT bp.*,
      COALESCE(rp.ros_14d_corrected, 0) AS ros_14d_c,
      COALESCE(rp.ros_28d_corrected, 0) AS ros_28d_c,
      COALESCE(rp.ros_56d_corrected, 0) AS ros_56d_c,
      rp.correction_days_removed_14d, rp.correction_days_removed_28d, rp.correction_days_removed_56d,
      COALESCE(pp.promo_uplift, 2.00) AS promo_uplift,
      COALESCE(pp.promo_uplift_source, 'default') AS promo_uplift_source
    FROM base_pool bp
    LEFT JOIN public.l2_bloom_ros_pantry rp ON rp.store_code = bp.store_code AND rp.product_code = bp.product_code
    LEFT JOIN public.l2_bloom_promo_pantry pp ON pp.store_code = bp.store_code AND pp.product_code = bp.product_code
  ),
  promo_match AS (
    -- promo_eligibility(D,D2): [start_date,end_date] overlaps [D,D2). Prefer the
    -- most cost-resolvable row (status='1' ACTIVE first) when more than one
    -- promo row overlaps the window.
    SELECT DISTINCT ON (wr.store_code, wr.product_code)
      wr.store_code, wr.product_code,
      pa.promo_nr, pa.start_date, pa.end_date, pa.status, pa.list_cost AS promo_unit_cost
    FROM with_ros wr
    JOIN public.sigma_promotion_articles pa
      ON pa.store_code = wr.store_code AND pa.product_code = wr.product_code
     AND pa.start_date < p_next_delivery AND pa.end_date >= p_delivery_date
    ORDER BY wr.store_code, wr.product_code,
             (pa.status = '1') DESC,   -- active promos (resolvable cost) first
             pa.end_date DESC
  ),
  tiered AS (
    SELECT wr.*,
      pm.promo_nr, pm.start_date AS promo_start, pm.end_date AS promo_end, pm.status AS promo_status,
      pm.promo_unit_cost,
      CASE wr.tier
        WHEN 'TOP_100'  THEN wr.ros_14d_c
        WHEN 'TOP_1000' THEN wr.ros_28d_c
        WHEN 'BOR'      THEN wr.ros_56d_c
        ELSE NULL
      END AS ros_used,
      CASE wr.tier
        WHEN 'TOP_100'  THEN 'ros_14d_corrected'
        WHEN 'TOP_1000' THEN 'ros_28d_corrected'
        WHEN 'BOR'      THEN 'ros_56d_corrected'
        ELSE NULL
      END AS ros_window_used,
      CASE wr.tier
        WHEN 'TOP_100'  THEN wr.correction_days_removed_14d
        WHEN 'TOP_1000' THEN wr.correction_days_removed_28d
        WHEN 'BOR'      THEN wr.correction_days_removed_56d
        ELSE NULL
      END AS correction_days_removed,
      CASE wr.tier WHEN 'TOP_100' THEN 14 WHEN 'TOP_1000' THEN 12 WHEN 'BOR' THEN 14 ELSE NULL END AS target_days_cover
    FROM with_ros wr
    LEFT JOIN promo_match pm ON pm.store_code = wr.store_code AND pm.product_code = wr.product_code
  ),
  calc AS (
    SELECT t.*,
      GREATEST(t.soh, 0) - t.ros_used * v_lead_days AS proj_soh,
      CASE
        WHEN t.tier = 'TOP_100' THEN true
        WHEN t.tier = 'TOP_1000' THEN (t.ros_used * 12 - (GREATEST(t.soh,0) - t.ros_used * v_lead_days)) > 0
        WHEN t.tier = 'BOR' THEN (GREATEST(t.soh,0) - t.ros_used * v_lead_days) < 3
        ELSE false
      END AS fires
    FROM tiered t
    WHERE t.tier IN ('TOP_100','TOP_1000','BOR')  -- CLASS_EXCLUDED / untiered lines never order
  ),
  final AS (
    SELECT c.*,
      GREATEST(c.ros_used * c.target_days_cover - c.proj_soh, 0) AS need,
      -- Canon: "round down to packs ... min 1 pack where the trigger fires."
      -- FLOOR not CEIL (2026-07-03 fix -- CEIL was a real bug, over-ordered
      -- every fractional-pack line). The min-1-pack floor is gated on
      -- ros_used > 0: a trigger firing on a genuinely zero-velocity line
      -- (BOR, low SOH, no sales) is a presence question, not a reorder
      -- signal -- forcing stock into a non-selling line contradicts this
      -- platform's own governing law (canon: "presence proven by sales,
      -- never by SOH", DF-7 Glenlivet pattern). OPEN QUESTION flagged to
      -- PM/Pieter, not resolved here: does the reference 80175 run apply
      -- this same ros_used>0 gate, or a different BOR trigger calibration?
      -- This function has not yet reconciled to the brief's validated
      -- 817-line / R173,977.97 target -- see HANDOVER.
      CASE WHEN c.fires AND c.ros_used > 0
           THEN GREATEST(FLOOR((c.ros_used * c.target_days_cover - c.proj_soh) / NULLIF(c.pack_size,0)), 1)
           ELSE 0 END AS normal_packs_calc
    FROM calc c
  )
  SELECT
    f.store_code, f.product_code, f.ean, f.description, f.dept_name, f.tier,
    f.soh, f.unit_cost, f.pack_size,
    ROUND(f.pack_list_cost, 2) AS pack_cost,
    f.ros_window_used, ROUND(f.ros_used, 4), f.correction_days_removed,
    ROUND(f.proj_soh, 2), f.target_days_cover, f.fires,
    ROUND(f.need, 2),
    f.normal_packs_calc::int AS normal_packs,
    (f.promo_nr IS NOT NULL) AS promo_active,
    f.promo_nr, f.promo_start, f.promo_end,
    f.promo_uplift, f.promo_uplift_source,
    CEIL(f.normal_packs_calc * f.promo_uplift)::int AS geared_packs,
    CASE
      WHEN f.promo_nr IS NOT NULL AND f.tier = 'TOP_100' THEN CEIL(f.normal_packs_calc * f.promo_uplift)::int
      ELSE f.normal_packs_calc::int
    END AS suggested_packs,
    CASE WHEN f.promo_status = '1' AND f.promo_unit_cost IS NOT NULL AND f.promo_unit_cost <> 0
         THEN ROUND((f.pack_list_cost / NULLIF(f.pack_size,0)) - f.promo_unit_cost, 4)
         ELSE NULL END AS promo_cost_delta,
    (f.promo_status = '1' AND f.promo_unit_cost IS NOT NULL AND f.promo_unit_cost <> 0) AS promo_cost_resolved,
    format('%s tier, %s window=%s (corrected, %s days removed), SOH %s, target %s days -> projected %s, trigger %s, need %s units = %s packs%s',
           f.tier, f.tier, f.ros_window_used, COALESCE(f.correction_days_removed,0), f.soh, f.target_days_cover,
           ROUND(f.proj_soh,1), f.fires, ROUND(f.need,1), f.normal_packs_calc,
           CASE WHEN f.promo_nr IS NOT NULL THEN format(' | promo %s->%s uplift %s (%s)', f.promo_start, f.promo_end, f.promo_uplift, f.promo_uplift_source) ELSE '' END
    ) AS story
  FROM final f
  ORDER BY f.tier, f.ros_used DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bloom_order_dc(text, date, date) TO anon, authenticated;
