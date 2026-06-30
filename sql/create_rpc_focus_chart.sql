-- =============================================================================
-- create_rpc_focus_chart.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 5.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 / SB-CC-VAT-GAP1-001 (2026-06-20).
-- =============================================================================
-- WHY:
--   Prior version was hybrid: sigma_sales (sigma_side) FULL OUTER JOIN
--   daily_snapshots (snap_side). snap_side provided SOH + description/size/unit
--   fallbacks + PRSSALE sales fallback for missed-EOD days. With daily_snapshots
--   frozen at 2026-06-28, snap_side returns nothing for dates >= 2026-06-29,
--   so the FULL OUTER JOIN collapses to sigma_side only anyway -- but SOH
--   surfaces as NULL because sn.soh was the only SOH source.
--
-- WHAT CHANGES:
--   snap_side (daily_snapshots) dropped entirely.
--   sigma_side remains the driver (unchanged logic).
--   SOH: NOW from l2_soh_daily -- aggregated per (store, ean, date) via bridge.
--   description/size/unit: from sigma_articles (a) and product_catalog (pc) --
--     these LEFT JOINs already existed in the old SELECT; snap_side was a
--     fallback only. COALESCE order adjusted: a -> pc (snap_side removed).
--   today_sales_ex_vat: sigma native SUM(sales_incl_vat - vat_value) -- unchanged.
--   FULL OUTER JOIN removed (snap_side gone); sigma_side is now a plain FROM.
--   PRSSALE sales fallback removed (snap_sales/snap_qty COALESCEs gone).
--   daily_snapshots dependency dropped entirely.
--
-- NULLS (R22): SOH NULL for dates before l2_soh_daily floor (2026-06-11 x4
--   stores, 2026-06-21 for 80579). No data rows returned for dates/EANs with
--   no sigma_sales transactions (same as before -- sigma_side was already the
--   effective driver for post-06-28 dates).
--
-- SIGNATURE: unchanged -- zero client breakage.
-- GRANT: anon + authenticated EXECUTE.
-- Rule 19: DROP + clean CREATE (CASCADE on old DROP to clear prior version).
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_focus_chart(text[], text[], text[]) CASCADE;

CREATE OR REPLACE FUNCTION public.rpc_focus_chart(
  p_eans        text[],
  p_store_codes text[],
  p_dates       text[]
)
RETURNS TABLE(
  ean                text,
  description        text,
  size               text,
  unit               text,
  snapshot_date      text,
  store_code         text,
  today_sales        numeric,
  today_sales_ex_vat numeric,
  today_qty          numeric,
  soh                numeric
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_dates date[] := p_dates::date[];
BEGIN
  RETURN QUERY
  WITH bridge AS (
    SELECT b.ean, b.store_code, b.product_code
    FROM   public.v_ean_bridge b
    WHERE  b.store_code = ANY(p_store_codes)
      AND  b.ean        = ANY(p_eans)
  ),
  sigma_side AS (
    SELECT
      b.ean,
      ss.store_code,
      ss.sale_date,
      SUM(ss.sales_incl_vat)                               AS sig_sales,
      SUM(ss.sales_incl_vat - COALESCE(ss.vat_value, 0))  AS sig_sales_ex_vat,
      SUM(ss.qty)                                          AS sig_qty
    FROM   public.sigma_sales ss
    JOIN   bridge b ON b.store_code = ss.store_code AND b.product_code = ss.product_code
    WHERE  ss.store_code  = ANY(p_store_codes)
      AND  ss.sale_date   = ANY(v_dates)
      AND  ss.period_kind = 'T' AND ss.txn_kind = 1
    GROUP  BY b.ean, ss.store_code, ss.sale_date
  ),
  soh_side AS (
    SELECT
      b.ean,
      ls.store_code,
      ls.snapshot_date,
      SUM(ls.soh) AS soh
    FROM   public.l2_soh_daily ls
    JOIN   bridge b ON b.store_code = ls.store_code AND b.product_code = ls.product_code
    WHERE  ls.snapshot_date = ANY(v_dates)
    GROUP  BY b.ean, ls.store_code, ls.snapshot_date
  )
  SELECT
    sg.ean,
    COALESCE(a.description,  pc.description)  AS description,
    pc.size_label                             AS size,
    COALESCE(a.unit,         pc.detail_unit)  AS unit,
    sg.sale_date::text                        AS snapshot_date,
    sg.store_code,
    ROUND(sg.sig_sales::numeric,     2)       AS today_sales,
    ROUND(sg.sig_sales_ex_vat::numeric, 2)    AS today_sales_ex_vat,
    sg.sig_qty::numeric                       AS today_qty,
    soh.soh::numeric                          AS soh
  FROM   sigma_side sg
  LEFT JOIN public.v_ean_bridge bb
    ON  bb.ean        = sg.ean
    AND bb.store_code = sg.store_code
  LEFT JOIN public.sigma_articles a
    ON  a.store_code   = sg.store_code
    AND a.product_code = bb.product_code
  LEFT JOIN public.product_catalog pc
    ON  pc.store_code = sg.store_code
    AND pc.ean        = sg.ean
  LEFT JOIN soh_side soh
    ON  soh.ean           = sg.ean
    AND soh.store_code    = sg.store_code
    AND soh.snapshot_date = sg.sale_date
  ORDER BY sg.sale_date ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_focus_chart(text[], text[], text[]) TO anon, authenticated;
