-- =============================================================================
-- create_rpc_product_detail.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 8.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 / fix_rpc_product_detail_pricing.sql.
-- =============================================================================
-- WHY:
--   Function read directly FROM daily_snapshots by EAN + store + date. Frozen
--   at 2026-06-28; returns nothing for dates >= 2026-06-29.
--
-- WHAT CHANGES:
--   today_qty, today_sales, today_cost: sigma_sales aggregated per
--     (store, sale_date) via v_ean_bridge product_code.
--   soh: l2_soh_daily aggregated per (store, snapshot_date) via bridge.
--   sell_price: sigma_articles.sell_price_incl_vat (includes VAT; best available
--     from sigma -- naming preserved as sell_price for zero client breakage).
--   unit_cost: l2_stock_position.unit_cost (always-latest; same accepted
--     limitation as rpc_dept_summary capital_tied).
--   vat_pct: NULL -- sigma_articles has vat_code (smallint) not a % value, and
--     no vat_codes lookup table exists. R22: surface NULL not a fabricated 15.
--     Client already handles NULL here (COALESCE(vat_pct, 15) in rpc_focus_chart
--     shows this pattern was already defensive).
--   store_name: from stores.
--   daily_snapshots dependency dropped entirely.
--
-- SIGNATURE: unchanged -- zero client breakage.
-- GRANT: anon + authenticated EXECUTE.
-- Rule 19: DROP + clean CREATE.
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_product_detail(text, text[], text[]);

CREATE OR REPLACE FUNCTION public.rpc_product_detail(
  p_ean         text,
  p_store_codes text[],
  p_dates       text[]
)
RETURNS TABLE(
  snapshot_date text,
  store_code    text,
  store_name    text,
  today_qty     numeric,
  today_sales   numeric,
  today_cost    numeric,
  soh           numeric,
  sell_price    numeric,
  unit_cost     numeric,
  vat_pct       numeric
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_dates date[] := p_dates::date[];
BEGIN
  RETURN QUERY
  WITH bridge AS (
    SELECT b.store_code, b.product_code
    FROM   public.v_ean_bridge b
    WHERE  b.store_code = ANY(p_store_codes)
      AND  b.ean        = p_ean
  ),
  sales_day AS (
    SELECT
      ss.store_code,
      ss.sale_date,
      round(sum(ss.qty),             2) AS today_qty,
      round(sum(ss.sales_incl_vat),  2) AS today_sales,
      round(sum(ss.cost_value),      2) AS today_cost
    FROM   public.sigma_sales ss
    JOIN   bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    WHERE  ss.sale_date   = ANY(v_dates)
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
    GROUP  BY ss.store_code, ss.sale_date
  ),
  soh_day AS (
    SELECT
      ls.store_code,
      ls.snapshot_date,
      sum(ls.soh) AS soh
    FROM   public.l2_soh_daily ls
    JOIN   bridge b ON b.store_code = ls.store_code AND b.product_code = ls.product_code
    WHERE  ls.snapshot_date = ANY(v_dates)
    GROUP  BY ls.store_code, ls.snapshot_date
  )
  SELECT
    sd.sale_date::text             AS snapshot_date,
    sd.store_code,
    s.store_name,
    sd.today_qty,
    sd.today_sales,
    sd.today_cost,
    soh.soh,
    a.sell_price_incl_vat          AS sell_price,
    sp.unit_cost,
    NULL::numeric                  AS vat_pct
  FROM   sales_day sd
  LEFT JOIN public.stores s
    ON   s.store_code = sd.store_code
  LEFT JOIN bridge b
    ON   b.store_code = sd.store_code
  LEFT JOIN public.sigma_articles a
    ON   a.store_code   = sd.store_code
    AND  a.product_code = b.product_code
  LEFT JOIN public.l2_stock_position sp
    ON   sp.store_code   = sd.store_code
    AND  sp.product_code = b.product_code
  LEFT JOIN soh_day soh
    ON   soh.store_code    = sd.store_code
    AND  soh.snapshot_date = sd.sale_date
  ORDER BY sd.sale_date ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_product_detail(text, text[], text[]) TO anon, authenticated;
