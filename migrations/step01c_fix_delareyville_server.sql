-- =============================================================================
-- SB-AP-002 Step 1c — Correct sigma_server for Delareyville stores
-- Discovery doc had SRTDELAREYVILSV — actual hostname is SRSDELAREYVILES
-- =============================================================================

UPDATE stores SET sigma_server = 'SRSDELAREYVILES' WHERE store_code = '10116';

-- NOTE: TOPS Delareyville (21355) was also listed as SRTDELAREYVILSV in the design doc.
-- If TOPS Delareyville runs on the same physical server as SPAR Delareyville,
-- uncomment the line below. If it has its own server, confirm that hostname separately.
-- UPDATE stores SET sigma_server = 'SRSDELAREYVILES' WHERE store_code = '21355';

-- Verify — all 5 stores
SELECT store_code, store_name, store_type, sigma_server
FROM stores
ORDER BY store_code;
