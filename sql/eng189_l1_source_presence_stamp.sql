-- =============================================================================
-- eng189_l1_source_presence_stamp.sql
-- ENG-189: the L1 mirror cannot tell which of its rows Sigma still holds.
-- =============================================================================
-- Reference : BUG-LOG ENG-189 (CC, 2026-09-15). Forge/SB-CC-ORDER-001 item 7.
-- Class     : the 11 L1 tables the extractor loads by a FULL re-read of the
--             Sigma table (no WHERE), upserted on the natural key, with NO
--             delete. A row Sigma deleted is never re-sent and never removed,
--             and the first-insert stamp (ingested_at, or extracted_at on the
--             two promo tables) is never refreshed by the upsert, so nothing
--             in the table says which rows the source still holds.
-- Measured  : 2026-09-15 09:2x SAST, against the 2026-09-14 nightly run. The
--             rows each load step rewrote (transaction id after the previous
--             step's push_log row) equal push_log.rows_pushed in 65 of 65 cells
--             (13 tables x 5 stores); the two delete-first tables hold 0 rows
--             the run did not send. Rows held that the run did not send:
--               sigma_order_lines          152,861
--               sigma_promotion_articles    57,185
--               sigma_orders                 7,932
--               sigma_supplier_link          5,923
--               sigma_articles               5,139
--               sigma_lifecycle              2,146
--               sigma_trade_terms            1,358
--               sigma_promotions               765
--               sigma_departments / sigma_subdepts / sigma_supplier_master  0
-- What this does: stamps last_seen_at = now() on every row the extractor
--             writes, by a BEFORE INSERT OR UPDATE trigger, so the extractor
--             needs no change and no server deploy. A row whose last_seen_at
--             is older than that store's latest successful full read of the
--             table (push_log, push_type l1_table) is a row Sigma no longer
--             holds.
-- What it does NOT do: delete anything (L1 keeps history; a purged promo or a
--             closed receipt is still evidence) and change no reader. No
--             number moves. Which readers must honour the stamp is the
--             cross-app scope in BUG-LOG ENG-189, PM's to rule.
-- Sites skipped, named (R30 addendum 3): sigma_ean_master and sigma_scan_refs
--             delete before they insert, so they already mirror (0 unsent rows,
--             measured); sigma_sales, sigma_movements and l2_soh_daily are
--             delta or append loads, where "not re-sent" means nothing.
-- Proof     : rollback proof 2026-09-15 on a 20,000-row copy of
--             sigma_promotion_articles through the extractor's statement shape
--             (jsonb_populate_recordset, ON CONFLICT DO UPDATE on the payload
--             columns only): 20,000 stamped, 0 null, the first-insert stamp
--             moved on 0 rows, a new row stamped on insert, service_role (the
--             extractor's role) fires it. 876 ms -> 1,068 ms per 20,000 rows.
-- Lock      : ADD COLUMN with no default is a catalog change, but it takes an
--             ACCESS EXCLUSIVE lock. lock_timeout fails the migration cleanly
--             on a busy table instead of queueing readers behind it.
-- Grants    : the function is REVOKEd from PUBLIC, anon and authenticated.
--             A trigger's EXECUTE is checked when the trigger is created, not
--             when it fires, so the extractor's upsert is unaffected (proven).
-- =============================================================================

SET lock_timeout = '5s';

CREATE FUNCTION public.sigma_stamp_last_seen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.last_seen_at := now();
  RETURN NEW;
END
$$;

COMMENT ON FUNCTION public.sigma_stamp_last_seen() IS
  'GRADE: RAW. ENG-189. Sets last_seen_at = now() on every row written to an L1 table the extractor loads by full re-read and upsert. A row the source deleted is never re-sent, so its last_seen_at stops moving. Provenance of the mirror, never a fact about the business.';

REVOKE ALL ON FUNCTION public.sigma_stamp_last_seen() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sigma_stamp_last_seen() FROM anon, authenticated;

DO $$
DECLARE
  t    text;
  tbls text[] := ARRAY['sigma_articles','sigma_lifecycle','sigma_orders','sigma_order_lines',
                       'sigma_supplier_master','sigma_supplier_link','sigma_trade_terms',
                       'sigma_departments','sigma_subdepts','sigma_promotions','sigma_promotion_articles'];
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    IF EXISTS (SELECT 1 FROM pg_attribute
               WHERE attrelid = ('public.' || t)::regclass AND attname = 'last_seen_at' AND NOT attisdropped) THEN
      RAISE EXCEPTION 'ENG-189: % already carries last_seen_at', t;
    END IF;
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN last_seen_at timestamptz', t);
    EXECUTE format('COMMENT ON COLUMN public.%I.last_seen_at IS %L', t,
      'ENG-189. When the extractor last sent this row, set by sigma_stamp_last_seen on insert and on every upsert. '
      'NULL = not sent since the stamp began on 2026-09-15. Older than the latest successful full read of this table '
      'at this store (push_log, push_type l1_table) = the source no longer holds the row. The first-insert stamp beside '
      'it (ingested_at, or extracted_at on the promo tables) is never refreshed by the upsert.');
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I '
                   'FOR EACH ROW EXECUTE FUNCTION public.sigma_stamp_last_seen()', t || '_last_seen', t);
  END LOOP;

  IF (SELECT count(*) FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = ANY (tbls) AND a.attname = 'last_seen_at' AND NOT a.attisdropped) <> 11 THEN
    RAISE EXCEPTION 'ENG-189: expected 11 last_seen_at columns';
  END IF;
  IF (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
      WHERE NOT tg.tgisinternal AND c.relname = ANY (tbls) AND tg.tgname = c.relname || '_last_seen') <> 11 THEN
    RAISE EXCEPTION 'ENG-189: expected 11 triggers';
  END IF;
  IF has_function_privilege('anon', 'public.sigma_stamp_last_seen()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.sigma_stamp_last_seen()', 'EXECUTE') THEN
    RAISE EXCEPTION 'ENG-189: a client role can execute the stamp';
  END IF;
END
$$;

-- =============================================================================
-- THE CHECK, after the first nightly run with the stamp. Every cell must read
-- seen_last_run = rows_pushed; a gap names a table and a store. The 10-minute
-- margin absorbs the server clock against the database clock; the previous
-- night's stamps sit about 24 hours earlier.
-- =============================================================================
-- WITH last AS (
--   SELECT DISTINCT ON (store_code, table_name) store_code, table_name, rows_pushed, started_at
--   FROM push_log WHERE push_type = 'l1_table' AND status = 'SUCCESS'
--   ORDER BY store_code, table_name, started_at DESC)
-- SELECT l.table_name, l.store_code, l.rows_pushed,
--        (xpath('/row/c/text()', query_to_xml(format(
--           'select count(*) as c from public.%I where store_code = %L and last_seen_at >= %L::timestamptz - interval ''10 minutes''',
--           l.table_name, l.store_code, l.started_at), false, true, '')))[1]::text::bigint AS seen_last_run
-- FROM last l
-- WHERE l.table_name IN ('sigma_articles','sigma_lifecycle','sigma_orders','sigma_order_lines',
--                        'sigma_supplier_master','sigma_supplier_link','sigma_trade_terms',
--                        'sigma_departments','sigma_subdepts','sigma_promotions','sigma_promotion_articles')
-- ORDER BY 1, 2;
