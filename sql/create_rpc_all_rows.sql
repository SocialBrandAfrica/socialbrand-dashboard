-- =============================================================================
-- create_rpc_all_rows.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 1, object 10.
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 (daily_snapshots paginated dump).
--
-- *** RETIRED AS THE REPORTS-DRAWER LOADER 2026-07-05 (R28 lineage). ***
-- Successor: rpc_report_rows (sql/create_rpc_report_rows.sql,
-- CC-BRIEF-DASH-FINAL-001 item 1). This function's sigma_articles x dates
-- driver joined ~1.1M rows and re-ran the full computation per 1,000-row page
-- (measured 27,760 ms/page 2026-07-05 vs the authenticator 8s timeout -- every
-- drawer call died). Function stays live in the DB, no frontend consumer;
-- drop is a PM/Pieter call.
-- =============================================================================
-- WHY:
--   Old function: SELECT * FROM daily_snapshots WHERE snapshot_date::text = ANY(p_dates).
--   daily_snapshots frozen at 2026-06-28; any date >= 2026-06-29 returns 0 rows.
--
-- WHAT CHANGES (PM-signed column map 2026-06-30):
--   Driver: sigma_articles x UNNEST(p_dates::date[]) -- preserves multi-date array
--     signature; a (store, product, date) triple is one output row.
--   ean: LEFT JOIN v_ean_bridge + COALESCE synthetic fallback (R20 addendum).
--   today_*: sigma_sales for sale_date = d.date_val (period_kind='T', txn_kind=1).
--   period_*: sigma_sales MTD -- date_trunc('month', d.date_val)::date to d.date_val.
--     Each date in p_dates gets its own correct MTD window.
--   soh: l2_soh_daily keyed on snapshot_date = d.date_val (R22 -- date-specific SOH,
--     no fabrication). NULL for dates before the ingestion floor (~11 Jun). Matches
--     v_kpi_by_date exactly. unit_cost: l2_stock_position (current -- no date history).
--   dept_code: LPAD(department_nr::text, 6, '0') -- 6-wide zero-padded to match
--     live daily_snapshots format ("000001"). Verified on frozen 28-Jun rows.
--   sub_dept_code: LPAD(merch_group_nr::text, 9, '0') -- 9-wide ("000000101").
--   dept_name: COALESCE(sd.name, 'UNMAPPED').
--   sub_dept_name: COALESCE(sub.name, 'UNMAPPED') -- added per PM ruling.
--   internal_ref: product_code::text (Sigma article number).
--   size: pack_content::text.
--   status: record_status.
--   sell_price: sell_price_incl_vat.
--   last_sales_date_iso: l2_rate_of_sale.last_sale_date::text.
--   vat_pct: NULL::numeric -- sigma_articles has vat_code (smallint type code),
--     no % value. Logged as R23 L1 gap (mislabels zero-rated lines). Same
--     precedent as rpc_product_detail. Client coalesces to 15% default.
--   is_placeholder: NULL::boolean -- concept retired with daily_snapshots.
--   store_name: stores.store_name.
--   daily_snapshots dependency dropped entirely.
--
-- SYNTHETIC EAN fallback: LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')
--   matches old daily_snapshots PLU-expansion convention (13 chars, R20 addendum).
--
-- SIGNATURE: unchanged (p_store_codes, p_dates, p_from, p_limit).
--   Index note: prior function used snapshot_date::text = ANY(p_dates) (index-
--   defeating cast, R26 capture). New function casts p_dates to date[] once and
--   joins on typed date columns -- index-safe on sigma_sales(store_code, sale_date)
--   and l2_soh_daily(store_code, snapshot_date).
--
-- R22 acceptance on apply:
--   MTD period_sales ties to sigma_sales direct SUM x5 for the queried date.
--   SOH spot-check: a historical date row ties to l2_soh_daily for that date x1+.
-- GRANT: anon + authenticated EXECUTE.
-- Function change protocol: DROP before CREATE (no overload -- single signature).
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_all_rows(text[], text[], integer, integer);

