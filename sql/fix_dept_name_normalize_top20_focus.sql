-- =============================================================================
-- fix_dept_name_normalize_top20_focus.sql
-- Deployed 2026-06-10 23:0x SAST via Supabase MCP (migration
-- fix_dept_name_normalize_top20_focus_top5). Kept here as canonical source.
-- =============================================================================
-- BUG: the dashboard normalizes dept names for its chips (normalizeDept strips
-- periods), so it sends e.g. 'BOTTLE, CRATES' while daily_snapshots stores
-- 'BOTTLE, CRATES.' (store 80579). rpc_top20 and rpc_focus_top5 compared
-- dept_name with raw equality, so selecting such a dept chip silently emptied
-- the Top 20 and Focus Top-5 panels (no error, no rows -- a silent-empty class
-- violation).
--
-- FIX: dept comparison is now period-insensitive on BOTH sides:
--   TRIM(replace(dept_name,'.','')) = TRIM(replace(p_dept,'.',''))
-- This matches the app's normalizeDept() exactly. Sub-dept comparisons stay
-- raw (no sub-dept names contain periods; the app passes raw values).
--
-- Proof (2026-06-10): rpc_top20('80579','2026-06-09','BOTTLE, CRATES',
-- parents=true) returned 0 before, 1 after. Regressions: HMR/WINE/subdept/
-- non_movers combos unchanged.
--
-- Rule 19: DROP + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS rpc_top20(text[], text[], text, text, text[], text, boolean);

CREATE OR REPLACE FUNCTION public.rpc_top20(
  p_store_codes text[],
  p_dates text[],
  p_dept text DEFAULT NULL::text,
  p_subdept text DEFAULT NULL::text,
  p_eans text[] DEFAULT NULL::text[],
  p_activity text DEFAULT 'movers'::text,
  p_parents boolean DEFAULT false)
RETURNS TABLE(ean text, description text, dept_name text, sub_dept_name text, size text, unit text, total_sales numeric, total_qty numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
BEGIN

  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    RETURN QUERY
      SELECT latest.ean, latest.description, latest.dept_name,
             latest.sub_dept_name, latest.size, latest.unit,
             latest.total_sales, latest.total_qty
      FROM (
          SELECT DISTINCT ON (s.ean)
              s.ean, s.description, s.dept_name, s.sub_dept_name,
              s.size, s.unit,
              ROUND((s.soh * COALESCE(s.sell_price, 0))::numeric, 2) AS total_sales,
              s.soh::numeric                                          AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.soh             > 0
            AND s.period_qty      = 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR TRIM(replace(s.dept_name, '.', '')) = TRIM(replace(p_dept, '.', '')))
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
            AND classify_snapshot_item(s.dept_name, s.sub_dept_name,
                                       s.soh, s.last_sales_date_iso) IS NULL
            AND NOT (
                is_fresh_perishable(s.dept_name, s.sub_dept_name)
                AND (s.last_sales_date_iso IS NULL
                     OR s.last_sales_date_iso < CURRENT_DATE - INTERVAL '30 days')
            )
          ORDER BY s.ean, s.snapshot_date DESC
      ) latest
      ORDER BY latest.total_sales DESC
      LIMIT 40;

  ELSE
    RETURN QUERY
      WITH agg AS MATERIALIZED (
          SELECT
              s.ean,
              MAX(s.description)                     AS description,
              MAX(s.dept_name)                       AS dept_name,
              MAX(s.sub_dept_name)                   AS sub_dept_name,
              MAX(s.size)                            AS size,
              MAX(s.unit)                            AS unit,
              ROUND(SUM(s.today_sales)::numeric, 2)  AS total_sales,
              SUM(s.today_qty)::numeric              AS total_qty
          FROM daily_snapshots s
          WHERE s.store_code    = ANY(p_store_codes)
            AND s.snapshot_date  = ANY(p_dates::date[])
            AND s.today_sales     > 0
            AND (p_parents OR NOT s.is_placeholder)
            AND (p_dept    IS NULL OR TRIM(replace(s.dept_name, '.', '')) = TRIM(replace(p_dept, '.', '')))
            AND (p_subdept IS NULL OR s.sub_dept_name = p_subdept)
            AND (p_eans    IS NULL OR s.ean            = ANY(p_eans))
          GROUP BY s.ean
      )
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_sales DESC LIMIT 20)
      UNION
      (SELECT agg.ean, agg.description, agg.dept_name, agg.sub_dept_name,
              agg.size, agg.unit, agg.total_sales, agg.total_qty
         FROM agg ORDER BY agg.total_qty DESC LIMIT 20);
  END IF;

END;
$function$;

GRANT EXECUTE ON FUNCTION rpc_top20(text[], text[], text, text, text[], text, boolean) TO anon, authenticated;


DROP FUNCTION IF EXISTS rpc_focus_top5(text[], text[], text, text);

CREATE OR REPLACE FUNCTION public.rpc_focus_top5(
  p_store_codes text[],
  p_dates text[],
  p_dept text DEFAULT NULL::text,
  p_subdept text DEFAULT NULL::text)
RETURNS TABLE(ean text, description text, store_code text, dept_name text, sub_dept_name text, period_sales numeric)
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
  SELECT
    ean,
    MAX(description)   AS description,
    store_code,
    MAX(dept_name)     AS dept_name,
    MAX(sub_dept_name) AS sub_dept_name,
    ROUND(SUM(today_sales)::numeric, 2) AS period_sales
  FROM daily_snapshots
  WHERE store_code    = ANY(p_store_codes)
    AND snapshot_date = ANY(p_dates::date[])
    AND today_sales   > 0
    AND (p_dept    IS NULL OR TRIM(replace(dept_name, '.', '')) = TRIM(replace(p_dept, '.', '')))
    AND (p_subdept IS NULL OR sub_dept_name = p_subdept)
  GROUP BY ean, store_code
  ORDER BY period_sales DESC
  LIMIT 50;
$function$;

GRANT EXECUTE ON FUNCTION rpc_focus_top5(text[], text[], text, text) TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');
