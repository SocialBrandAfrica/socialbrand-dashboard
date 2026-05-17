-- ============================================================
-- Step 1f — Patch existing stores table
-- Adds lan_ip and secondary_ip columns, corrects all hostnames
-- Source of truth: project_server_inventory.md verified 2026-05-17
-- ============================================================

ALTER TABLE stores ADD COLUMN IF NOT EXISTS lan_ip       TEXT;
ALTER TABLE stores ADD COLUMN IF NOT EXISTS secondary_ip TEXT;

UPDATE stores SET sigma_server = 'srsdelareyvilesvr', lan_ip = '10.6.120.1',  secondary_ip = NULL           WHERE store_code = '10116';
UPDATE stores SET sigma_server = 'srsroosvillesvr',   lan_ip = '10.6.214.1',  secondary_ip = NULL           WHERE store_code = '80175';
UPDATE stores SET sigma_server = 'srtdelareyvilsvr',  lan_ip = '10.6.120.60', secondary_ip = NULL           WHERE store_code = '21355';
UPDATE stores SET sigma_server = 'srsdelareyt2svr',   lan_ip = '10.6.18.60',  secondary_ip = '192.168.0.249' WHERE store_code = '80579';
UPDATE stores SET sigma_server = 'srtroosvillesvr',   lan_ip = '10.6.214.60', secondary_ip = NULL           WHERE store_code = '80176';

-- Verify
SELECT store_code, store_name, sigma_server, lan_ip, secondary_ip
FROM stores ORDER BY store_code;
