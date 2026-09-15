-- create_sigma_stamp_last_seen.sql
--
-- ENG-189. The source-presence stamp on the 11 full-read L1 tables.
-- GENERATED FROM LIVE via pg_get_functiondef on 2026-09-15, never hand-written, hash-gated:
-- c3cc9abe62ac798d0bd4506dfdc07138 / 200. COMMENT 6d8bab1dd537690558144753dfddcaaf.
-- The migration that created it, with the 11 last_seen_at columns and the 11 <table>_last_seen triggers,
-- is sql/eng189_l1_source_presence_stamp.sql (migration eng189_l1_source_presence_stamp, applied
-- 2026-09-15 17:53 SAST). A trigger's EXECUTE is checked when the trigger is created, never when it fires,
-- so the revokes below do not touch the extractor's upsert (proven in that file).

CREATE OR REPLACE FUNCTION public.sigma_stamp_last_seen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.last_seen_at := now();
  RETURN NEW;
END
$function$;

COMMENT ON FUNCTION public.sigma_stamp_last_seen() IS
  'GRADE: RAW. ENG-189. Sets last_seen_at = now() on every row written to an L1 table the extractor loads by full re-read and upsert. A row the source deleted is never re-sent, so its last_seen_at stops moving. Provenance of the mirror, never a fact about the business.';

REVOKE ALL ON FUNCTION public.sigma_stamp_last_seen() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sigma_stamp_last_seen() FROM anon, authenticated;
