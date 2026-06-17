-- =============================================================================
-- create_v_top_products_by_date.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for v_top_products_by_date.
-- Supersedes fix_top20_subdept.sql (sediment, where the view was first created).
-- Extracted verbatim from LIVE 2026-06-17.
-- =============================================================================
CREATE OR REPLACE VIEW public.v_top_products_by_date AS
 SELECT store_code,
    snapshot_date,
    ean,
    description,
    dept_name,
    sub_dept_name,
    today_sales,
    today_qty,
    rank() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_sales DESC) AS rank_by_sales,
    rank() OVER (PARTITION BY store_code, snapshot_date ORDER BY today_qty DESC) AS rank_by_qty
   FROM daily_snapshots
  WHERE today_sales > 0::numeric;
