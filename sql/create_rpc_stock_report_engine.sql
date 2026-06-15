-- =============================================================================
-- create_rpc_stock_report_engine.sql
-- SB-CC-DASH-SOURCE-003 Phase A -- engine-backed stock-report source.
-- Deployed live via MCP migration dash_source_003_rpc_stock_report_engine.
-- =============================================================================
-- One row per flagged article from l2_stock_position (the Sigma-native stock
-- engine), bridged to the canonical EAN via v_ean_bridge. LEFT JOIN the bridge
-- so unbridged rows return ean=NULL -- the frontend excludes them from the table
-- and footnotes the count (never a silent drop, R22/R23). The documented ~3%
-- ean-over-product_code tail is the accepted caveat (R26; re-key = page change,
-- out of scope).
--
-- Reusable across the stock-report arc via p_signal:
--   slowmovers -> slow_mover_signal  (RULE-BOOK §5 KPI 4: soh>0, no sale 14d,
--                                     sold within 364d -- the corrected engine signal)
--   negsoh     -> soh < 0            (canon §5 KPI 5, all classes)
--   ghost      -> ghost_stock_flag
--   stale      -> stale_ledger_flag
--   oos        -> reorder_signal
--
-- CAPITAL TIED REPORT NOTE: do NOT total capital_value from this RPC. The Capital
-- Tied report must read v_l2_capital_by_store (purified bucket, R10.3M -- the same
-- source behind the dashboard tile). Do not fork a second capital number.
--
-- Function-change protocol (RULE-BOOK §8): single signature, DROP + CREATE,
-- reload schema. SECURITY DEFINER, anon + authenticated EXECUTE.
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_stock_report_engine(text[], text);

CREATE FUNCTION public.rpc_stock_report_engine(p_store_codes text[], p_signal text)
RETURNS TABLE(
  store_code text, store_name text, product_code bigint, ean text,
  description text, dept_name text, subdept_name text,
  soh numeric, unit_cost numeric, capital_value numeric,
  days_cover numeric, daily_ros numeric, last_sale_date date,
  sell_price numeric, class text, tier text
)
LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  SELECT sp.store_code, st.store_name, sp.product_code, b.ean,
         sp.description, sp.dept_name, sp.subdept_name,
         sp.soh, sp.unit_cost, sp.capital_value,
         sp.days_cover, sp.daily_ros, sp.last_sale_date,
         sp.sell_price_incl_vat, sp.class, sp.tier
  FROM l2_stock_position sp
  LEFT JOIN v_ean_bridge b ON b.store_code = sp.store_code AND b.product_code = sp.product_code
  LEFT JOIN stores st       ON st.store_code = sp.store_code
  WHERE sp.store_code = ANY(p_store_codes)
    AND CASE p_signal
          WHEN 'slowmovers' THEN sp.slow_mover_signal
          WHEN 'negsoh'     THEN sp.soh < 0
          WHEN 'ghost'      THEN sp.ghost_stock_flag
          WHEN 'stale'      THEN sp.stale_ledger_flag
          WHEN 'oos'        THEN sp.reorder_signal
          ELSE false
        END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_stock_report_engine(text[], text) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');
