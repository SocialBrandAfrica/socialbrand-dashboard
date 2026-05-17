-- =============================================================================
-- SB-AP-002 Step 1b — Patch sigma_server for the three stores confirmed 2026-05-17
-- =============================================================================

UPDATE stores SET sigma_server = 'SRSROOSVILLESVR'  WHERE store_code = '80175';
UPDATE stores SET sigma_server = 'SRSDELAREYT2SVR'  WHERE store_code = '80579';
UPDATE stores SET sigma_server = 'SRTROOSVILLESVR'  WHERE store_code = '80176';

-- Verify — all 5 stores should now have a sigma_server value
SELECT store_code, store_name, sigma_server
FROM stores
ORDER BY store_code;
