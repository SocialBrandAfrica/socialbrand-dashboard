-- =============================================================================
-- SB-AP-002 Step 2c — Backfill client_id on daily_snapshots
-- This table may be large — run separately and give it time.
-- =============================================================================

UPDATE daily_snapshots
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

-- Verify
SELECT COUNT(*) AS total, COUNT(client_id) AS with_client_id FROM daily_snapshots;
