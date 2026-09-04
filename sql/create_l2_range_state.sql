-- =============================================================================
-- create_l2_range_state.sql
-- SB-CC-BLOOM-008 item 1 (v10 W27) -- THE RANGE STATE FACT.
--
-- Pieter's range taxonomy (WALK-FINDINGS W27), the per-line state that
-- drives the order action:
--   HERO     -- the 3-5 lines that carry each category (l2_bt_heroes),
--               best position, first call, ordered to MAX, never empty,
--               always in the KVI-focused scenarios.
--   CORE     -- the balance of the selling range before the tail.
--   SLOW     -- 1-2 sales in the quarter, stays listed, NO depth, watched
--               not fed.
--   MARKDOWN -- dead a quarter AND physically counted (stock is real) --
--               mark down to money and space, do not order.
--   DERANGE  -- dead with nothing on the floor (no count confirms it) --
--               delist so it cannot be reordered out of habit.
--   VERIFY   -- dead, ledger claims stock, not counted recently -- count
--               first, never order until reactivated.
--
-- REUSE, DO NOT REINVENT (v10's own instruction): every signal below
-- already exists.
--   HERO            <- l2_bt_heroes (top-5-by-91d-GP per store/merch_group,
--                      ~60 lines/12 categories, live).
--   CORE            <- l2_kvi_profile.passes_life_gate = true (canon s14
--                      addendum v3 life gate: bucket not in DEAD_ZERO/
--                      PHANTOM_ZERO/COST_ERROR/NON_STOCK, >=1 sale 56d,
--                      >=3 distinct selling days 91d).
--   VERIFY          <- l2_classification bucket = PHANTOM_ZERO (cascade s8.5
--                      line 5: real barcode, NOT sold 365d, NOT counted
--                      91d -- "dead, ledger claims stock, not counted
--                      recently" is that bucket's own definition, verbatim).
--   DERANGE         <- l2_classification bucket = DEAD_ZERO (cascade line 1:
--                      no movement of ANY type in 365d, including no
--                      count -- "nothing on the floor" is the strongest
--                      possible reading of that bucket).
--   MARKDOWN        <- l2_classification bucket = LEAVE_COUNTED. By cascade
--                      construction (s8.5) a line only reaches step 4
--                      (counted_91) after failing sold_91 (step 2) and both
--                      commercial directions (step 3) -- so LEAVE_COUNTED
--                      lines are, by construction, dead in the trailing
--                      quarter AND recently physically counted. Exact match
--                      to W27's own wording.
--   SLOW            <- the catch-all: fails the life gate, is not HERO, and
--                      is none of the three dead-bucket reads above (an
--                      active COUNT/AMBIGUOUS/HEALTHY bucket, or genuinely
--                      no l2_classification row because SOH sits at 0 and
--                      the cleanup cascade's own scope never reached it) --
--                      "some recent life, below the life-gate bar."
--
-- EXCLUDED (not one of the six states -- named, not silently folded into
--   SLOW): l2_classification bucket IN (NON_STOCK, COST_ERROR, SOURCE_FIX,
--   DEPOSIT). These are accounting lines, pack-cost errors, production/BOM
--   items and deposit float that occasionally carry an active DC/direct
--   supplier link (verified live: 5 such lines in the 10116/DC_AMBIENT pool)
--   -- never orderable stock, never one of the six range states. The
--   recipe excludes them from every scenario outright.
--
-- SCOPE: l2_kvi_profile's own pool (l2_stock_position class='NORMAL' at the
-- store, no value floor -- canon s8.2). This is WIDER than l2_classification's
-- own scope (which additionally requires soh<>0) -- a SOH-0 line still needs
-- a range state (it may need reordering), it just won't have a
-- l2_classification row, and falls through to SLOW/CORE by the life gate
-- alone, never silently dropped (R21 s5).
--
-- FROZEN FOCUS (named debt, R21 s5/R23 -- NOT built this pass): W27 names a
-- second HERO-class input, "the perishable/frozen version of the heroes,
-- same concept" -- BLOOM-008 item 8 (deferred). frozen_focus_pending=true
-- is carried on every row as the named gap; no line is currently promoted
-- to HERO via this route. When item 8 lands, this column flips the
-- affected rows without touching the rest of the cascade.
--
-- ARCHITECTURE: same proven pattern as l2_kvi_profile/l2_classification --
-- persistent TABLE, refresh_<name>(p_store) per-store function, idempotent
-- (DELETE store rows + re-INSERT).
--
-- R22 (verified live, 10116/DC_AMBIENT orderable pool, 2026-07-12): HERO 42
-- + CORE 5,071 (176 KVI-band lines across HERO+CORE) + SLOW 7,456 (7,375
-- LONG_TAIL) + DERANGE 42 + VERIFY 30 + MARKDOWN 11 + EXCLUDED 5 = 12,657.
-- Reconciles to the brief's own reference table (KVI 178/Core 4,981/Tail
-- 7,456) to within live drift.
-- =============================================================================

DROP TABLE IF EXISTS public.l2_range_state CASCADE;

CREATE TABLE public.l2_range_state (
  client_id            text NOT NULL DEFAULT 'socialbrand',
  store_code           text NOT NULL,
  product_code         bigint NOT NULL,
  range_state          text NOT NULL,   -- HERO|CORE|SLOW|MARKDOWN|DERANGE|VERIFY|EXCLUDED
  state_reason         text NOT NULL,
  is_bt_hero           boolean NOT NULL DEFAULT false,
  bt_merch_group_nr    int,
  bt_label             text,
  frozen_focus_pending boolean NOT NULL DEFAULT false,
  passes_life_gate     boolean NOT NULL DEFAULT false,
  classification_bucket text,
  engine_version       text NOT NULL DEFAULT 'v1.0',
  profiled_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, product_code)
);

