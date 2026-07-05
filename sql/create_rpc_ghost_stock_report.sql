-- =============================================================================
-- create_rpc_ghost_stock_report.sql
-- Drawer "Ghost Stock" report (SB-AP-004 C).
-- =============================================================================
-- RETIRE-003 / CC-BRIEF-DASH-FINAL-001 item 4 (2026-07-05):
--   Rewritten OFF frozen daily_snapshots (0 rows on any date >= 29 Jun) ONTO the
--   always-latest, sigma-native engine (l2_stock_position). Applied live
--   (migration dashfinal_ghost_integrity_reports_engine). Output signature
--   UNCHANGED -- the frontend column map (handleReportCardClick) is untouched.
--   Prior canonical (SB-CC-RECONCILE-001, daily_snapshots + classify_snapshot_item)
--   is superseded; history in git.
--
-- WHAT IT SURFACES:
--   Production + non-stock stock that carries capital (SOH > 0, capital_value > 0)
--   -- stock the engine has classified as NOT real sellable capital. The engine
--   class verdict (l2_stock_position.class, from l2_item_classification) replaces
--   the old classify_snapshot_item() over daily_snapshots.
--   exclusion_class = the engine class; ghost_value = engine capital_value.
--   Fresh-impossible perishable moved WHOLLY to rpc_stock_integrity_report
--   (it was duplicated across both reports on the daily_snapshots versions).
--
-- p_date: accepted for signature compatibility only. The engine has no historical
--   date dimension (one latest position per store); the frozen table this
--   replaced returned nothing for current dates regardless.
--
-- R22 (2026-07-05, latest position x5): ghost rows 281/15/185/13/23,
--   ghost capital R4.25M/R0.04M/R3.75M/R0.03M/R0.05M -- reconciles to the direct
--   l2_stock_position filter (class IN PRODUCTION/NON_STOCK, soh>0, capital>0).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_ghost_stock_report(p_store_codes text[], p_date text)
 RETURNS TABLE(store_code text, store_name text, ean text, description text, dept_name text, sub_dept_name text, soh numeric, unit_cost numeric, ghost_value numeric, exclusion_class text, score integer, why_flagged text, confirmed_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  SELECT
    sp.store_code,
    st.store_name,
    b.ean,
    sp.description,
    sp.dept_name,
    sp.subdept_name                                         AS sub_dept_name,
    sp.soh,
    sp.unit_cost,
    ROUND(sp.capital_value::numeric, 2)                     AS ghost_value,
    sp.class                                                AS exclusion_class,
    NULL::int                                               AS score,
    'dept=' || COALESCE(sp.dept_name,'') || ' sub=' || COALESCE(sp.subdept_name,'')
      || CASE sp.class
           WHEN 'PRODUCTION' THEN ' | made-in-store / production stock -- SOH is a recipe by-product'
           WHEN 'NON_STOCK'  THEN ' | non-stock / store-use line carrying value'
           ELSE ' | engine-excluded stock'
         END                                                AS why_flagged,
    NULL::text                                              AS confirmed_by
  FROM public.l2_stock_position sp
  LEFT JOIN public.v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
  LEFT JOIN public.stores st      ON st.store_code = sp.store_code
  WHERE sp.store_code = ANY(p_store_codes)
    AND sp.class IN ('PRODUCTION','NON_STOCK')
    AND sp.soh > 0
    AND sp.capital_value > 0
  ORDER BY ghost_value DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_ghost_stock_report(text[], text) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
