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

## Dashboard panel checklist

Load dashboard.socialbrand.africa and verify each panel renders:

- [ ] KPI strip (v_kpi_by_date + mv_kpi_by_date)
- [ ] Date picker populates (rpc_push_available_dates)
- [ ] Push status strip (rpc_push_status)
- [ ] Sales by Dept / DeptTable (v_dept_by_date)
- [ ] Top 20 panel (v_top_products_by_date)
- [ ] Focus Area (rpc_focus_top5, rpc_focus_chart)
- [ ] Focus drilldown — supplier mode (rpc_eans_by_supplier)
- [ ] Product search (rpc_product_search_index)
- [ ] Product detail panel (rpc_product_detail, mv_rate_of_sale)
- [ ] Lost Sales panel (rpc_lost_sales_oos)
- [ ] Ghost Stock (rpc_ghost_stock_report)
- [ ] Stock Integrity (rpc_stock_integrity_report)
- [ ] pmini partner page (/pmini) — loads and shows data
- [ ] Capital Tied KPI (v_l2_capital_by_store)
- [ ] YOY graph (v_kpi_by_date)

Any blank panel = a read path not yet routed through an RPC. Do NOT lock Stage 2
until Stage 1 check passes clean.
