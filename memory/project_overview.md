---
name: project-overview
description: SocialBrand dashboard — architecture, data model, Supabase views, key facts
metadata:
  type: project
---

## Stack
Next.js 14, React 18, Supabase (anon key only — no service role key in repo), xlsx, recharts.
Deployed to Vercel. Working dir: `C:\Users\User\Desktop\DIWAAIS\socialbrand-dashboard`.

## Stores
10116 SPAR Delareyville, 21355 TOPS Delareyville, 80175 SPAR Roosville, 80176 TOPS Roosville, 80579 TOPS Dice.

## Supabase views (pre-existing)
- `v_kpi_by_date`: store_code, store_name, snapshot_date, total_sales, total_cost, total_qty, neg_soh_count, slow_mover_count
- `v_dept_by_date`: store_code, snapshot_date, dept_name, dept_sales, dept_cost, dept_qty
- `v_top_products_by_date`: store_code, snapshot_date, ean, description, dept_name, today_sales, today_qty, rank_by_sales, rank_by_qty
- `v_focus_trend`: store_code, snapshot_date, ean, dept_name, sub_dept_name, description, sales, qty

## v_rate_of_sale (new — user must run sql/v_rate_of_sale.sql in Supabase SQL editor)
Columns: store_code, store_name, ean, description, dept_name, sub_dept_name, dept_code, sub_dept_code, soh, sell_price, unit_cost, status, internal_ref, daily_ros, days_cover
- daily_ros = sum(today_qty over last 91 days) / 91  [NOT period_qty — that's cumulative]
- days_cover = soh / daily_ros, NULL when ROS=0

## daily_snapshots columns (29 total)
id, store_code, store_name, file_date, snapshot_date, ean, description, size, unit, sell_price, vat_pct, today_qty, today_cost, today_sales, period_qty, period_cost, period_sales, soh, dept_code, dept_name, sub_dept_code, sub_dept_name, internal_ref, status, promo, last_sales_date_raw, last_sales_date_iso, unit_cost, is_placeholder

**Key**: `today_qty` = units sold that day. `period_qty` = cumulative period total (NOT daily). Always use `today_qty` for rate-of-sale.

## Suppliers table
supplier_code, supplier_name, created_at, updated_at. NO join key to daily_snapshots/products — cannot link supplier name to EAN.

## Fetch architecture (post-refactor)
- Store/date change → fetch v_kpi_by_date + v_dept_by_date + v_top_products_by_date (fast, ~small row counts)
- Dept filter selected → cheap distinct sub_dept_name query on daily_snapshots
- Report card click → full daily_snapshots fetch (lazy, user-initiated) + v_rate_of_sale for ROS enrichment
- Product row click → single-EAN daily_snapshots fetch + v_rate_of_sale for detail panel

## Dept filter
Now stored as dept_name STRING (not dept_code). Sub-dept filter = sub_dept_name STRING.
Both filters applied client-side on the already-fetched full-store reportRows.

## Sanity check confirmed
SPAR Delareyville (10116) on 2026-05-10: total_sales = 190,901.93 ✓ (matches from v_kpi_by_date)

**Why:** Architecture redesign to avoid fetching 17k+ raw rows on every filter change.
**How to apply:** Don't regress to eager-fetching daily_snapshots on filter changes. Views are the fast path for KPIs/charts; daily_snapshots only on explicit report load.
