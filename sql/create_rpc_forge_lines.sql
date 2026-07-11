-- =============================================================================
-- create_rpc_forge_lines.sql
-- Forge toolkit (2026-07-10 build). Built live, never committed to the repo
-- until this pass (HANDOVER-CURRENT item 10, "Forge fold-in" debt).
-- =============================================================================
-- Fixer download source: the actual product lines behind a Forge selector --
-- leave_counted (bucket), deposit (bucket, own manual list per ENG-007, never
-- the routine count stack), tlx (artifact='tlx' AND |soh| < the near-
-- certainty belt AND not counted_91 AND ean_status='REAL' -- canon §8.12#3),
-- or any other artifact name directly (stockflow, etc).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_forge_lines(p_store text, p_date date DEFAULT NULL::date, p_selector text DEFAULT 'stockflow'::text)
 RETURNS TABLE(product_code bigint, description text, dept_name text, subdept_name text, soh numeric, capital_value numeric, last_sale_date date, last_receipt_date date, bucket text, bucket_reason text, ean_key text, ean_status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH belt AS (
  SELECT value_num FROM forge_config WHERE config_key='tlx_soh_belt' AND retired_on IS NULL LIMIT 1
),
latest AS (
  SELECT COALESCE(p_date, MAX(snapshot_date)) AS d FROM l2_classification WHERE store_code = p_store
)
SELECT c.product_code, c.description, c.dept_name, c.subdept_name,
       c.soh, c.capital_value, sp.last_sale_date, sp.last_receipt_date,
       c.bucket, c.bucket_reason, c.ean_key, c.ean_status
FROM l2_classification c
JOIN latest l ON c.snapshot_date = l.d
LEFT JOIN l2_stock_position sp
       ON sp.store_code = c.store_code AND sp.product_code = c.product_code
WHERE c.store_code = p_store
  AND (
        (p_selector = 'leave_counted' AND c.bucket = 'LEAVE_COUNTED')
     OR (p_selector = 'deposit' AND c.bucket = 'DEPOSIT')
     OR (p_selector = 'tlx' AND c.artifact = 'tlx'
         AND ABS(c.soh) < (SELECT value_num FROM belt)
         AND NOT c.counted_91 AND c.ean_status = 'REAL')
     OR (p_selector NOT IN ('tlx','leave_counted','deposit') AND c.artifact = p_selector)
      )
ORDER BY c.capital_value DESC
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_forge_lines(text, date, text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
