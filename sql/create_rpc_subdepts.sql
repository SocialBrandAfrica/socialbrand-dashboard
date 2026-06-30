-- =============================================================================
-- create_rpc_subdepts.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 7.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 / fix_rpc_subdepts_sel002.sql.
-- =============================================================================
-- WHY:
--   Function read DISTINCT sub_dept_name FROM daily_snapshots for the selected
--   store/date. Frozen at 2026-06-28; returns nothing for dates >= 2026-06-29,
--   so the sub-dept filter dropdown is empty on any current-date view.
--
-- WHAT CHANGES:
--   Source: sigma_articles -> sigma_subdepts (for sub_dept_name) filtered by
--     products that had sales on the selected date(s) in sigma_sales.
--   dept_name filter: via sigma_departments join on sigma_articles.department_nr.
--   is_placeholder filter dropped (no equivalent in sigma; real transactions only).
--   Date pre-cast to date[] (index-safe, same pattern as rpc_dept_summary).
--   daily_snapshots dependency dropped entirely.
--
-- BEHAVIOR NOTE: returns sub-depts with actual sales on the date (same intent
--   as prior -- SEL-002 had removed the today_sales>0 filter but the snapshot
--   itself only contained products with activity). If a sub-dept had zero sales
--   on a date but had SOH, it will no longer appear. This is acceptable: the
--   sub-dept filter is for sales drill-down, not stock browsing.
--
-- SIGNATURE: unchanged -- zero client breakage.
-- GRANT: anon + authenticated EXECUTE.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_subdepts(text[], text[], text[]);

CREATE OR REPLACE FUNCTION public.rpc_subdepts(
  p_store_codes text[],
  p_dates       text[],
  p_dept_names  text[] DEFAULT NULL
)
RETURNS TABLE(sub_dept_name text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_dates date[] := p_dates::date[];
BEGIN
  RETURN QUERY
  SELECT DISTINCT sub.name AS sub_dept_name
  FROM   public.sigma_sales ss
  JOIN   public.sigma_articles a
    ON   a.store_code   = ss.store_code
    AND  a.product_code = ss.product_code
  JOIN   public.sigma_subdepts sub
    ON   sub.store_code     = a.store_code
    AND  sub.merch_group_nr = a.merch_group_nr
  LEFT JOIN public.sigma_departments sd
    ON   sd.store_code    = a.store_code
    AND  sd.department_nr = a.department_nr
  WHERE  ss.store_code   = ANY(p_store_codes)
    AND  ss.sale_date     = ANY(v_dates)
    AND  ss.period_kind   = 'T' AND ss.txn_kind = 1
    AND  sub.name         IS NOT NULL
    AND  (p_dept_names IS NULL OR sd.name = ANY(p_dept_names))
  ORDER BY sub_dept_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_subdepts(text[], text[], text[]) TO anon, authenticated;
