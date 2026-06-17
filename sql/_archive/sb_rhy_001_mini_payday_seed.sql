-- =============================================================================
-- SB-RHY-001 -- Add mini payday (15th) as 5th community_rhythm profile
-- Decision basis: SB-RHY-001-BRIEF-2026-05-23.md Decision B (PM 2026-05-23)
--
-- Adds one row per client (store_code NULL = all stores).
-- Uses INSERT ... SELECT with NOT EXISTS guard -- safe to re-run.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Inspect existing profiles (read-only)
-- ---------------------------------------------------------------------------
SELECT event_name, event_type, start_day, end_day, multiplier_configured, store_code
FROM   public.community_rhythm
ORDER  BY start_day;
-- Expected: 4 rows before this runs


-- ---------------------------------------------------------------------------
-- STEP 2 -- Insert 5th profile: Mini-payday window (13th-16th, x1.10)
-- ---------------------------------------------------------------------------
INSERT INTO public.community_rhythm
    (client_id, store_code, event_name, event_type, start_day, end_day, multiplier_configured)
SELECT
    c.client_id,
    NULL,
    'Mini-payday window',
    'payday',
    13,
    16,
    1.10
FROM clients c
WHERE NOT EXISTS (
    SELECT 1 FROM public.community_rhythm cr
    WHERE cr.client_id = c.client_id
      AND cr.event_name = 'Mini-payday window'
);


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
SELECT event_name, event_type, start_day, end_day, multiplier_configured, store_code
FROM   public.community_rhythm
ORDER  BY start_day;
-- Expected: 5 rows -- Mini-payday window at start_day 13 now included
