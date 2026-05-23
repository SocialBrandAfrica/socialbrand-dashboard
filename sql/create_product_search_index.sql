-- =============================================================================
-- Performance: product_search_index table + upsert RPC
-- Creates a one-row-per-EAN product catalog for fast in-memory search.
-- Run once in Supabase SQL Editor.
--
-- Push-SigmaToSupabase.ps1 calls upsert_search_index('<store_code>') each night.
-- The stores[] array accumulates across all 5 store servers automatically.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1.  Table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS product_search_index (
    ean         text   PRIMARY KEY,
    description text   NOT NULL,
    dept        text   NOT NULL,
    subdept     text,
    stores      text[] NOT NULL DEFAULT '{}',
    last_seen   date   NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_psi_dept   ON product_search_index (dept);
CREATE INDEX IF NOT EXISTS idx_psi_stores ON product_search_index USING gin (stores);
CREATE INDEX IF NOT EXISTS idx_psi_desc   ON product_search_index USING gin (to_tsvector('simple', description));


-- -----------------------------------------------------------------------------
-- 2.  RLS: dashboard anon key may SELECT; writes go through the SECURITY DEFINER
--     function below (Push script uses service_role which bypasses RLS anyway,
--     but the function is cleaner and audit-safe).
-- -----------------------------------------------------------------------------
ALTER TABLE product_search_index ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'product_search_index' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON product_search_index FOR SELECT USING (true);
    END IF;
END
$$;


-- -----------------------------------------------------------------------------
-- 3.  Upsert RPC — called by Push-SigmaToSupabase.ps1 once per store per night
--
--     p_store_code: the calling store code (e.g. '10116')
--
--     On INSERT: adds the EAN with that store in the stores array.
--     On CONFLICT: merges the stores array (UNION) and keeps the latest last_seen.
--     dept is stored normalised (dots stripped) to match the UI chip labels.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_search_index(p_store_code text)
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
