# SB-CC-SEC-001 Stage 3 — Panel verification checklist

Run this checklist TWICE:
- After Stage 1 (lock list D) — before Stage 2
- After Stage 2 (lock list C) — final sign-off

## R22 acceptance criteria (run in Supabase SQL editor)

```sql
-- Must return "permission denied" or 0 rows after Stage 1:
SELECT * FROM sigma_sales LIMIT 1;

-- Must return "permission denied" or 0 rows after Stage 2:
SELECT * FROM push_log LIMIT 1;
SELECT * FROM product_catalog LIMIT 1;
SELECT * FROM products LIMIT 1;
SELECT * FROM product_search_index LIMIT 1;

-- Must still return data (SECURITY DEFINER bypasses RLS):
SELECT COUNT(*) FROM rpc_bt_scorecard('2026-05');
SELECT COUNT(*) FROM rpc_push_status();
SELECT COUNT(*) FROM rpc_push_available_dates();
```

Note: run as anon role or use the anon key in curl/PostgREST to confirm.

## Timing note (tables are already locked in production)

Run the panel sweep against the LIVE SITE NOW on the anon key, not a preview.
Direct table reads that are already broken: products (Focus drilldown supplier
mode), product_catalog (product detail supplier name). Confirm below.

## Anon-key denial checks (run in terminal with the public anon key)

```bash
ANON="<ANON_KEY>"
URL="https://crklvhfwyxlisfcvqenc.supabase.co/rest/v1"
# Must return [] after Stage 1:
curl "$URL/sigma_sales?select=*&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
curl "$URL/l2_classification?select=*&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
curl "$URL/l2_bt_baseline?select=*&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
# Must return [] after stage2_drop_search_policy.sql is run:
curl "$URL/product_search_index?select=*&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
# Must still return data (SECURITY DEFINER):
curl "$URL/rpc/rpc_push_status" -X POST -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" -d '{}'
```

## Dashboard panel checklist (run on live site, anon key)

- [ ] KPI strip (v_kpi_by_date + mv_kpi_by_date)
- [ ] KPI sparkline (mv_sparkline_14d)
- [ ] Date picker populates (rpc_push_available_dates)
- [ ] Push status strip (rpc_push_status)
- [ ] Community Rhythm band (community_rhythm -- anon read policy kept, intentional)
- [ ] Sales by Dept / DeptTable (v_dept_by_date)
- [ ] Top 20 panel (v_top_products_by_date)
- [ ] Focus Area (rpc_focus_top5, rpc_focus_chart)
- [ ] Focus drilldown — supplier mode (rpc_eans_by_supplier + supplier_code column)
- [ ] Product search (rpc_product_search_index -- CRITICAL: confirm not blank)
- [ ] Product detail panel (rpc_product_detail, mv_rate_of_sale, rpc_supplier_by_ean)
- [ ] l2_kpi_daily KPI cards (matview, no RLS, direct read fine)
- [ ] Lost Sales panel (rpc_lost_sales_oos)
- [ ] Ghost Stock (rpc_ghost_stock_report)
- [ ] Stock Integrity (rpc_stock_integrity_report)
- [ ] pmini partner page (/pmini) — loads and shows data
- [ ] Capital Tied KPI (v_l2_capital_by_store)
- [ ] YOY graph (v_kpi_by_date)
- [ ] /api/dev-corner route (server-side, uses service key -- internal only, no anon exposure)

Any blank panel = direct table read still in the code. Do NOT run
stage2_drop_search_policy.sql until product search is confirmed working.
