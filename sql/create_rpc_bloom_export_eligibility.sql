-- =============================================================================
-- create_rpc_bloom_export_eligibility.sql
-- TRACK A ITEM 1 -- the published read interface over l2_export_key.
-- Applied 2026-07-21, migration a1_rpc_bloom_export_eligibility.
--
-- R30: a surface reads a published engine interface, never a base table, and never
-- re-derives identity itself. The three exportTlx() builders call this with the
-- order's own product codes, write the engine's `export_key`, and surface every
-- held-back line WITH its reason -- replacing the dead `if (!l.ean) continue` guard
-- (BUG-LOG ENG-031). An error here BLOCKS the export rather than shipping a guessed
-- file: a TLX built without the verdict is exactly the silent-drop failure the fix
-- exists to end (R22).
--
-- ⚠️ NAMED DEVIATION from PM's wording, flagged not taken silently. PM specified
-- "an engine flag from rpc_bloom_order_recipe". The verdict IS engine-owned and
-- native-sourced exactly as ruled, but it is delivered as its own interface rather
-- than folded into the recipe's row, because adding columns to that function's
-- RETURNS TABLE forces a DROP + CREATE of an 850-line body with five untracked
-- function-to-function callers -- rpc_bloom_scenario_overview, rpc_bloom_stock_state,
-- rpc_bloom_delivery_chain, rpc_bloom_month_projection, rpc_bloom_direct_dc_overlap.
-- Postgres does not record those in pg_depend (canon SS13's read-only class), so
-- nothing would warn us if one broke. That return-type change deserves its own pass
-- with its own R22 rather than being tacked onto the end of this one.
-- FOLDING THE FLAG INTO THE RECIPE ROW REMAINS OWED and is the cleaner end state.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_bloom_export_eligibility(
  p_store_code    text,
  p_product_codes bigint[] DEFAULT NULL   -- NULL = the whole store
)
RETURNS TABLE (
  product_code      bigint,
  export_key        text,
  key_source        text,
  export_eligible   boolean,
  ineligible_reason text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
SET statement_timeout = '15s'
AS $fn$
  SELECT ek.product_code, ek.export_key, ek.key_source, ek.export_eligible, ek.ineligible_reason
  FROM l2_export_key ek
  WHERE ek.store_code = p_store_code
    AND (p_product_codes IS NULL OR ek.product_code = ANY(p_product_codes))
  ORDER BY ek.product_code;
$fn$;

REVOKE ALL ON FUNCTION public.rpc_bloom_export_eligibility(text, bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_export_eligibility(text, bigint[]) TO anon, authenticated;
