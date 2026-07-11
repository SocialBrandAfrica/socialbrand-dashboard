-- =============================================================================
-- create_rpc_forge_summary.sql
-- Forge toolkit (2026-07-10 build). Built live, never committed to the repo
-- until this pass (HANDOVER-CURRENT item 10, "Forge fold-in" debt).
-- =============================================================================
-- Per-store, per-bucket/artifact rollup off l2_classification's latest
-- snapshot -- rows, capital by bucket, row counts by artifact (routing
-- destination: stockflow/tlx/deposit_manual/none). Read-only, no ledger scan
-- -- purely aggregates the existing classification snapshot.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_forge_summary(p_stores text[] DEFAULT NULL::text[], p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH latest AS (
  SELECT store_code, COALESCE(p_date, MAX(snapshot_date)) AS snapshot_date
  FROM l2_classification
  WHERE (p_stores IS NULL OR store_code = ANY(p_stores))
  GROUP BY store_code
),
rows_in AS (
  SELECT c.* FROM l2_classification c
  JOIN latest l ON l.store_code = c.store_code AND l.snapshot_date = c.snapshot_date
),
b AS (
  SELECT store_code, snapshot_date, bucket,
         COUNT(*) AS rows, ROUND(SUM(capital_value)::numeric,2) AS capital
  FROM rows_in GROUP BY store_code, snapshot_date, bucket
),
a AS (
  SELECT store_code, snapshot_date, artifact, COUNT(*) AS rows
  FROM rows_in WHERE artifact <> 'none'
  GROUP BY store_code, snapshot_date, artifact
),
hdr AS (
  SELECT store_code, snapshot_date,
         MAX(engine_version) AS engine_version,
         COUNT(*) AS pool_total,
         COUNT(*) FILTER (WHERE ean_status='UNRESOLVED') AS unresolved_ean
  FROM rows_in GROUP BY store_code, snapshot_date
)
SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'store_code', h.store_code,
  'snapshot_date', h.snapshot_date,
  'engine_version', h.engine_version,
  'pool_total', h.pool_total,
  'unresolved_ean', h.unresolved_ean,
  'buckets', (SELECT jsonb_object_agg(b.bucket, jsonb_build_object('rows', b.rows, 'capital', b.capital))
              FROM b WHERE b.store_code = h.store_code),
  'artifacts', (SELECT jsonb_object_agg(a.artifact, jsonb_build_object('rows', a.rows))
                FROM a WHERE a.store_code = h.store_code)
) ORDER BY h.store_code), '[]'::jsonb)
FROM hdr h
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_forge_summary(text[], date) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
