-- =============================================================================
-- create_classify_snapshot_item.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for
-- classify_snapshot_item. DDL previously lived only inside the sb_ap_004_c_*
-- multi-object sediment files. Extracted verbatim from LIVE 2026-06-17.
--
-- TWO OVERLOADS exist live and are BOTH captured (faithful):
--   * 3-arg (p_dept,p_subdept,p_soh)            -- IMMUTABLE, older
--   * 4-arg (...,p_last_sold date DEFAULT NULL)  -- STABLE, current (never-sold rule)
-- Whether to retire the 3-arg overload is a behaviour decision for PM (dropping a
-- function changes call resolution) -- NOT done here. Both reconciled to live.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.classify_snapshot_item(p_dept text, p_subdept text, p_soh numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT CASE

        -- NON_STOCK: entire dept is non-stock (store expense / admin).
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'EXPENSES',
            'FRONTEND PACK',
            'NON SCAN SALES',
            'AIRTIME',
            'SPAR MOBILE',
            'ONLINE VAS PRODUCTS',
            'ONLINE TRANSACTIONS',
            'DC - SPECIAL PROMOTIONS',
            'DEPARTMENT OVERS/UNDERS'
        ) THEN 'NON_STOCK'

        -- NON_STOCK: sub-dept keyword signals (store-use, unambiguous).
        WHEN COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
          OR COALESCE(p_subdept, '') ILIKE '%CRATE%'
          OR COALESCE(p_subdept, '') ILIKE '%ADVERTISING%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK & WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK&WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        THEN 'NON_STOCK'

        -- PRODUCTION: production dept + sub-dept structural signals. BUY OUT excluded.
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND (
               COALESCE(p_subdept, '') ILIKE '%PRODUCTION%'
            OR COALESCE(p_subdept, '') ILIKE '%(PRODUCTI%'
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%CATERING%'
            OR COALESCE(p_subdept, '') ILIKE '%SCALE PRODUCT%'
            OR COALESCE(p_subdept, '') ILIKE '%WASTAGE%'
         )
        THEN 'PRODUCTION'

        -- RECEIPTING_BREAK: large negative SOH (flagged for Stock Integrity).
        WHEN COALESCE(p_soh, 0) < -50 THEN 'RECEIPTING_BREAK'

        ELSE NULL

    END;
$function$;

CREATE OR REPLACE FUNCTION public.classify_snapshot_item(p_dept text, p_subdept text, p_soh numeric, p_last_sold date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
    SELECT CASE

        -- NON_STOCK: entire dept is non-stock
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'EXPENSES', 'FRONTEND PACK', 'NON SCAN SALES', 'AIRTIME',
            'SPAR MOBILE', 'ONLINE VAS PRODUCTS', 'ONLINE TRANSACTIONS',
            'DC - SPECIAL PROMOTIONS', 'DEPARTMENT OVERS/UNDERS'
        ) THEN 'NON_STOCK'

        -- NON_STOCK: sub-dept keyword (store-use, unambiguous)
        WHEN COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
          OR COALESCE(p_subdept, '') ILIKE '%CRATE%'
          OR COALESCE(p_subdept, '') ILIKE '%ADVERTISING%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK & WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%PACK&WRAP%'
          OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        THEN 'NON_STOCK'

        -- PRODUCTION: sub-dept keyword signal
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND (
               COALESCE(p_subdept, '') ILIKE '%PRODUCTION%'
            OR COALESCE(p_subdept, '') ILIKE '%(PRODUCTI%'
            OR COALESCE(p_subdept, '') ILIKE '%(PROD%'       -- catches 30-char truncations
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%CATERING%'
            OR COALESCE(p_subdept, '') ILIKE '%SCALE PRODUCT%'
            OR COALESCE(p_subdept, '') ILIKE '%WASTAGE%'
         )
        THEN 'PRODUCTION'

        -- PRODUCTION: never-sold in a production dept (Bucket 3b)
        WHEN UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'COFFEE SHOP', 'COFFEE', 'SEAFOOD', 'FISH SHOP', 'FISH'
        )
         AND p_last_sold IS NULL
        THEN 'PRODUCTION'

        -- RECEIPTING_BREAK: large negative SOH
        WHEN COALESCE(p_soh, 0) < -50 THEN 'RECEIPTING_BREAK'

        ELSE NULL

    END;
$function$;
