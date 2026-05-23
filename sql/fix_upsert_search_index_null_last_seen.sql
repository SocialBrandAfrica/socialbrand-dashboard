-- =============================================================================
-- Fix upsert_search_index -- null last_seen on dormant/placeholder products
--
-- Root cause: product_search_index.last_seen is NOT NULL, but daily_snapshots
-- contains rows for dormant catalogue stubs where snapshot_date IS NULL.
-- MAX(snapshot_date) over an all-NULL group returns NULL, which violates the
-- NOT NULL constraint. GREATEST(existing, NULL) also returns NULL on the
-- conflict-update path.
--
-- Fix: add snapshot_date IS NOT NULL to the WHERE clause. Products with no
-- valid snapshot date are excluded from the search index entirely -- this is
-- correct because we cannot set last_seen accurately for them.
--
-- Protocol: Rule 3 -- check overloads, DROP, recreate, flush cache.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Check for overloads
-- ---------------------------------------------------------------------------
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.proname = 'upsert_search_index';
-- Expected: one row -- (p_store_code text)


-- ---------------------------------------------------------------------------
-- STEP 2 -- Drop all versions
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.upsert_search_index CASCADE;


-- ---------------------------------------------------------------------------
-- STEP 3 -- Recreate with snapshot_date IS NOT NULL guard
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.upsert_search_index(p_store_code text)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER AS $$
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
$$;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Flush PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY -- re-run the failing call; should succeed with no error
-- ---------------------------------------------------------------------------
SELECT upsert_search_index('80579');
-- Expected: no error, function returns void
