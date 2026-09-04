-- ENG-102 FOLLOW-ONS, 2026-09-02. Two corrections to my own ship, applied live as
-- migrations `eng102_cached_reader_withholds_covered_until_ui` and
-- `eng102_covered_tag_never_steals_a_withheld_line`. Bodies below are what ran.
--
-- ============================================================================
-- WHY. ENG-102 made the recipe RETAIN covered lines and the cache builder tag
-- them. That part is right and is R22'd at zero rand movement. But
-- rpc_bloom_order_cached serves EVERY cache line, and the live frontend marks
-- only line_kind='hidden'. A covered row therefore rendered as an ordinary line
-- at zero quantity, unmarked, sorted among the ordered lines: 120 at 80175 and
-- ~212 at 10116 after the nightly rebuild.
--
-- 🔴 AND IT WOULD HAVE LANDED WITHOUT ANY MERGE. The database half was already
-- live and job 26 rebuilds every DC desk at 01:30 SAST, so the frontend deploy
-- gate (brief F11, "no frontend change ships before the three DC orders") would
-- NOT have caught it. A DB-only change can breach a frontend gate. That is the
-- durable lesson and it is why this is written down rather than just fixed.
--
-- The export was never at risk: it filters qty > 0, so a covered row could not
-- reach a CSV or TLX and no wrong order could be placed. The damage was what the
-- buyer sees, which on an order morning is damage enough.
-- ============================================================================
--
-- CORRECTION 1 -- the reader withholds covered rows until a surface can render
-- them. THE TRIPWIRE IS PRESERVED, NOT WEAKENED: served and line_count still come
-- from two INDEPENDENT paths (a count of the served rows, and the stored header
-- count minus the covered rows), so a genuine truncation still fires. Not silent
-- (R22 §3): `covered_withheld` carries the number on every payload. Reversible in
-- one line -- delete the two WHERE clauses when the surface learns to render them.
--
-- CORRECTION 2 -- the covered tag must never steal a hidden seller. Measured: the
-- served sheet went 859 -> 841 and the missing 18 carried `withheld_correction`.
-- Before ENG-102 the recipe did not return them, so the cache APPENDED them as
-- line_kind='hidden' and the buyer saw them flagged DROPPED. Afterwards the recipe
-- DID return them, the append skipped them, they stayed 'ordered', and the covered
-- tag claimed them -- so the withhold hid them completely. That is a SURFACING
-- REGRESSION and the exact opposite of what ENG-102 exists to do.
-- PROJECT-LEXICON settles it: line_kind answers PROVENANCE, withheld_correction
-- answers WHAT IS TRUE of the rate evidence, and collapsing them is ENG-123 --
-- which has now tried to happen a third time.
--
-- R22 AFTER BOTH, read as the browser's own anon role:
--   80175 DC_AMBIENT served 859 = line_count 859 = pre-ENG-102 served 859
--                    covered_withheld 102 · covered leaked 0
--                    ordered 568 + hidden 291 = 859 · all 342 warned lines visible
--   Pre-ENG-102 caches (10116, 21355, 80176, 80579): covered_withheld 0,
--   served = line_count, tripwire green. No regression on an unrebuilt desk.
--
-- 🔴 RESIDUAL, NAMED NOT FIXED: 18 lines at 80175 that used to carry the DROPPED
-- badge on the sheet now render as ordinary zero-quantity rows, because they are
-- line_kind='ordered' with withheld_correction rather than an appended 'hidden'.
-- They remain fully surfaced in the hidden-sellers panel with their reason and
-- their export. Whether the sheet should badge a withheld line that the recipe now
-- returns is a DISPLAY decision (Rule 10, CC does not make product decisions) and
-- it is put to PM rather than guessed at on an order eve.
--
-- 🔴 NO-DIVERGENCE, NAMED: sql/create_bloom_order_cache.sql cannot receive these
-- two changes as a clean splice, because that file is ALREADY rotted well beyond
-- them. Measured 2026-09-02: it carries ZERO occurrences of `line_kind` and its
-- counts block still reads `SET line_count=v_n, generation_ms=v_ms`, so it predates
-- the whole SB-CC-BLOOM-026 §5(b2) hidden-lines ship of 2026-08-25 as well as
-- ENG-106's benchmark columns. Regenerating it is a wholesale job across several
-- prior ships, not a splice of mine, and it is filed rather than half-done.
-- Both live bodies carry ZERO backslashes, so that regeneration is SAFE whenever
-- it is scheduled -- the 13-backslash channel hazard does not apply here.

