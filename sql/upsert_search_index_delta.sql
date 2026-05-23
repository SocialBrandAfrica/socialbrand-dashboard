-- =============================================================================
-- upsert_search_index v2 -- delta mode support
-- SB-SCH-001 item: search index delta update
--
-- Adds optional p_snapshot_date parameter.
-- When provided (nightly mode): only processes EANs seen on that date
--   (delta -- only today's EANs, much faster than full rebuild).
-- When NULL (manual or backfill): processes all EANs for the store
--   (full rebuild -- backwards compatible with existing calls).
--
-- Already includes snapshot_date IS NOT NULL guard from
--   fix_upsert_search_index_null_last_seen.sql (2026-05-23).
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
-- STEP 3 -- Recreate with optional p_snapshot_date parameter
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.upsert_search_index(
    p_store_code    text,
    p_snapshot_date date DEFAULT NULL
)
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
$$;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Flush PostgREST schema cache
-- ---------------------------------------------------------------------------
SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY -- delta call (today's date) and full rebuild both work
-- ---------------------------------------------------------------------------
SELECT upsert_search_index('80579', CURRENT_DATE);
-- Expected: no error, returns NULL (void)

SELECT upsert_search_index('80579');
-- Expected: no error, returns NULL (void)
