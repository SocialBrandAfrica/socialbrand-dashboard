CREATE OR REPLACE FUNCTION public.rpc_forge_integrity_lines(p_store text, p_instrument text)
 RETURNS TABLE(product_code bigint, description text, dept_name text, subdept_name text, soh numeric, capital_value numeric, detail text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH latest AS (
  SELECT MAX(snapshot_date) AS d FROM l2_classification WHERE store_code = p_store
),
cls AS (
  SELECT c.* FROM l2_classification c JOIN latest l ON l.d = c.snapshot_date
  WHERE c.store_code = p_store
)
-- untrusted capital: what is dragging Trusted capital down (the excluded lines still carrying soh)
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'excluded from trusted capital: '||c.bucket||COALESCE(' — '||c.bucket_reason,'')
FROM cls c
WHERE p_instrument = 'purified_capital_share'
  AND c.bucket NOT IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED') AND c.soh <> 0
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       COALESCE(c.bucket_reason,'unclassifiable — data gap')
FROM cls c WHERE p_instrument = 'ambiguity_debt' AND c.bucket = 'AMBIGUOUS'
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'no proven barcode — bucket '||c.bucket
FROM cls c WHERE p_instrument = 'unresolved_ean' AND c.ean_status = 'UNRESOLVED'
UNION ALL
SELECT c.product_code, c.description, c.dept_name, c.subdept_name, c.soh, c.capital_value,
       'healthy and selling, cost R0 — load the cost in Sigma'
FROM cls c WHERE p_instrument = 'costless_real_stock'
  AND c.bucket = 'HEALTHY' AND c.soh > 0 AND COALESCE(c.unit_cost,0) = 0
UNION ALL
SELECT sp.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       'SOH '||sp.soh||', last sale '||COALESCE(sp.last_sale_date::text,'never')
FROM l2_stock_position sp
JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
WHERE p_instrument = 'negative_book' AND sp.store_code = p_store AND sp.class = 'NORMAL' AND sp.soh < 0
UNION ALL
SELECT sp.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       'not counted in 91 days (ledger I-channel)'
FROM l2_stock_position sp
JOIN sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
WHERE p_instrument = 'count_coverage_91d' AND sp.store_code = p_store AND sp.class = 'NORMAL' AND sp.soh <> 0
  AND NOT EXISTS (SELECT 1 FROM sigma_movements m
                  WHERE m.store_code = sp.store_code AND m.product_code = sp.product_code
                    AND m.movement_type = 'I' AND m.movement_date >= CURRENT_DATE - 91)
UNION ALL
SELECT sp.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       k.kvi_band||', SOH '||sp.soh||' — order or count today'
FROM l2_stock_position sp
JOIN l2_kvi_profile k ON k.store_code = sp.store_code AND k.product_code = sp.product_code
WHERE p_instrument = 'kvi_lines_oos' AND sp.store_code = p_store AND sp.class = 'NORMAL'
  AND sp.soh <= 0 AND k.kvi_band IN ('KVI_CRITICAL','KVI_IMPORTANT')
UNION ALL
SELECT p.product_code, sp.description, sp.dept_name, sp.subdept_name, sp.soh, sp.capital_value,
       'family draw '||ROUND(p.ros_draw_28d::numeric,1)||'/day vs till scan '||ROUND(p.ros_28d::numeric,1)||'/day — '
       ||ROUND((p.ros_draw_28d - p.ros_28d)::numeric,1)||'/day invisible to scan-based ordering'
FROM l2_bloom_ros_pantry p
LEFT JOIN l2_stock_position sp ON sp.store_code = p.store_code AND sp.product_code = p.product_code
WHERE p_instrument = 'hidden_family_demand' AND p.store_code = p_store
  AND NOT p.unit_incommensurable AND p.ros_draw_28d > p.ros_28d
ORDER BY capital_value DESC NULLS LAST
$function$
