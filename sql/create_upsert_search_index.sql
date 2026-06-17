-- =============================================================================
-- create_upsert_search_index.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for upsert_search_index.
-- Supersedes the copies in create_product_search_index.sql, upsert_search_index_delta.sql
-- and fix_upsert_search_index_null_last_seen.sql (sediment). Extracted verbatim from
-- LIVE 2026-06-17. Delta mode: pass a snapshot_date to re-index only that day's EANs;
-- NULL = full rebuild. (The product_search_index TABLE remains in create_product_search_index.sql.)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.upsert_search_index(p_store_code text, p_snapshot_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
    INSERT INTO product_search_index (ean, description, dept, subdept, stores, last_seen)
    SELECT
        ean,
        MAX(description)                           AS description,
        TRIM(REPLACE(MAX(dept_name),  '.', ''))    AS dept,
        MAX(sub_dept_name)                         AS subdept,
        ARRAY_AGG(DISTINCT store_code)             AS stores,
        MAX(snapshot_date)::date                   AS last_seen
    FROM  daily_snapshots
    WHERE store_code    = p_store_code
      AND ean           IS NOT NULL
      AND description   IS NOT NULL
      AND dept_name     IS NOT NULL
      AND snapshot_date IS NOT NULL
      AND (p_snapshot_date IS NULL OR snapshot_date = p_snapshot_date)
    GROUP BY ean
    ON CONFLICT (ean) DO UPDATE
        SET description = EXCLUDED.description,
            dept        = EXCLUDED.dept,
            subdept     = COALESCE(EXCLUDED.subdept, product_search_index.subdept),
            stores      = (
                SELECT ARRAY_AGG(DISTINCT s)
                FROM   UNNEST(product_search_index.stores || EXCLUDED.stores) AS s
            ),
            last_seen   = GREATEST(product_search_index.last_seen, EXCLUDED.last_seen);
$function$;
