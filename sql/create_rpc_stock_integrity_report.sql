-- =============================================================================
-- create_rpc_stock_integrity_report.sql
-- Drawer "Stock Integrity" report (SB-AP-004 C / RPT-001).
-- =============================================================================
-- RETIRE-003 / CC-BRIEF-DASH-FINAL-001 item 4 (2026-07-05):
--   Rewritten OFF frozen daily_snapshots (0 rows on any date >= 29 Jun) ONTO the
--   always-latest, sigma-native engine (l2_stock_position). Applied live
--   (migration dashfinal_ghost_integrity_reports_engine). Output signature
--   UNCHANGED. Prior canonical (SB-CC-RECONCILE-001, daily_snapshots) superseded;
--   history in git.
--
-- WHAT IT SURFACES (two integrity signals):
--   RECEIPTING_BREAK -- SOH sold through past -50 with no GRV booked (soh < -50).
--   FRESH_IMPOSSIBLE -- fresh perishable holding SOH with no sale in 30+ days.
--     is_fresh_perishable(dept_name, subdept_name) reads the same sigma dept /
--     subdept names it read on daily_snapshots. Only SPAR stores carry fresh
--     depts (10116/80175); TOPS liquor stores correctly return none.
--
-- p_date: signature compatibility only (engine has no historical date dimension).
--
-- R22 (2026-07-05, latest position x5): RECEIPTING_BREAK 84/9/22/8/5,
--   FRESH_IMPOSSIBLE 154/0/78/0/0 -- reconciles to the direct l2_stock_position
--   filters (soh<-50; fresh + soh>0 + no sale 30d).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_stock_integrity_report(p_store_codes text[], p_date text)
 RETURNS TABLE(store_code text, store_name text, ean text, description text, dept_name text, sub_dept_name text, soh numeric, sell_price numeric, integrity_type text, days_no_sale integer, value_at_risk numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET statement_timeout TO '15s'
AS $function$
  -- RECEIPTING_BREAK: SOH sold through past -50 with no GRV booked
  SELECT
    sp.store_code,
    st.store_name,
    b.ean,
    sp.description,
    sp.dept_name,
    sp.subdept_name                                            AS sub_dept_name,
    sp.soh,
    sp.sell_price_incl_vat                                     AS sell_price,
    'RECEIPTING_BREAK'::text                                   AS integrity_type,
    NULL::int                                                  AS days_no_sale,
    ROUND((ABS(sp.soh) * COALESCE(sp.sell_price_incl_vat,0))::numeric, 2) AS value_at_risk
  FROM public.l2_stock_position sp
  LEFT JOIN public.v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
  LEFT JOIN public.stores st      ON st.store_code = sp.store_code
  WHERE sp.store_code = ANY(p_store_codes)
    AND sp.soh < -50

  UNION ALL

  -- FRESH_IMPOSSIBLE: fresh perishable holding SOH but no sale in 30+ days
  SELECT
    sp.store_code,
    st.store_name,
    b.ean,
    sp.description,
    sp.dept_name,
    sp.subdept_name                                            AS sub_dept_name,
    sp.soh,
    sp.sell_price_incl_vat                                     AS sell_price,
    'FRESH_IMPOSSIBLE'::text                                   AS integrity_type,
    (CURRENT_DATE - sp.last_sale_date)::int                    AS days_no_sale,
    ROUND((sp.soh * COALESCE(sp.sell_price_incl_vat,0))::numeric, 2) AS value_at_risk
  FROM public.l2_stock_position sp
  LEFT JOIN public.v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
  LEFT JOIN public.stores st      ON st.store_code = sp.store_code
  WHERE sp.store_code = ANY(p_store_codes)
    AND sp.soh > 0
    AND is_fresh_perishable(sp.dept_name, sp.subdept_name)
    AND (sp.last_sale_date IS NULL OR sp.last_sale_date < CURRENT_DATE - INTERVAL '30 days')

  ORDER BY integrity_type, value_at_risk DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_stock_integrity_report(text[], text) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