BEGIN;

-- ---------------------------------------------------------------------------
-- CORRECTION 1: rpc_bloom_order_cached withholds covered rows.
-- ---------------------------------------------------------------------------
DO $eng102ui$
DECLARE
  src text;
  a_from text := $q$    'line_count',   (SELECT line_count FROM hdr),$q$;
  a_to   text := $q$    -- ENG-102: the covered rows are withheld from this payload until a surface
    -- can render them, so the count names the population actually served.
    'line_count',   (SELECT line_count FROM hdr)
                    - (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                        WHERE l.line_kind = 'covered'),
    'covered_withheld', (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                          WHERE l.line_kind = 'covered'),$q$;
  b_from text := $q$    'served',       (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id),$q$;
  b_to   text := $q$    'served',       (SELECT count(*) FROM public.bloom_order_cache_line l JOIN hdr ON hdr.cache_id=l.cache_id
                     WHERE l.line_kind IS DISTINCT FROM 'covered'),$q$;
  c_from text := $q$    'lines',        COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
                              FROM public.bloom_order_cache_line l
                              JOIN hdr ON hdr.cache_id=l.cache_id), '[]'::jsonb),$q$;
  c_to   text := $q$    'lines',        COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no)
                              FROM public.bloom_order_cache_line l
                              JOIN hdr ON hdr.cache_id=l.cache_id
                             WHERE l.line_kind IS DISTINCT FROM 'covered'), '[]'::jsonb),$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='rpc_bloom_order_cached';
  IF src IS NULL THEN RAISE EXCEPTION 'ENG-102 ui guard: rpc_bloom_order_cached not found'; END IF;
  IF (length(src)-length(replace(src,a_from,'')))/length(a_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102 ui guard: line_count anchor not unique'; END IF;
  src := replace(src, a_from, a_to);
  IF (length(src)-length(replace(src,b_from,'')))/length(b_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102 ui guard: served anchor not unique'; END IF;
  src := replace(src, b_from, b_to);
  IF (length(src)-length(replace(src,c_from,'')))/length(c_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102 ui guard: lines anchor not unique'; END IF;
  src := replace(src, c_from, c_to);
  EXECUTE src;
END
$eng102ui$;

-- ---------------------------------------------------------------------------
-- CORRECTION 2: the covered tag never claims a withheld-correction line.
-- ---------------------------------------------------------------------------
DO $eng102w$
DECLARE
  src text;
  w_from text := $q$     AND NOT (coalesce(count_first,false) OR coalesce(keep_or_delist,false)
              OR coalesce(pack_forced_review,false) OR coalesce(min_presence_forced,false));$q$;
  w_to   text := $q$     AND NOT (coalesce(count_first,false) OR coalesce(keep_or_delist,false)
              OR coalesce(pack_forced_review,false) OR coalesce(min_presence_forced,false))
     -- ENG-102 correction: a withheld-correction line is a HIDDEN SELLER and keeps
     -- that identity. Before ENG-102 it was appended as line_kind='hidden' and the
     -- buyer saw it flagged DROPPED. The covered tag must never claim it.
     AND NOT coalesce(withheld_correction, false);$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='refresh_bloom_order_cache';
  IF src IS NULL THEN RAISE EXCEPTION 'ENG-102: refresh_bloom_order_cache not found'; END IF;
  IF (length(src)-length(replace(src,w_from,'')))/length(w_from) <> 1 THEN
    RAISE EXCEPTION 'ENG-102: covered-tag guard anchor not unique'; END IF;
  src := replace(src, w_from, w_to);
  EXECUTE src;
END
$eng102w$;

COMMIT;
