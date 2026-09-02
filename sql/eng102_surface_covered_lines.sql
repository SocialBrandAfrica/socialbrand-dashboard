-- ENG-102 -- SURFACE THE COVERED LINES.
--
-- THE DEFECT. rpc_bloom_order_recipe computes every pool line in full and then
-- DELETEs the non-actionable ones from _bloom_recipe_out. A CORE or HERO line
-- sitting at or below its own min_band therefore leaves the order sheet with no
-- row and no reason, and the reason is usually a good one ("336 units landing
-- 2 Sept"). ORDERING-CANON B4 requires an unqualified line to stay surfaced
-- with its per-line reason, and 5(b2) rules that every pool line is a ROW.
-- Both are unenforced on the recipe's own DELETE. Same shape as ENG-155's Raja:
-- a correct answer the buyer cannot see, and an invisible correct answer is
-- indistinguishable from a wrong one.
--
-- THE MEASUREMENT BEHIND IT (CC, 2026-09-02, probe clone with both keep-gates
-- neutered, live function never touched, instrument gate passed at 550 rows /
-- R280,029.75 reproduced exactly). Of the discarded lines the separation is
-- decisive: needu <= 0 on 54 of 54, ros_final = 0 on NONE. The mechanism is the
-- in-transit leg lifting projected_soh above target_level, and the in-transit is
-- REAL -- all 54 latest open orders dated 2026-08-31 or 09-01, zero sentinels,
-- none over 30 days, all promising a GRV date of today or later.
--
-- Across all 20 desks: 33,811 discarded lines, ZERO of them carrying
-- need_units > 0. The discard arithmetic is sound estate-wide. What is wrong is
-- only that the reason is thrown away.
--
-- R22, all 20 desks, 2026-09-02, measured before this file was written:
--   rows   3,020 -> 3,489  (+469)
--   value  R1,466,857.16 -> R1,466,857.16   (identical to the cent)
--   packs  5,889 -> 5,889                   (identical)
--   added rows carrying quantity: 0    rows lost: 0
-- Quantity-neutral by construction: the new clause is OR'd onto the keep
-- condition, so it can only ADD rows, and a row it adds had suggested_packs = 0
-- or it would already have been kept.
--
-- NO NEW CONSTANT. The rule reads the line's OWN min_band, never a threshold,
-- so store #6 inherits it unchanged (FILE-GOVERNANCE s0h, R25). Per-desk yield
-- ranges 0 to 212 and two desks return zero, so it discriminates rather than
-- blankets.
--
-- THREE PARTS, ONE UNIT. Shipping the recipe change alone would inflate
-- ordered_line_count by 469 zero-quantity rows, which is the ENG-123 defect by
-- name: a display count naming the wrong population.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. line_kind gains 'covered'. It answers WHERE a row came from, exactly as
--    PROJECT-LEXICON defines it, and stays a third value rather than being
--    collapsed into 'hidden' -- a covered line is one the engine got RIGHT.
-- ---------------------------------------------------------------------------
ALTER TABLE public.bloom_order_cache_line
  DROP CONSTRAINT bloom_order_cache_line_kind_ck;

ALTER TABLE public.bloom_order_cache_line
  ADD CONSTRAINT bloom_order_cache_line_kind_ck
  CHECK (line_kind = ANY (ARRAY['ordered'::text, 'hidden'::text, 'covered'::text]));

-- ---------------------------------------------------------------------------
-- 2. The recipe RETAINS the covered lines instead of deleting them.
--    Patched by asserted replace off pg_get_functiondef rather than by
--    re-typing 44,251 characters. Both keep-gates are widened: the DELETE
--    carries the condition in negative form and the RETURN QUERY carries it
--    again in positive form.
-- ---------------------------------------------------------------------------
DO $eng102$
DECLARE
  src    text;
  a_from text := $q$WHERE NOT (suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced)$q$;
  a_to   text := $q$WHERE NOT (suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced OR (range_state IN (''CORE'',''HERO'') AND soh <= min_band))$q$;
  b_from text := $q$WHERE suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced$q$;
  b_to   text := $q$WHERE suggested_packs > 0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced OR (range_state IN (''CORE'',''HERO'') AND soh <= min_band)$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_bloom_order_recipe';

  IF src IS NULL THEN
    RAISE EXCEPTION 'ENG-102: rpc_bloom_order_recipe not found';
  END IF;

  -- Pin gate. If the recipe moved since this file was written, stop rather
  -- than patch a body nobody measured.
  IF md5(src) <> '6204ae7bf6b12f1a17e8bcb3d72028ea' THEN
    RAISE EXCEPTION 'ENG-102: recipe pin is %, expected 6204ae7bf6b12f1a17e8bcb3d72028ea', md5(src);
  END IF;

  IF (length(src) - length(replace(src, a_from, ''))) / length(a_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102: DELETE anchor is not unique';
  END IF;
  src := replace(src, a_from, a_to);

  IF (length(src) - length(replace(src, b_from, ''))) / length(b_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102: RETURN anchor is not unique after the DELETE patch';
  END IF;
  src := replace(src, b_from, b_to);

  EXECUTE src;
END
$eng102$;

-- ---------------------------------------------------------------------------
-- 3. The cache builder tags the retained rows and keeps ordered_line_count
--    naming the population it has always named.
-- ---------------------------------------------------------------------------
DO $eng102b$
DECLARE
  src    text;
  c_from text := $q$  UPDATE public.bloom_order_cache
     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n,$q$;
  c_to   text := $q$  -- ENG-102: the recipe now RETAINS a CORE/HERO line sitting at or below its
  -- own min_band, at zero quantity, so the sheet can say why it was not ordered
  -- (canon B4, 5(b2)). Tag it here, AFTER the hidden passes, so a hidden row is
  -- never restolen, and keep ordered_line_count on the population it named
  -- before this change (ENG-123: a display count must name its own population).
  UPDATE public.bloom_order_cache_line
     SET line_kind = 'covered'
   WHERE cache_id = v_cache_id
     AND line_kind = 'ordered'
     AND coalesce(suggested_packs, 0) = 0
     AND range_state IN ('CORE', 'HERO')
     AND soh <= min_band;

  UPDATE public.bloom_order_cache
     SET line_count         = v_n + v_appended,
         ordered_line_count = v_n - (SELECT count(*)
                                       FROM public.bloom_order_cache_line
                                      WHERE cache_id = v_cache_id
                                        AND line_kind = 'covered'),$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'refresh_bloom_order_cache';

  IF src IS NULL THEN
    RAISE EXCEPTION 'ENG-102: refresh_bloom_order_cache not found';
  END IF;
  IF (length(src) - length(replace(src, c_from, ''))) / length(c_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102: cache-count anchor is not unique';
  END IF;

  src := replace(src, c_from, c_to);
  EXECUTE src;
END
$eng102b$;

COMMIT;
