-- =============================================================================
-- SB-SCH-001 Block 8 Step 4 -- Create community_rhythm table
-- Decision basis: SB-SCH-001-MINUTES-2026-05-23.md Block 3
--
-- Key design decisions:
--   store_code NULLABLE: NULL row applies to entire client portfolio.
--     A non-null row overrides for a specific store. Avoids duplicating
--     event records across all 5 stores for the same event.
--   multiplier_observed NULLABLE: starts empty, filled retrospectively
--     by comparing actual sales to the event window over time.
--   4 standard event profiles seeded on creation (DFM defaults).
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Create table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.community_rhythm (
    id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             uuid        NOT NULL REFERENCES clients(client_id),
    store_code            text        NULL,
    event_name            text        NOT NULL,
    event_type            text        NOT NULL CHECK (event_type IN ('payday', 'pension', 'seasonal', 'custom')),
    start_day             int         NOT NULL CHECK (start_day BETWEEN 1 AND 31),
    end_day               int         NOT NULL CHECK (end_day BETWEEN 1 AND 31),
    multiplier_configured decimal     NOT NULL DEFAULT 1.0,
    multiplier_observed   decimal     NULL,
    is_active             boolean     NOT NULL DEFAULT true,
    created_at            timestamptz NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- STEP 2 -- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_community_rhythm_client
    ON public.community_rhythm (client_id);

CREATE INDEX IF NOT EXISTS idx_community_rhythm_client_store
    ON public.community_rhythm (client_id, store_code);

CREATE INDEX IF NOT EXISTS idx_community_rhythm_active
    ON public.community_rhythm (client_id, is_active)
    WHERE is_active = true;


-- ---------------------------------------------------------------------------
-- STEP 3 -- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.community_rhythm ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'community_rhythm' AND policyname = 'anon read'
    ) THEN
        CREATE POLICY "anon read" ON public.community_rhythm
            FOR SELECT USING (true);
    END IF;
END $$;


-- ---------------------------------------------------------------------------
-- STEP 4 -- Seed 4 standard event profiles for DFM (store_code NULL = all stores)
--
-- Profile 1: Payday window    22nd-28th
-- Profile 2: Pension window   2nd-8th
-- Profile 3: Pre-payday       18th-22nd
-- Profile 4: Custom/seasonal  placeholder (start/end adjustable without code changes)
-- ---------------------------------------------------------------------------
INSERT INTO public.community_rhythm
    (client_id, store_code, event_name, event_type, start_day, end_day, multiplier_configured)
SELECT
    c.client_id,
    NULL,
    e.event_name,
    e.event_type,
    e.start_day,
    e.end_day,
    e.multiplier_configured
FROM clients c
CROSS JOIN (VALUES
    ('Payday window',     'payday',   22, 28, 1.30),
    ('Pension window',    'pension',   2,  8, 1.20),
    ('Pre-payday buildup','payday',   18, 22, 1.15),
    ('Custom seasonal',   'custom',    1,  1, 1.00)
) AS e(event_name, event_type, start_day, end_day, multiplier_configured)
WHERE NOT EXISTS (
    SELECT 1 FROM public.community_rhythm cr
    WHERE cr.client_id = c.client_id
      AND cr.event_name = e.event_name
);


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT
    id,
    event_name,
    event_type,
    start_day,
    end_day,
    multiplier_configured,
    store_code,
    is_active
FROM public.community_rhythm
ORDER BY event_type, start_day;
-- Expected: 4 rows (one per event profile, store_code NULL = all stores)

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'community_rhythm';
-- Expected: 1 row
