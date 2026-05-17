-- Verify all stores have a sigma_server value
SELECT store_code, store_name, store_type, sigma_server,
       CASE WHEN sigma_server IS NULL THEN '*** MISSING ***' ELSE 'OK' END AS status
FROM stores
ORDER BY store_code;
