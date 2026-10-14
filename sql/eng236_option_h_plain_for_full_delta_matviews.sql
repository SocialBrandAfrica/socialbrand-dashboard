-- =============================================================================
-- ENG-236 OPTION H -- READY, NOT APPLIED. Apply only on PM's ruling (BUG-LOG ENG-236 addendum 3).
--
--   Four of the six chain matviews change every row on every refresh (l2_stock_position.positioned_at, l2_item_classification.classified_at and
--   l2_ranging_tier.tiered_at are CURRENT_TIMESTAMP, l2_rate_of_sale.computed_date is CURRENT_DATE), so REFRESH ... CONCURRENTLY deletes and
--   re-inserts all 283,807 rows of each through 4 to 10 indexes. Measured on a scratch copy of l2_stock_position: plain 68 s, concurrent 366 s.
--   H turns those four back into plain REFRESH and keeps CONCURRENTLY on l2_movements_typed, l2_kpi_daily, mv_kpi_by_date and mv_rate_of_sale,
--   which have a real delta.
--
--   WHAT H GIVES BACK AND WHAT IT COSTS. Back: the 22 to 24.5 minute chain of the 18 plain nights. Cost: the four plain refreshes take AccessExclusive
--   locks again and hold them to the end of the pipeline transaction, so the 13-10 deadlock (a reader holding one chain matview while it waits for another)
--   is possible on those four. What still stands against it: the 22:00 to 03:00 SAST rule (no session reads heavily while the pipeline runs) and
--   guard_pipeline_orphans (cancels a read-only mgmt-api query older than 10 minutes while the pipeline runs).
--
--   Asserted replace on the live definition, pinned on the live md5 (6653de1a36ba3e545b3af14c42ca2a64, 13,499 chars, after eng236_pipeline_concurrent_guard).
-- REVERSE: put CONCURRENTLY back on the four statements (the same four anchors, swapped).
-- =============================================================================

DO $mig$
DECLARE
  def text; v_live text; n int; a text; b text; t text;
BEGIN
  SELECT md5(p.prosrc) INTO v_live FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'refresh_l2_pipeline';
  IF v_live IS DISTINCT FROM '6653de1a36ba3e545b3af14c42ca2a64' THEN RAISE EXCEPTION 'pin failed: live md5 % is not 6653de1a', v_live; END IF;
  def := pg_get_functiondef('public.refresh_l2_pipeline()'::regprocedure);
  FOREACH t IN ARRAY ARRAY['l2_rate_of_sale', 'l2_item_classification', 'l2_ranging_tier', 'l2_stock_position'] LOOP
    a := 'REFRESH MATERIALIZED VIEW CONCURRENTLY ' || t || ';';
    b := 'REFRESH MATERIALIZED VIEW ' || t || ';';
    n := (length(def) - length(replace(def, a, ''))) / length(a);
    IF n <> 1 THEN RAISE EXCEPTION 'anchor [%] found % times', a, n; END IF;
    def := replace(def, a, b);
  END LOOP;
  EXECUTE def;
END
$mig$;