CREATE FUNCTION public.rpc_all_rows(
  p_store_codes  text[],
  p_dates        text[],
  p_from         integer DEFAULT 0,
  p_limit        integer DEFAULT 1000
)
RETURNS TABLE(
  ean                  text,
  description          text,
  size                 text,
  unit                 text,
  sell_price           numeric,
  vat_pct              numeric,
  today_qty            numeric,
  today_cost           numeric,
  today_sales          numeric,
  period_qty           numeric,
  period_cost          numeric,
  period_sales         numeric,
  soh                  numeric,
  dept_code            text,
  dept_name            text,
  sub_dept_code        text,
  sub_dept_name        text,
  internal_ref         text,
  status               text,
  last_sales_date_iso  text,
  is_placeholder       boolean,
  snapshot_date        text,
  store_code           text,
  store_name           text,
  unit_cost            numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $function$
WITH
today_s AS (
  SELECT
    ss.store_code,
    ss.product_code,
    ss.sale_date,
    round(sum(ss.qty),            2) AS today_qty,
    round(sum(ss.cost_value),     2) AS today_cost,
    round(sum(ss.sales_incl_vat), 2) AS today_sales
  FROM public.sigma_sales ss
  WHERE ss.store_code  = ANY(p_store_codes)
    AND ss.sale_date   = ANY(p_dates::date[])
    AND ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY ss.store_code, ss.product_code, ss.sale_date
),
period_s AS (
  SELECT
    ss.store_code,
    ss.product_code,
    d.date_val,
    round(sum(ss.qty),            2) AS period_qty,
    round(sum(ss.cost_value),     2) AS period_cost,
    round(sum(ss.sales_incl_vat), 2) AS period_sales
  FROM public.sigma_sales ss
  CROSS JOIN UNNEST(p_dates::date[]) AS d(date_val)
  WHERE ss.store_code  = ANY(p_store_codes)
    AND ss.sale_date   BETWEEN date_trunc('month', d.date_val)::date AND d.date_val
    AND ss.period_kind = 'T'
    AND ss.txn_kind    = 1
  GROUP BY ss.store_code, ss.product_code, d.date_val
)
SELECT
  COALESCE(b.ean,
    LPAD(a.store_code, 5, '0') || LPAD(a.product_code::text, 8, '0'))    AS ean,
  a.description,
  a.pack_content::text                                                     AS size,
  a.unit,
  a.sell_price_incl_vat                                                    AS sell_price,
  NULL::numeric                                                            AS vat_pct,
  COALESCE(t.today_qty,    0)                                             AS today_qty,
  COALESCE(t.today_cost,   0)                                             AS today_cost,
  COALESCE(t.today_sales,  0)                                             AS today_sales,
  COALESCE(ps.period_qty,  0)                                             AS period_qty,
  COALESCE(ps.period_cost, 0)                                             AS period_cost,
  COALESCE(ps.period_sales,0)                                             AS period_sales,
  ls.soh,
  LPAD(a.department_nr::text,  6, '0')                                    AS dept_code,
  COALESCE(sd.name, 'UNMAPPED')                                           AS dept_name,
  LPAD(a.merch_group_nr::text, 9, '0')                                    AS sub_dept_code,
  COALESCE(sub.name, 'UNMAPPED')                                          AS sub_dept_name,
  a.product_code::text                                                     AS internal_ref,
  a.record_status                                                          AS status,
  ros.last_sale_date::text                                                 AS last_sales_date_iso,
  NULL::boolean                                                            AS is_placeholder,
  d.date_val::text                                                         AS snapshot_date,
  a.store_code,
  st.store_name,
  sp.unit_cost
FROM public.sigma_articles a
CROSS JOIN UNNEST(p_dates::date[]) AS d(date_val)
LEFT JOIN public.v_ean_bridge b
  ON  b.store_code   = a.store_code
  AND b.product_code = a.product_code
LEFT JOIN public.sigma_departments sd
  ON  sd.store_code    = a.store_code
  AND sd.department_nr = a.department_nr
LEFT JOIN public.sigma_subdepts sub
  ON  sub.store_code     = a.store_code
  AND sub.merch_group_nr = a.merch_group_nr
LEFT JOIN public.l2_soh_daily ls
  ON  ls.store_code    = a.store_code
  AND ls.product_code  = a.product_code
  AND ls.snapshot_date = d.date_val
LEFT JOIN public.l2_stock_position sp
  ON  sp.store_code   = a.store_code
  AND sp.product_code = a.product_code
LEFT JOIN public.l2_rate_of_sale ros
  ON  ros.store_code   = a.store_code
  AND ros.product_code = a.product_code
LEFT JOIN public.stores st
  ON  st.store_code = a.store_code
LEFT JOIN today_s t
  ON  t.store_code   = a.store_code
  AND t.product_code = a.product_code
  AND t.sale_date    = d.date_val
LEFT JOIN period_s ps
  ON  ps.store_code   = a.store_code
  AND ps.product_code = a.product_code
  AND ps.date_val     = d.date_val
WHERE a.store_code = ANY(p_store_codes)
ORDER BY a.description, d.date_val
LIMIT  p_limit
OFFSET p_from;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_all_rows(text[], text[], integer, integer)
  TO anon, authenticated;
