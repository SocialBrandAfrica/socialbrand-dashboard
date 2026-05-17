-- =============================================================================
-- SB-AP-002 Step 2b — Backfill client_id on small tables (products, suppliers, price_history)
-- Run this after step02a. Do NOT include daily_snapshots here — that's step02c.
-- =============================================================================

UPDATE products
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

UPDATE suppliers
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

UPDATE price_history
SET client_id = (SELECT client_id FROM clients WHERE client_name = 'SocialBrand')
WHERE client_id IS NULL;

-- Verify
SELECT 'products'      AS tbl, COUNT(*) AS total, COUNT(client_id) AS with_client_id FROM products
UNION ALL
SELECT 'suppliers'     AS tbl, COUNT(*) AS total, COUNT(client_id) AS with_client_id FROM suppliers
UNION ALL
SELECT 'price_history' AS tbl, COUNT(*) AS total, COUNT(client_id) AS with_client_id FROM price_history;
