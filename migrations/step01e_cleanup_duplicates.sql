-- =============================================================================
-- Step 1e — Remove duplicate clients/stores rows and apply correct sigma_servers
-- =============================================================================

-- Step 1: Identify the client_id to KEEP (oldest row)
-- Step 2: Delete stores belonging to the duplicate client_id
-- Step 3: Delete the duplicate client row
-- Steps 2 and 3 must run in this order due to the FK constraint.

WITH keep AS (
  SELECT client_id FROM clients
  WHERE client_name = 'SocialBrand'
  ORDER BY created_at ASC
  LIMIT 1
)
DELETE FROM stores
WHERE client_id NOT IN (SELECT client_id FROM keep)
  AND client_id IN (SELECT client_id FROM clients WHERE client_name = 'SocialBrand');

WITH keep AS (
  SELECT client_id FROM clients
  WHERE client_name = 'SocialBrand'
  ORDER BY created_at ASC
  LIMIT 1
)
DELETE FROM clients
WHERE client_name = 'SocialBrand'
  AND client_id NOT IN (SELECT client_id FROM keep);

-- Step 4: Apply all correct sigma_server values
UPDATE stores SET sigma_server = 'SRSDELAREYVILES' WHERE store_code = '10116';
UPDATE stores SET sigma_server = 'SRSROOSVILLESVR' WHERE store_code = '80175';
UPDATE stores SET sigma_server = 'SRTDELAREYVILSV' WHERE store_code = '21355';
UPDATE stores SET sigma_server = 'SRSDELAREYT2SVR' WHERE store_code = '80579';
UPDATE stores SET sigma_server = 'SRTROOSVILLESVR' WHERE store_code = '80176';

-- Step 5: Verify — must return exactly 5 rows, all OK
SELECT store_code, store_name, store_type, sigma_server,
       CASE WHEN sigma_server IS NULL THEN '*** MISSING ***' ELSE 'OK' END AS status
FROM stores
ORDER BY store_code;
