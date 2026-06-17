-- SEL-002 FIX -- rpc_subdepts: remove today_sales filter + fix index violation
-- Run in Supabase SQL Editor.
-- BUG-A: today_sales > 0 silently dropped all production sub-depts with zero
--        same-day retail sales (HMR INGREDIENTS, PACKAGING, SMART CHEF, etc.).
-- BUG-B: snapshot_date::text = ANY(p_dates) cast the column, killing the index.
--        Fixed to snapshot_date = ANY(p_dates::date[]).

CREATE OR REPLACE FUNCTION rpc_subdepts(
    p_store_codes  text[],
    p_dates        text[],
    p_dept_names   text[] DEFAULT NULL
)
RETURNS TABLE(sub_dept_name text)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT DISTINCT sub_dept_name
    FROM  daily_snapshots
    WHERE store_code     = ANY(p_store_codes)
      AND snapshot_date  = ANY(p_dates::date[])
      AND is_placeholder = FALSE
      AND sub_dept_name  IS NOT NULL
      AND (p_dept_names IS NULL OR dept_name = ANY(p_dept_names))
    ORDER BY sub_dept_name;
$$;

GRANT EXECUTE ON FUNCTION rpc_subdepts(text[], text[], text[]) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
