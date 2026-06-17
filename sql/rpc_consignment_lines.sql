-- rpc_consignment_lines
-- SB-CC-AUDIT-002 (L2 restructure, 2026-06-08): thin SELECT from l2_consignment_daily.
-- SB-CC-PMINI-WIRE-001 (2026-06-17): + item_type column (engine-stamped, native
--   source); + p_include_catalog flag so the Pulse Mini partner page can derive its
--   "no sales this month" list from this SAME rpc (no base-table access needed).
--   STATUS: STAGED — DO NOT RUN until PM signs the Pulse Mini close-out plan.
--   Requires create_v_consignment_catalog.sql + the updated l2_consignment_daily
--   refresh to be deployed FIRST.
--
-- Classification (sushi 's' / Chinese 'c') is pre-computed in l2_consignment_daily
-- at nightly refresh time (from v_consignment_catalog). This RPC is L3 display:
-- no classification at fetch.
--
-- BACKWARD COMPATIBILITY (important):
--   * The main dashboard ConsignmentPanel.jsx calls rpc_consignment_lines(p_month,
--     p_store) and reads sales/qty/sale_date/description. The new item_type column
--     is additive (ignored there) and p_include_catalog DEFAULTS false, so that
--     panel is byte-for-byte unchanged — sold lines only, same totals.
--   * SECURITY DEFINER: the function reads l2_consignment_daily + v_consignment_catalog
--     as owner, so the restricted partner role needs only EXECUTE on this function
--     (no SELECT on any base table). This is what makes the partner key "consignment
--     only" (SB-CC-PMINI-WIRE-001 Gap B / Route 3).
--
-- p_include_catalog:
--   false (default) -> sold lines only (one row per description per sold day).
--   true            -> ALSO emit one zero row (sale_date NULL, sales/qty 0) per
--                      in-scope group-610 article with NO sale this month, so the
--                      caller can list "no sales" lines without reading sigma_articles.
--
-- Signature note: arg list grows by one optional boolean. Old 4-arg signature is
-- dropped; PostgREST resolves named calls against the 5-arg form via defaults.
-- Pre-June months return 0 sold rows by design (recycled product codes, R20 class).

DROP FUNCTION IF EXISTS rpc_consignment_lines(text, text, integer, text);
DROP FUNCTION IF EXISTS rpc_consignment_lines(text, text, integer, text, boolean);

CREATE FUNCTION rpc_consignment_lines(
  p_month           text,
  p_store           text    DEFAULT '10116',
  p_group           integer DEFAULT 610,
  p_client          text    DEFAULT 'socialbrand',
  p_include_catalog boolean DEFAULT false
)
RETURNS TABLE (
  description text,
  item_type   text,
  sale_date   date,
  sales       numeric,
  qty         numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  -- Sold lines (always). Thin read from l2_consignment_daily; item_type is the
  -- engine-stamped value, so no classification happens at fetch.
  SELECT
    d.description,
    d.item_type,
    d.sale_date,
    SUM(d.sales)::numeric AS sales,
    SUM(d.qty)::numeric   AS qty
  FROM l2_consignment_daily d
  WHERE d.store_code = p_store
    AND d.sale_date BETWEEN
        (p_month || '-01')::date
        AND (date_trunc('month', (p_month || '-01')::date)
             + INTERVAL '1 month - 1 day')::date
  GROUP BY d.description, d.item_type, d.sale_date

  UNION ALL

  -- Catalog (optional). In-scope group-610 articles with NO sale this month,
  -- emitted as zero rows so the partner page can show its "no sales" flag without
  -- touching sigma_articles. Suppressed entirely when p_include_catalog = false.
  SELECT DISTINCT
    cat.description,
    cat.item_type,
    NULL::date  AS sale_date,
    0::numeric  AS sales,
    0::numeric  AS qty
  FROM v_consignment_catalog cat
  WHERE p_include_catalog
    AND cat.store_code = p_store
    AND cat.client_id  = p_client
    AND cat.description NOT IN (
      SELECT d2.description
      FROM l2_consignment_daily d2
      WHERE d2.store_code = p_store
        AND d2.sale_date BETWEEN
            (p_month || '-01')::date
            AND (date_trunc('month', (p_month || '-01')::date)
                 + INTERVAL '1 month - 1 day')::date
    )

  ORDER BY 1, 3;
$$;

-- SECURITY DEFINER function: EXECUTE to anon (shared dashboard path). The restricted
-- partner role is granted EXECUTE separately in pmini_partner_lockdown.sql.
GRANT EXECUTE ON FUNCTION rpc_consignment_lines(text, text, integer, text, boolean)
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Regression checks (run AFTER deploy):
--   1) Sold totals unchanged + item_type now populated (store 10116, June):
--      SELECT COUNT(*) rows, COUNT(DISTINCT description) lines,
--             ROUND(SUM(sales),2) sales,
--             COUNT(*) FILTER (WHERE item_type='s') s_rows,
--             COUNT(*) FILTER (WHERE item_type='c') c_rows
--      FROM rpc_consignment_lines('2026-06', '10116');
--      -- expect sales = 50266.00 (Jun 1-16 snapshot); s_rows > 0 (was 0).
--   2) Catalog mode adds no-sales lines, sold totals identical:
--      SELECT ROUND(SUM(sales),2)
--      FROM rpc_consignment_lines('2026-06','10116',610,'socialbrand',true);
--      -- expect SAME 50266.00 (zero rows add nothing).
--   3) Main-panel call (defaults) returns sold lines only, no NULL sale_date rows:
--      SELECT COUNT(*) FILTER (WHERE sale_date IS NULL)
--      FROM rpc_consignment_lines('2026-06','10116');  -- expect 0.
-- ---------------------------------------------------------------------------