CREATE INDEX idx_l2_range_state_state ON public.l2_range_state (store_code, range_state);

REVOKE ALL ON public.l2_range_state FROM PUBLIC;
GRANT SELECT ON public.l2_range_state TO anon, authenticated;

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_l2_range_state(p_store text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_rows int;
  v_summary jsonb;
BEGIN
  DELETE FROM public.l2_range_state WHERE store_code = p_store;

  WITH k AS (
    SELECT product_code, passes_life_gate, kvi_band
    FROM public.l2_kvi_profile WHERE store_code = p_store
  ),
  hero AS (
    SELECT DISTINCT ON (product_code) product_code, merch_group_nr, label
    FROM public.l2_bt_heroes WHERE store_code = p_store
    ORDER BY product_code, rn
  ),
  lc AS (
    SELECT DISTINCT ON (product_code) product_code, bucket
    FROM public.l2_classification WHERE store_code = p_store
    ORDER BY product_code, snapshot_date DESC
  ),
  states AS (
    SELECT
      k.product_code, k.passes_life_gate, lc.bucket,
      (hero.product_code IS NOT NULL) AS is_hero, hero.merch_group_nr, hero.label,
      CASE
        WHEN hero.product_code IS NOT NULL THEN 'HERO'
        WHEN COALESCE(lc.bucket,'') IN ('NON_STOCK','COST_ERROR','SOURCE_FIX','DEPOSIT') THEN 'EXCLUDED'
        WHEN k.passes_life_gate THEN 'CORE'
        WHEN lc.bucket = 'PHANTOM_ZERO' THEN 'VERIFY'
        WHEN lc.bucket = 'DEAD_ZERO' THEN 'DERANGE'
        WHEN lc.bucket = 'LEAVE_COUNTED' THEN 'MARKDOWN'
        ELSE 'SLOW'
      END AS range_state
    FROM k
    LEFT JOIN hero ON hero.product_code = k.product_code
    LEFT JOIN lc ON lc.product_code = k.product_code
  )
  INSERT INTO public.l2_range_state (
    client_id, store_code, product_code, range_state, state_reason,
    is_bt_hero, bt_merch_group_nr, bt_label, frozen_focus_pending,
    passes_life_gate, classification_bucket, engine_version, profiled_at
  )
  SELECT
    'socialbrand', p_store, s.product_code, s.range_state,
    CASE s.range_state
      WHEN 'HERO' THEN 'l2_bt_heroes: top GP line in its category, ordered to max, never empty'
      WHEN 'EXCLUDED' THEN 'l2_classification bucket=' || s.bucket || ': not orderable stock (accounting/cost-error/production/deposit)'
      WHEN 'CORE' THEN 'passes_life_gate: selling range'
      WHEN 'VERIFY' THEN 'l2_classification PHANTOM_ZERO: dead, ledger claims stock, not counted 91d -- count first, never order until reactivated'
      WHEN 'DERANGE' THEN 'l2_classification DEAD_ZERO: no movement any type 365d -- nothing on the floor, delist candidate'
      WHEN 'MARKDOWN' THEN 'l2_classification LEAVE_COUNTED: dead a quarter, recently physically counted -- mark down, do not order'
      ELSE 'below life-gate threshold, some recent activity -- watched not fed, no depth'
    END,
    s.is_hero, s.merch_group_nr, s.label, false,
    s.passes_life_gate, s.bucket, 'v1.0', now()
  FROM states s;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  SELECT jsonb_object_agg(range_state, cnt) INTO v_summary
  FROM (
    SELECT range_state, count(*) AS cnt
    FROM public.l2_range_state WHERE store_code = p_store
    GROUP BY range_state
  ) t;

  RETURN jsonb_build_object('store_code', p_store, 'rows', v_rows, 'by_state', v_summary);
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_l2_range_state(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_l2_range_state(text) TO authenticated;

-- ENG-172 / SB-CC-GROUND-001 leg 1: the grade travels with the object (ENGINE-CANON-LAYERS §L4).
COMMENT ON TABLE public.l2_range_state IS
    'GRADE: VERDICT. The per-line range state. HERO, CORE, SLOW, MARKDOWN, DERANGE, VERIFY or EXCLUDED, with state_reason.';
