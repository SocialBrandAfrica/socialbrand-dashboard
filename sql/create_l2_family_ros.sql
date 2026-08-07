-- =============================================================================
-- create_l2_family_ros.sql
-- BUG-LOG ENG-073 / SB-CC-BLOOM-020 item 1 -- THE FAMILY-RESOLVED DISPLAY RATE.
-- Canonical source. Deployed 2026-08-07 via Supabase MCP migration
--   eng073_l2_family_ros.
-- =============================================================================
-- THE DEFECT. ENG-005 closed for the RECIPE on 2026-07-10 and never for the
--   DISPLAY. `l2_stock_position.daily_ros` is keyed on the till SCAN CODE, and
--   `mv_rate_of_sale`, Top 20 cover, product detail and days cover all read it.
--   On a parent-child family the pack code sells but holds no stock, so its draw
--   never reaches the code that does -- and the shelf reads full when it is empty.
--
--   Measured live 2026-08-07 at 10116 on SPAR MILK L/L F/CREAM (1674 + 18919_6),
--   a KVI_CRITICAL line: scan `daily_ros` 30.45/day and days_cover 3.42, against
--   a family rate of 437.20/day and a true family cover of 0.24 days.
--   THE DISPLAY OVERSTATES COVER BY 14.4x. A manager reading 3.4 days of cover
--   on his fastest line does not reorder it. THE ORDER ITSELF IS SAFE -- the
--   recipe is already family-resolved. Only the display lies.
--
-- WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT.
--   It is ONE named pantry fact per (store, product) carrying the family-resolved
--   rate BESIDE the raw scan rate -- R27 SS2, every variant its own named field,
--   no consumer silently switches. It is NOT a change to any existing object:
--   `l2_stock_position` is untouched, so its 31 dependents (canon SS13: 7
--   CASCADE-class + 24 read-only) neither move nor need rebuilding, and no
--   number on any live surface changes until a consumer is repointed on its own
--   pass with its own R22.
--
-- ASSEMBLED, NOT REINVENTED (canon v10's discipline; R21).
--   The family and its multiplier come from `l2_product_resolution` -- the
--   engine's own deterministic resolution, `rank_band = B_DB_DECIDES`, built to
--   canon SS17's item-12 ruling. `family_key` is `merch_group|pack_content|
--   description-root`, which IS canon's parent-child matching rule (same merch
--   group, same pack_content content-guard, same description root).
--   ⭐ THIS IS THE FIRST CONSUMER `l2_product_resolution` HAS EVER HAD. DB-SCHEMA
--   records it as 9,812 rows with "NO READER ... that is the SS0i PROSE state".
--   This wires it.
--
-- ⚠️ DO NOT USE `sigma_supplier_link.pack_size` AS THE RETAIL MULTIPLE. Verified
--   live on this very family: it reads 6 on the LOOSE code 1674 and 1 on the
--   PACK code 18919 -- the inverse of the retail multiple, because it is the
--   SUPPLIER case quantity. Using it would multiply the wrong code by six.
--   SIGMA-CLEANUP-WORKFLOW already warns this; the trap is real and it is
--   inverted, not merely absent. `l2_product_resolution.pack_multiple` is the
--   source of record.
--
-- THE WINDOW IS THE DISPLAY'S OWN, ON PURPOSE. `daily_ros_91d` is
--   `sales_qty_91d / 91.0` -- CALENDAR days, verified live against both
--   `l2_rate_of_sale` and `l2_stock_position` (30.450549 three ways on 1674).
--   This fact uses the SAME divisor, so the ONLY variable that changes between
--   the old figure and the new one is family resolution. Anything else would
--   make the R22 unreadable. (The ordering pantry's `ros_draw_*` are 14/28/56-day
--   ORDERING windows and are a different question -- they are not display rates.)
--
-- THE ACCEPTANCE GATE IS EXTERNAL, per the brief -- Sigma's own Product
--   Statistics screen ("Parent Selling Unit incl. Child Selling Units"), not an
--   internal assertion. `family_singles = loose_qty + (pack_size x pack_qty)`
--   reproduced against it at 10116 / 1674+18919, 30 Jul to 5 Aug 2026:
--     31 Jul 18 vs 18 - 01 Aug 855 vs 856 - 02 Aug 474 vs 474 - 03 Aug 685 vs 691
--     04 Aug 1,079 vs 1,079 - 05 Aug 504 vs 504   (5 of 7 exact, 2 inside a pack)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_family_ros (
  client_id              text        NOT NULL,
  store_code             text        NOT NULL,
  product_code           bigint      NOT NULL,

  family_key             text        NOT NULL,
  level                  text,
  pack_multiple          numeric     NOT NULL,
  -- THREE-WAY ON PURPOSE. TRUE = the tracked code the family holds stock on
  -- (canon s14 v5). FALSE = a zero-deplete pack/case code. NULL = Sigma's
  -- record_stock_qty was never captured for this line, so the holder is UNKNOWN
  -- and is not asserted either way (canon s11: NULL falls through to the
  -- heuristic, it does NOT mean non-stock). The first build had this NOT NULL
  -- and the insert failed on 7 real lines group-wide -- the constraint stopped a
  -- false "holds no stock" from landing on lines nobody has measured. Same
  -- discipline as l2_product_resolution.cost_error, NULL because NOT TESTED.
  is_stock_holder        boolean,
  family_member_count    int         NOT NULL,

  -- RAW, kept beside the resolved value for audit (R27 SS2). This is exactly
  -- what l2_stock_position.daily_ros carries today.
  scan_qty_91d           numeric,
  scan_daily_ros_91d     numeric,

  -- FAMILY-RESOLVED, in SINGLES, same 91-calendar-day divisor.
  family_singles_91d     numeric,
  family_daily_ros_91d   numeric,
  family_soh_singles     numeric,
  family_days_cover      numeric,

  -- How wrong the scan-code figure was on this line.
  family_ratio           numeric,

  resolution_confidence  numeric,
  story                  text        NOT NULL,
  engine_version         text        NOT NULL,
  computed_at            timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (client_id, store_code, product_code)
);

-- store_code-leading so a two-key read does not hit the client_id-leading trap
-- that canon SS17 names on l2_stock_position / l2_rate_of_sale, and that ENG-074
-- proved was costing ~4,665 per probe on a live dashboard object.
CREATE INDEX IF NOT EXISTS idx_l2_family_ros_store_product
  ON public.l2_family_ros (store_code, product_code);
CREATE INDEX IF NOT EXISTS idx_l2_family_ros_family
  ON public.l2_family_ros (store_code, family_key);

ALTER TABLE public.l2_family_ros ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_family_ros_read ON public.l2_family_ros;
CREATE POLICY l2_family_ros_read ON public.l2_family_ros FOR SELECT USING (true);
GRANT SELECT ON public.l2_family_ros TO anon, authenticated;

COMMENT ON TABLE public.l2_family_ros IS
  'ENG-073 / BLOOM-020 item 1. Family-resolved display rate per (store, product), '
  'in singles, on the display''s own 91-calendar-day divisor, with the raw scan '
  'rate kept beside it (R27 s2). Family and multiplier come from '
  'l2_product_resolution (B_DB_DECIDES). Consumers repoint one at a time.';


CREATE OR REPLACE FUNCTION public.refresh_l2_family_ros(p_store text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_version text := 'ENG-073 family-resolved display rate v1.1';
  v_rows    int;
  v_fams    int;
BEGIN
  SET LOCAL statement_timeout = '120s';

  DELETE FROM l2_family_ros WHERE store_code = p_store;

  WITH members AS (
    -- The resolved family set. A row needs a family and a multiple to be
    -- resolvable at all; anything else is left OUT rather than guessed, and the
    -- summary below reports how many that was (R21 s5, exclusions surfaced).
    SELECT r.store_code, r.product_code, r.family_key, r.level,
           r.pack_multiple, r.confidence
    FROM l2_product_resolution r
    WHERE r.store_code = p_store
      AND r.family_key IS NOT NULL
      AND r.pack_multiple IS NOT NULL
      AND r.pack_multiple > 0
  ),
  facts AS (
    SELECT m.*,
           sp.client_id,
           sp.soh,
           -- record_stock_qty lives ONLY on sigma_articles (verified in the
           -- catalog, not assumed). Joined on BOTH keys -- sigma_articles is
           -- grained (store_code, product_code) and a single-key join fans out
           -- ~2.2x (RULE-BOOK s2).
           art.record_stock_qty,
           COALESCE(ros.sales_qty_91d, 0) AS scan_qty_91d,
           ros.daily_ros_91d              AS scan_daily_ros_91d
    FROM members m
    JOIN l2_stock_position sp
      ON sp.store_code = m.store_code AND sp.product_code = m.product_code
    JOIN sigma_articles art
      ON art.store_code = m.store_code AND art.product_code = m.product_code
    LEFT JOIN l2_rate_of_sale ros
      ON ros.client_id = sp.client_id AND ros.store_code = m.store_code
     AND ros.product_code = m.product_code
  ),
  fam AS (
    SELECT store_code, family_key,
           SUM(scan_qty_91d * pack_multiple) AS family_singles_91d,
           SUM(soh          * pack_multiple) AS family_soh_singles,
           COUNT(*)                          AS family_member_count
    FROM facts
    GROUP BY store_code, family_key
  )
  INSERT INTO l2_family_ros (
    client_id, store_code, product_code, family_key, level, pack_multiple,
    is_stock_holder, family_member_count, scan_qty_91d, scan_daily_ros_91d,
    family_singles_91d, family_daily_ros_91d, family_soh_singles,
    family_days_cover, family_ratio, resolution_confidence, story,
    engine_version, computed_at)
  SELECT
    f.client_id, f.store_code, f.product_code, f.family_key, f.level,
    f.pack_multiple,
    -- Canon s14 v5: the family holds stock on the TRACKED code. Three-way --
    -- an uncaptured flag is UNKNOWN, never an asserted false.
    CASE WHEN f.record_stock_qty IS NULL THEN NULL ELSE (f.record_stock_qty = 1) END,
    fa.family_member_count,
    f.scan_qty_91d,
    f.scan_daily_ros_91d,
    fa.family_singles_91d,
    ROUND(fa.family_singles_91d / 91.0, 6),
    fa.family_soh_singles,
    -- Days cover is UNDEFINED at a zero rate, never infinity and never a zero
    -- masquerading as one (RULE-BOOK s2: show a dash).
    CASE WHEN fa.family_singles_91d > 0
         THEN ROUND(fa.family_soh_singles / (fa.family_singles_91d / 91.0), 4) END,
    CASE WHEN COALESCE(f.scan_daily_ros_91d, 0) > 0
         THEN ROUND((fa.family_singles_91d / 91.0) / f.scan_daily_ros_91d, 4) END,
    f.confidence,
    'family ' || f.family_key || ': ' || fa.family_member_count || ' codes; this code '
      || COALESCE(f.level,'?') || ' x' || f.pack_multiple
      || '; family sold ' || ROUND(fa.family_singles_91d,0) || ' singles/91d = '
      || ROUND(fa.family_singles_91d / 91.0, 2) || '/day against this code''s own '
      || COALESCE(ROUND(f.scan_daily_ros_91d,2)::text,'no rate')
      || CASE WHEN f.record_stock_qty IS NULL THEN '; stock-tracking flag not captured, holder unknown'
              WHEN f.record_stock_qty = 1    THEN '; holds the family stock'
              ELSE '; holds no stock, family stock sits elsewhere' END,
    v_version,
    now()
  FROM facts f
  JOIN fam fa ON fa.store_code = f.store_code AND fa.family_key = f.family_key;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT COUNT(DISTINCT family_key) INTO v_fams FROM l2_family_ros WHERE store_code = p_store;

  -- No silent empties (canon s8.6 guard 4).
  RETURN jsonb_build_object(
    'store_code', p_store,
    'rows',       v_rows,
    'families',   v_fams,
    -- Surfaced, never swallowed (R21 s5): how many lines could not say who holds
    -- the stock, and how many families have NO holder at all -- the second is the
    -- BLOOM-020 item 2 population (a zero-deplete code holding stock).
    'stock_holder_unknown',
      (SELECT COUNT(*) FROM l2_family_ros WHERE store_code = p_store AND is_stock_holder IS NULL),
    'families_with_no_holder',
      (SELECT COUNT(*) FROM (
         SELECT family_key FROM l2_family_ros WHERE store_code = p_store
         GROUP BY family_key HAVING bool_or(COALESCE(is_stock_holder,false)) = false) z),
    'unresolved_in_resolution_table',
      (SELECT COUNT(*) FROM l2_product_resolution r
        WHERE r.store_code = p_store
          AND (r.family_key IS NULL OR r.pack_multiple IS NULL)),
    'engine_version', v_version,
    'computed_at', now());
END
$function$;

-- Mutating function: R30 addendum extension -- PUBLIC and anon BOTH revoked, and
-- the proof is a privilege check after create, never a memory.
REVOKE ALL ON FUNCTION public.refresh_l2_family_ros(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_l2_family_ros(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.refresh_l2_family_ros(text) TO authenticated;
