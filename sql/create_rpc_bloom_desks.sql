-- =====================================================================
-- rpc_bloom_desks + supplier_calendar.display_label / desk_sort
-- THE DESK LIST BECOMES CONFIG, NOT A HARDCODED MAP.
--
-- Ref:      SB-CC-BLOOM /bloom general fix (ENG-088 generalisation)
-- Date:     2026-08-19
-- Owner:    Claude Code
-- Canon:    R21 (behaviour/config, never a name or a list) · R25 SS4
--           (config-only onboarding) · R32 SS4 (the rollout test) ·
--           ORDERING-CANON SSA1/SSA4/SSA5 · FILE-GOVERNANCE SS0g
--           (write-forward: one fact, one home) · SS0h (the config-key gate)
--
-- WHY THIS EXISTS
-- src/app/bloom/page.jsx carried STORE_DESKS, DESK_STORES and TOPS_STORES --
-- literal store and desk lists in code. That fails the store-#6 test: a new
-- store or a new desk needed a code change and a deploy. The same literal
-- problem sat in refresh_bloom_order_cache_all, whose p_routes default
-- ARRAY['DC_AMBIENT','DC_TOPS'] was the only thing deciding which desks got a
-- precomputed order -- which is why 15 of 20 desks still ran the live recipe and
-- died at the 30s role statement_timeout.
--
-- THE DISCOVERY RULE, PROVEN ZERO-DELTA BEFORE ADOPTION
-- A desk exists where the store has a supplier_calendar ROW for that route.
-- Reconciled against the hardcoded map at source, 2026-08-19, all five stores:
--   10116 7=7 · 80175 7=7 · 21355 3=3 · 80176 2=2 · 80579 1=1   -- exact,
-- same labels, same buyer-priority order.
--
-- WHY THE CALENDAR AND NOT bloom_route_config: 80579 carries a RULED
-- DIRECT_BEER row in bloom_route_config but NO supplier_calendar row, and
-- ORDERING-CANON SSA1 says that desk is deliberately absent (80579 is IBT-fed
-- and has no SAB receipts of its own). Keying on the calendar reproduces that
-- intended omission; keying on route_config would have resurrected a desk canon
-- says must not exist. A desk needs delivery days before it can order at all.
--
-- is_dc DERIVES FROM CONFIG PRESENCE, NEVER FROM THE route_key STRING.
-- route_key is an opaque join key and canon SSA5 item 7j forbids reading meaning
-- out of a name. A route WITH a bloom_route_config row is direct/dropship; one
-- WITHOUT is a DC desk. Verified true on all 20 live desks.
-- =====================================================================

-- ---------- SS0h THE CONFIG-KEY GATE ----------
-- The values MOVE to config; they are never merely deleted from the frontend.
-- display_label carries the human name the hardcoded map held. desk_sort carries
-- the BUYER-PRIORITY ordering (SB-CC-BLOOM-009 item 6: DC first, then direct
-- desks by weekly rand) which plain alphabetical order would have silently
-- destroyed -- that ordering is information, not decoration.
ALTER TABLE public.supplier_calendar
  ADD COLUMN IF NOT EXISTS display_label text,
  ADD COLUMN IF NOT EXISTS desk_sort      smallint;

COMMENT ON COLUMN public.supplier_calendar.display_label IS
  'Human desk name shown on /bloom. Carved from the hardcoded STORE_DESKS map 2026-08-19 (SS0h: the value moves to config). NULL is legal -- rpc_bloom_desks derives a readable fallback, so a store-#6 route is usable the moment its calendar row exists.';
COMMENT ON COLUMN public.supplier_calendar.desk_sort IS
  'Desk display order, low first. Carries SB-CC-BLOOM-009 item 6 buyer priority (DC first, then direct desks by weekly rand). NULL sorts last, alphabetically.';

-- Seeded from the labels the frontend held, so nothing the buyer sees changes.
UPDATE public.supplier_calendar sc
   SET display_label = m.label,
       desk_sort     = m.sort
  FROM (VALUES
      ('DC_AMBIENT',        'SPAR DC Ambient',        0::smallint),
      ('DC_TOPS',           'TOPS DC',                0::smallint),
      ('DIRECT_BEER',       'SAB Direct',             1::smallint),
      ('DIRECT_COCACOLA',   'Coca-Cola Direct',       2::smallint),
      ('DIRECT_CLOVER',     'Clover Direct',          3::smallint),
      ('DIRECT_SIMBA',      'Simba Direct',           4::smallint),
      ('DIRECT_DANONE',     'Danone Direct',          5::smallint),
      ('DIRECT_NATBRANDS',  'National Brands Direct', 6::smallint),
      ('DIRECT_MONDELEZ',   'Mondelez Direct',        7::smallint)
  ) AS m(route_key, label, sort)
 WHERE sc.route_key = m.route_key
   AND sc.display_label IS DISTINCT FROM m.label;

-- ---------- the one home for "which desks exist" ----------
-- Read by the /bloom desk picker AND by refresh_bloom_order_cache_all, so the
-- screen and the nightly builder can never disagree about the desk set
-- (SS0g write-forward: one fact, one home).
CREATE OR REPLACE FUNCTION public.rpc_bloom_desks(p_store_code text DEFAULT NULL)
RETURNS TABLE (
  store_code           text,
  store_name           text,
  route_key            text,
  display_label        text,
  is_dc                boolean,
  delivery_dows        smallint[],
  order_cutoff_days    smallint,
  cycle_weeks          smallint,
  desk_sort            smallint
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT
    sc.store_code,
    st.store_name,
    sc.route_key,
    COALESCE(
      sc.display_label,
      -- Readable fallback so an UNLABELLED route (store #6, a desk seeded
      -- tonight) is usable immediately instead of rendering a raw key.
      -- Cosmetic only: nothing branches on it.
      CASE
        WHEN rc.route_key IS NULL
          THEN initcap(replace(regexp_replace(sc.route_key, '^DC_?', ''), '_', ' ')) || ' DC'
        ELSE initcap(replace(regexp_replace(sc.route_key, '^DIRECT_?', ''), '_', ' ')) || ' Direct'
      END
    )                                            AS display_label,
    (rc.route_key IS NULL)                       AS is_dc,
    sc.delivery_dows,
    sc.order_cutoff_days,
    sc.cycle_weeks,
    sc.desk_sort
  FROM public.supplier_calendar sc
  JOIN public.stores st
    ON st.store_code = sc.store_code
   AND st.is_active
  LEFT JOIN public.bloom_route_config rc
    ON rc.store_code = sc.store_code
   AND rc.route_key  = sc.route_key
  WHERE p_store_code IS NULL OR sc.store_code = p_store_code
  ORDER BY sc.store_code,
           COALESCE(sc.desk_sort, 32767),
           sc.route_key;
$fn$;

COMMENT ON FUNCTION public.rpc_bloom_desks(text) IS
  'The desk set, discovered from config (supplier_calendar x stores.is_active), never a hardcoded list. A desk exists where a supplier_calendar row exists -- see this file for why the calendar and not bloom_route_config (the 80579 DIRECT_BEER case, ORDERING-CANON A1). is_dc derives from config presence, never from the route_key string (canon A5 7j). Consumers: the /bloom desk picker and refresh_bloom_order_cache_all.';

-- A READ rpc: anon-executable by design. The R30 addendum extension that demands
-- an explicit anon REVOKE is scoped to MUTATING functions; grants are stated
-- here explicitly either way, never assumed (a create_*.sql without its grants
-- is incomplete).
REVOKE ALL ON FUNCTION public.rpc_bloom_desks(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_desks(text) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
