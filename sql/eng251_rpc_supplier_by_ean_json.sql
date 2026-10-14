-- =============================================================================
-- eng251_rpc_supplier_by_ean_json.sql   (APPLIED 14-10-2026, migration eng251_rpc_supplier_by_ean_json)
-- ENG-251 (BUG-LOG): the Supplier column of the Slow Movers, Velocity, Stock Ledger
-- Discrepancy and Focus Area reports was read through the 1,000-row PostgREST cap
-- (first 200 rows with a supplier: 5 at 10116, 12 at 80175, 168 at 80579 whose rows fit).
--
-- Additive jsonb wrapper over rpc_supplier_by_ean (R30; the SETOF original is untouched).
-- ONE jsonb row a row cap cannot truncate; `served` is computed FROM the payload, the R22
-- tripwire the page checks against the length of `rows`.
-- One supplier per EAN: DISTINCT ON picks the alphabetically first supplier_name where
-- stores disagree (the old client rule, last write wins, had no defined order).
-- ACL copied from rpc_supplier_by_ean: anon, authenticated, service_role (a function grant,
-- no table permission is touched).
--
-- R22 after apply: 10116 served 30,232 = rows 30,232 (1.23 MB); five stores served 32,880 =
-- rows 32,880 (1.34 MB).
-- Rollback: DROP FUNCTION public.rpc_supplier_by_ean_json(text[]);
-- =============================================================================
DO $$
BEGIN
  IF to_regprocedure('public.rpc_supplier_by_ean_json(text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'rpc_supplier_by_ean_json already exists; refusing to overwrite it';
  END IF;
END $$;

CREATE FUNCTION public.rpc_supplier_by_ean_json(p_stores text[])
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '15s'
AS $fn$
  WITH r AS (
    SELECT DISTINCT ON (ean) ean, supplier_name
      FROM public.rpc_supplier_by_ean(p_stores)
     ORDER BY ean, supplier_name
  )
  SELECT jsonb_build_object(
    'stores',       to_jsonb(p_stores),
    'served',       (SELECT count(*) FROM r),
    'rows',         COALESCE((SELECT jsonb_agg(jsonb_build_array(ean, supplier_name)) FROM r), '[]'::jsonb),
    'generated_at', statement_timestamp()
  )
$fn$;

COMMENT ON FUNCTION public.rpc_supplier_by_ean_json(text[]) IS
  'GRADE: CALCULATED. ENG-251 (dashboard lane, 14-10-2026): [[ean, supplier_name], ...] for the selected stores as ONE jsonb row, with served = count of the rows array (R22 tripwire). Additive wrapper over rpc_supplier_by_ean, which is a SETOF read through the 1,000-row PostgREST cap.';

REVOKE EXECUTE ON FUNCTION public.rpc_supplier_by_ean_json(text[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_supplier_by_ean_json(text[]) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
