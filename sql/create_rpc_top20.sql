-- =============================================================================
-- create_rpc_top20.sql
-- SB-CC-DASH-SOURCE-002 (SB-INDEX-005 Phase 2) -- canonical rpc_top20.
-- Deployed live via Supabase MCP migration dash_source_002_rpc_top20_movers_to_sigma.
-- (Previously the function had no single create file -- only fix_* patches; this
--  is now the source of record. RULE-BOOK R19.)
-- =============================================================================
-- TWO MODES, split on p_activity:
--
--   'movers' (default) -- SALES FACTS -> sigma_sales (DBUMBA exact ledger,
--     missed-EOD complete). total_sales = SUM(sales_incl_vat - vat_value) ex-VAT
--     (same formula as mv_kpi_by_date.total_sales_ex_vat -- reconciles with the
--     KPI strip and Sales Trend on Panel 1/2). total_qty = SUM(qty) selling-units.
--     Output keyed by EAN via the SHARED v_ean_bridge view (one canonical ean per
--     (store, product_code) -- no fan-out; see create_v_ean_bridge.sql).
--     dept/sub-dept resolved sigma-native (sigma_articles -> sigma_departments /
--     sigma_subdepts.name), size/unit from product_catalog / sigma_articles.
--     Returns top-20-by-sales UNION top-20-by-qty. plpgsql pre-cast v_dates so
--     ss.sale_date = ANY(v_dates) keeps idx_sigma_sales_store_date (whole-store,
--     no ean filter = the same seq-scan trap that timed out rpc_focus_top5).
--     p_parents has NO sigma equivalent (the ledger has no placeholder rows) ->
--     no-op in this branch.
--
--   'non_movers' -- STOCK FACTS, HELD on daily_snapshots (soh>0 + period_qty=0
--     + classify_snapshot_item + fresh-perishable guard; total_sales =
--     soh*sell_price = stock value, total_qty = soh). This is the held
--     stock-facts thread -- it migrates with the coordinated stock step, NOT
--     here. Boundary flagged, not crossed.
--
-- Verified live (2026-06-13): movers fan-out delta 0.00 vs once-per-product_code
--   truth (5 stores x 14d, R4,712,543.70); 1.43s; top sellers correct;
--   non_movers unchanged (40 rows). Data unchanged on the held branch.
-- Updated 2026-06-20: movers total_sales -> ex-VAT (Panel 3 R22 -- reconcile
--   with mv_kpi_by_date.total_sales_ex_vat). ON PIETER to apply to live.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_top20(
    p_store_codes text[],
    p_dates       text[],
    p_dept        text DEFAULT NULL,
    p_subdept     text DEFAULT NULL,
    p_eans        text[] DEFAULT NULL,
    p_activity    text DEFAULT 'movers',
    p_parents     boolean DEFAULT false
)
RETURNS TABLE(ean text, description text, dept_name text, sub_dept_name text, size text, unit text, total_sales numeric, total_qty numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_dates date[] := p_dates::date[];   -- pre-cast ONCE (index-safe)
BEGIN

  IF COALESCE(p_activity, 'movers') = 'non_movers' THEN
    -- STOCK FACTS (held): soh / period_qty=0 / classification stay on daily_snapshots.
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
            AND s.snapshot_date  = ANY(v_dates)
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
    -- SALES FACTS -> sigma_sales, ean-keyed via shared v_ean_bridge.
    RETURN QUERY
      WITH agg AS MATERIALIZED (
          SELECT
              b.ean,
              MAX(COALESCE(a.description, a.short_description)) AS description,
              MAX(COALESCE(sd.name,  'UNMAPPED'))              AS dept_name,
              MAX(COALESCE(sub.name, 'UNMAPPED'))              AS sub_dept_name,
              MAX(pc.size_label)                               AS size,
              MAX(COALESCE(a.unit, pc.detail_unit))            AS unit,
              ROUND(SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0))::numeric, 2) AS total_sales,
              SUM(ss.qty)::numeric                                               AS total_qty
          FROM sigma_sales ss
          JOIN   v_ean_bridge b         ON b.store_code = ss.store_code AND b.product_code = ss.product_code
          LEFT   JOIN sigma_articles a  ON a.store_code = ss.store_code AND a.product_code = ss.product_code
          LEFT   JOIN sigma_departments sd ON sd.store_code = a.store_code AND sd.department_nr = a.department_nr
          LEFT   JOIN sigma_subdepts sub   ON sub.store_code = a.store_code AND sub.merch_group_nr = a.merch_group_nr
          LEFT   JOIN product_catalog pc   ON pc.store_code = ss.store_code AND pc.ean = b.ean
          WHERE ss.store_code   = ANY(p_store_codes)
            AND ss.sale_date    = ANY(v_dates)
            AND ss.period_kind  = 'T' AND ss.txn_kind = 1
            AND ss.sales_incl_vat > 0
            AND (p_dept    IS NULL OR sd.name  = p_dept)
            AND (p_subdept IS NULL OR sub.name = p_subdept)
            AND (p_eans    IS NULL OR b.ean    = ANY(p_eans))
          GROUP BY b.ean
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

GRANT EXECUTE ON FUNCTION public.rpc_top20(text[], text[], text, text, text[], text, boolean) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
