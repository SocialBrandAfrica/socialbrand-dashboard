-- =============================================================================
-- create_is_fresh_perishable.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for is_fresh_perishable.
-- DDL previously lived only inside sb_ap_004_c_interim_exclusion.sql (sediment).
-- Extracted verbatim from LIVE 2026-06-17.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_fresh_perishable(p_dept text, p_subdept text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT
        UPPER(COALESCE(p_dept, '')) IN (
            'BAKERY', 'BUTCHERY', 'HMR', 'DELI', 'DELICATESSEN',
            'PRODUCE', 'PERISHABLES', 'FISH SHOP', 'FISH', 'SEAFOOD',
            'FLOWERS', 'COFFEE SHOP'
        )
        AND NOT (
               COALESCE(p_subdept, '') ILIKE '%FROZEN%'
            OR COALESCE(p_subdept, '') ILIKE '%ICE CREAM%'
            OR COALESCE(p_subdept, '') ILIKE '%LONG LIFE%'
            OR COALESCE(p_subdept, '') ILIKE '%CANNED%'
            OR COALESCE(p_subdept, '') ILIKE '%TINNED%'
            OR COALESCE(p_subdept, '') ILIKE '%PACKAGING%'
            OR COALESCE(p_subdept, '') ILIKE '%INGREDIENTS%'
            OR COALESCE(p_subdept, '') ILIKE '%BUY OUT%'
            OR COALESCE(p_subdept, '') ILIKE '%PREPACKED%'
            OR COALESCE(p_subdept, '') ILIKE '%CONFECTIONARY%'
            OR COALESCE(p_subdept, '') ILIKE '%RUSKS%'
            OR COALESCE(p_subdept, '') ILIKE '%BISCUITS%'
            OR COALESCE(p_subdept, '') ILIKE '%FUTURE USE%'
        );
$function$;
