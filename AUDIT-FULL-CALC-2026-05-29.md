# SB-CC-AUDIT-001 v1.1 — Full Calculation Integrity Audit
**Ref:** SB-CC-AUDIT-001  
**Version:** 1.1  
**Date:** 2026-05-29  
**Scope:** All calculation logic in `src/app/page.jsx`, `src/components/FocusAreaPanel.jsx`, `src/components/ProductDetailPanel.jsx`, `src/components/SalesTrendPanel.jsx`, and all SQL files in `sql/`  
**Auditor:** Claude Code (read-only pass; no code changed)

---

## Shape 1 — Assumed Rate (Hardcoded VAT factor instead of per-row `vat_pct`)

### Finding 1-A
**Finding:** `buildDeptMarginReport` divides `total_sales` by the constant `1.15` to remove VAT when computing GP%.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/app/page.jsx` lines 569, 573  
**Current behaviour:** `const exVat = r.total_sales > 0 ? r.total_sales / 1.15 : 0` — a single fixed 15% divisor is applied to the aggregated department sales total.  
**Why it is wrong:** `total_sales` is the sum across all products in the department. Products with `vat_pct = 0` (zero-rated), `vat_pct = 9`, or any non-standard rate inflate the calculated ex-VAT figure. The correct approach requires splitting VAT per item before aggregating.  
**Severity:** MEDIUM (Dept Margin Trend report figure; not a headline KPI card)  
**Proposed correction:** `rpc_dept_summary` must return both `total_sales` (inc VAT) and `total_sales_ex_vat` (sum of `today_sales / (1 + vat_pct/100)` per row before summing). Frontend then uses the pre-split column.

---

### Finding 1-B
**Finding:** KPI GP% card divides `kpiSales` by `1.15` to compute ex-VAT sales.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/app/page.jsx` line 1871  
**Current behaviour:** `const kpiSalesExVat = kpiSales / 1.15` — a fixed 15% divisor applied to the aggregated total sales from `v_kpi_by_date` / `mv_kpi_by_date`.  
**Why it is wrong:** `total_sales` in these views is `SUM(today_sales)` across all products, which may include zero-rated items. The Rule Book warns of this: "current KPI card GP% uses VAT-inclusive sales vs VAT-exclusive cost — basis note is displayed." The note is displayed, but the figure is structurally imprecise for any mix containing non-15% lines.  
**Severity:** MEDIUM (headline figure, but Rule Book explicitly notes the limitation and requires a basis note — which is present)  
**Proposed correction:** `v_kpi_by_date` and `mv_kpi_by_date` must include `SUM(today_sales / (1 + vat_pct/100))` as `total_sales_ex_vat`. Frontend uses that column instead of dividing by 1.15.

---

### Finding 1-C
**Finding:** LY GP% card divides `lyKpiSales` by `1.15` using the same assumed rate.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/app/page.jsx` line 1971  
**Current behaviour:** `const lyKpiSalesExVat = lyKpiSales / 1.15`  
**Why it is wrong:** Same as Finding 1-B. LY comparison inherits the same structural imprecision. If the product mix changed (e.g. more zero-rated lines last year), the LY GP% will be distorted and the period-on-period pp delta will not be apples-to-apples.  
**Severity:** MEDIUM  
**Proposed correction:** Same as 1-B — add `total_sales_ex_vat` to both views; use it for LY too.

---

### Finding 1-D
**Finding:** Sparkline GP% array divides by `1.15` per date row.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/app/page.jsx` line 2023  
**Current behaviour:** `gpPct: sorted.map(([, v]) => v.sales > 0 ? gpPct(v.sales / 1.15, v.cost) : 0)` — sparkline GP% is computed from `mv_sparkline_14d.total_sales / 1.15`.  
**Why it is wrong:** `total_sales` in `mv_sparkline_14d` is `SUM(today_sales)` — same issue as 1-B.  
**Severity:** LOW (sparkline is visual trend; not a number users act on directly)  
**Proposed correction:** Add `total_sales_ex_vat` to `mv_sparkline_14d`; use it for the sparkline GP% array.

---

### Finding 1-E
**Finding:** `FocusAreaPanel` GP% divides `sell_price` by `1.15` (constant) instead of using `vat_pct` from the row.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/components/FocusAreaPanel.jsx` line 128  
**Current behaviour:** `const exVatSell = sellPrice != null && sellPrice > 0 ? sellPrice / 1.15 : null`  
**Why it is wrong:** `rpc_focus_chart` (as deployed by `fix_rpc_product_detail_pricing.sql`) returns `sell_price` and `unit_cost` but does NOT return `vat_pct`. The DB-SCHEMA note confirms: "Does NOT return vat_pct — FocusAreaPanel uses hardcoded /1.15 divisor." For zero-rated products the divisor should be `/1.0`; for non-standard rates it should differ.  
**Severity:** MEDIUM (Focus Area GP% cell shown per product in the basket)  
**Proposed correction:** Add `vat_pct` to `rpc_focus_chart` return columns. Frontend: `const exVatSell = sellPrice / (1 + (vat_pct ?? 15) / 100)`.

---

### Finding 1-F
**Finding:** `deptsummary` report function (in-page, not DB) divides `d.sales / 1.15` for per-department GP%.  
**Shape:** 1 — Assumed rate  
**File and line:** `src/app/page.jsx` line 418 and line 433  
**Current behaviour:** `const exVatSales = d.sales / 1.15` — `d.sales` is the sum of `period_sales` across all rows in the department.  
**Why it is wrong:** `d.sales` is the sum of `period_sales` across multiple products with potentially varying VAT rates. The division by 1.15 produces incorrect ex-VAT sales for departments containing zero-rated items.  
**Severity:** MEDIUM (Dept Summary download report GP% column)  
**Proposed correction:** Accumulate `period_sales / (1 + vat_pct/100)` per row into `d.salesExVat` before summing, then use `d.salesExVat` directly.

---

## Shape 2 — Aggregate of an Aggregate (Summing cumulative MTD fields across dates)

### Finding 2-A
**Finding:** `mergeByEan` (single-store merge) sums `period_qty`, `period_cost`, and `period_sales` across rows from different snapshot dates for the same EAN.  
**Shape:** 2 — Aggregate of an aggregate  
**File and line:** `src/app/page.jsx` lines 176–178  
**Current behaviour:** When multiple dates are selected and `fetchAllRows` returns rows for the same EAN on multiple snapshot dates, `mergeByEan` adds them: `m.period_sales = (m.period_sales ?? 0) + (r.period_sales ?? 0)`.  
**Why it is wrong:** `period_sales` is a Sigma cumulative MTD counter. If the selected dates span 01-May through 10-May, each daily row already contains the running total for the period. Summing 10 rows produces a figure 10x the actual MTD turnover. The correct value is the single latest row's `period_sales` for that EAN.  
**Severity:** HIGH (Period Sales report, Dept Summary report, DIWAAIS report — all downstream consumers of `period_*` fields)  
**Proposed correction:** In `mergeByEan` and `mergeGroupRows`, `period_*` fields must NOT be summed across dates. Take the value from the latest snapshot date row only (the row that wins `m.snapshot_date` comparison). Only `today_*` fields are legitimately additive across dates.

---

### Finding 2-B
**Finding:** `mergeGroupRows` (multi-store merge) applies the same summing of `period_qty`, `period_cost`, `period_sales` across dates.  
**Shape:** 2 — Aggregate of an aggregate  
**File and line:** `src/app/page.jsx` lines 202–204  
**Current behaviour:** Identical to 2-A but applied when `storeCodes.length > 1`.  
**Why it is wrong:** Same reasoning as 2-A. The MTD cumulative is double-counted for every additional date included in the selection. The multi-store path is used for the majority of live dashboard use (all 5 stores default selected).  
**Severity:** HIGH  
**Proposed correction:** Same as 2-A.

---

### Finding 2-C
**Finding:** `deptsummary` report aggregates `period_qty`, `period_cost`, `period_sales` from `filteredReportRows` which has already been processed by `mergeByEan`/`mergeGroupRows`.  
**Shape:** 2 — Aggregate of an aggregate  
**File and line:** `src/app/page.jsx` lines 410–413  
**Current behaviour:** The `deptsummary` case iterates `rows` (which is `filteredReportRows` — already merged) and sums `r.period_qty`, `r.period_cost`, `r.period_sales` per department.  
**Why it is wrong:** If the merged rows already contain inflated `period_*` values (from Finding 2-A/B), the department totals are doubly wrong. Additionally, even if the merge is fixed, this path uses `period_*` where only `today_*` would be safe for multi-date selections.  
**Severity:** HIGH  
**Proposed correction:** Fix 2-A/B first. Then ensure the `deptsummary` report case always uses `today_*` fields (which are correctly additive) rather than `period_*`.

---

## Shape 3 — Proxy Variable (Stand-in value where a real measured fact is needed)

### Finding 3-A
**Finding:** `lostSalesValue` KPI uses `selectedDates.length` as the number of days a product has been out of stock.  
**Shape:** 3 — Proxy variable  
**File and line:** `src/app/page.jsx` line 1904  
**Current behaviour:** `return sum + (selectedDates.length * dailyRos * price)` — the number of calendar dates selected in the UI picker substitutes for OOS days.  
**Why it is wrong:** `selectedDates.length` is the count of dates the user has clicked in the date picker. If the user selects 3 dates in May but the product has been OOS since March, the estimated lost value is dramatically understated. Conversely, selecting many dates for a product that only became OOS on the last date overstates it. The real measurement is days since `last_sales_date_iso` (or the first date on which `soh <= 0` was first confirmed), both of which are available in `lostSalesItems`.  
**Severity:** HIGH (the "Lost Sales Value" KPI card is a headline number that management acts on)  
**Proposed correction:** Compute `daysSince` from `last_sales_date_iso` to `availableDates[0]` for each item in `lostSalesItems` (same as the download report does at line 349). Use `Math.max(1, daysSince)` as the OOS days multiplier.

---

### Finding 3-B
**Finding:** The Velocity report's "Stock Turn" column uses `365 / n` as an annualisation factor where `n = selectedDates.length`.  
**Shape:** 3 — Proxy variable  
**File and line:** `src/app/page.jsx` line 321  
**Current behaviour:** `((r.period_qty ?? 0) / (r.soh ?? 0) * (365 / n)).toFixed(1)` — stock turn is `(period_qty / SOH) * (365 / n_dates_selected)`.  
**Why it is wrong:** `selectedDates.length` is the count of date-picker clicks, not the number of trading days in the business period. If the user selects 3 non-consecutive snapshot dates (e.g. the 1st, 15th, and 28th of a month), the formula treats it as 3 trading days, producing a 121.7x annualisation factor. The correct denominator is the elapsed calendar days between the earliest and latest selected date.  
**Severity:** MEDIUM (Velocity report download; not a headline KPI)  
**Proposed correction:** Compute `n` as the number of calendar days between `min(selectedDates)` and `max(selectedDates)`, plus 1. Use that as the denominator.

---

## Shape 4 — Math in the Wrong Layer (Derived figures computed in JS that DB cannot trace)

### Finding 4-A
**Finding:** KPI GP% (headline card) is computed entirely in JS from aggregated `total_sales` and `total_cost`.  
**Shape:** 4 — Math in the wrong layer  
**File and line:** `src/app/page.jsx` lines 1871–1873  
**Current behaviour:** `kpiSalesExVat = kpiSales / 1.15; kpiGPRand = kpiSalesExVat - kpiCost; kpiGP = (kpiGPRand / kpiSalesExVat) * 100`  
**Why it is wrong:** The DB has no record of what ex-VAT GP% was reported. If the query returns partial data (a store missing), the JS silently computes a wrong figure with no error. The correct approach is for the DB view to expose `total_sales_ex_vat` so the JS only divides pre-computed columns.  
**Severity:** MEDIUM (structural traceability issue; actual error depends on VAT mix — see also 1-B)  
**Proposed correction:** Add `SUM(today_sales / (1 + vat_pct / 100.0))` as `total_sales_ex_vat` to `v_kpi_by_date` and `mv_kpi_by_date`. JS then computes `kpiGP = (kpiSalesExVat - kpiCost) / kpiSalesExVat * 100` using the pre-split DB column.

---

### Finding 4-B
**Finding:** KPI Stock Turn is computed in JS using `kpiCost / selectedDates.length * 365` as annualised COGS.  
**Shape:** 4 — Math in the wrong layer  
**File and line:** `src/app/page.jsx` lines 1986–1987  
**Current behaviour:** `kpiStockTurn = (kpiCost / selectedDates.length * 365) / kpiCapTied`  
**Why it is wrong:** `selectedDates.length` is a proxy for period days (see Shape 3). This compounds the error: the JS annualises COGS using the date-count rather than the actual trading period length.  
**Severity:** HIGH (Stock Turn KPI card is a headline metric)  
**Proposed correction:** Replace `selectedDates.length` with the elapsed calendar days between earliest and latest selected date (`daysInPeriod`). Formula: `(kpiCost / daysInPeriod * 365) / kpiCapTied`.

---

### Finding 4-C
**Finding:** Lost Sales download report (Signal A) computes `estLostValue` in JS using `daysSince * dailyRos * sell_price` at VAT-inclusive sell price.  
**Shape:** 4 — Math in the wrong layer  
**File and line:** `src/app/page.jsx` line 357  
**Current behaviour:** `estLostValue = Math.round(dailyRos * (r.sell_price ?? 0) * Math.max(1, daysSince) * 100) / 100`  
**Why it is wrong:** `sell_price` is the shelf price including VAT. Lost Sales Value is a revenue-loss estimate. It should be on a consistent basis — either ex-VAT throughout or VAT-inc throughout and labelled accordingly. The KPI card tooltip says "Rand value of sales lost" without clarifying VAT treatment. The Rule Book (Section 6) says: `lost value per day = daily_ros × sell_price` — it does not specify ex-VAT, so VAT-inclusive is technically consistent with the Rule Book, but the basis should be stated.  
**Severity:** LOW (consistent with Rule Book definition; presentation issue only — basis note should be added)  
**Proposed correction:** Add a basis note "incl. VAT" to the Lost Sales tooltip and download column header, consistent with Rule Book Section 6.

---

## Shape 5 — Unguarded Division

### Finding 5-A
**Finding:** `unitCost` helper falls through to `sell_price * 0.8` with no guard when `sell_price = 0`.  
**Shape:** 5 — Unguarded division  
**File and line:** `src/app/page.jsx` lines 83–86  
**Current behaviour:** When `unit_cost` is null and `period_qty = 0`, the function computes `(row.sell_price / (1 + vat)) * 0.8`. If `sell_price = 0` this returns `0` — not a division by zero, but it implies 80% margin assumption on a zero-price item, producing `capitalTied = 0` for items where cost is unknown.  
**Why it is wrong:** The proxy cost of `sell_price * 0.8 / (1+vat)` is an assumption (20% GP), not a measured fact. It is used in the `slowmovers` report Capital Tied column and in `capTiedByDept` drill-down. The assumption is undocumented in the UI.  
**Severity:** MEDIUM (Capital Tied in slow movers report and drill-down may silently understate for items with missing `unit_cost`)  
**Proposed correction:** When `unit_cost` is null and `period_qty = 0`, return `null` rather than a proxy value. Flag the column as `—` and note "unit cost unknown" in the report.

---

### Finding 5-B
**Finding:** `gpPct` helper divides `(sales - cost) / sales` with no null/zero guard beyond `!sales || sales === 0`.  
**Shape:** 5 — Unguarded division  
**File and line:** `src/app/page.jsx` lines 93–96  
**Current behaviour:** `function gpPct(sales, cost) { if (!sales || sales === 0) return 0; return ((sales - cost) / sales) * 100 }` — returns `0` when sales is falsy, but does not guard against negative `sales`.  
**Why it is wrong:** If `sales` is negative (e.g. a credit return producing negative `today_sales`), the function returns a positive GP% on a negative base. The correct return for negative sales is `null` or `—` since GP% is undefined on returns.  
**Severity:** LOW (edge case for credit returns; rare in practice)  
**Proposed correction:** Add `if (sales < 0) return null` guard before the division.

---

### Finding 5-C
**Finding:** `kpiDaysCover` divides `365 / kpiStockTurn` with no guard if `kpiStockTurn = 0`.  
**Shape:** 5 — Unguarded division  
**File and line:** `src/app/page.jsx` line 1989  
**Current behaviour:** `const kpiDaysCover = kpiStockTurn > 0 ? Math.round(365 / kpiStockTurn) : null` — the guard `> 0` prevents division by zero. Correct.  
**Why it is wrong:** N/A — this division is guarded. Documented here for completeness.  
**Severity:** N/A — no finding; guard is present.

---

### Finding 5-D
**Finding:** `mv_rate_of_sale` SQL divides `soh / (total_qty_91d / 91.0)` for days_cover with a guard only on `total_qty_91d = 0`.  
**Shape:** 5 — Unguarded division  
**File and line:** `sql/mv_rate_of_sale.sql` line 79  
**Current behaviour:** `CASE WHEN COALESCE(r.total_qty_91d, 0) = 0 THEN NULL ELSE ROUND((l.soh / (r.total_qty_91d / 91.0))::NUMERIC, 1) END AS days_cover`  
**Why it is wrong:** Guard is present and correct — `NULL` is returned when `daily_ros = 0`, consistent with Rule Book "Days cover is undefined when daily_ros = 0." No error.  
**Severity:** N/A — no finding; guard is present.

---

### Finding 5-E
**Finding:** Velocity report divides `currentRos / baselineRos` with a guard only when `baselineRos > 0`.  
**Shape:** 5 — Unguarded division  
**File and line:** `src/app/page.jsx` line 303  
**Current behaviour:** `const rosVsBase = baselineRos > 0 ? currentRos / baselineRos : null` — guarded correctly.  
**Severity:** N/A — no finding.

---

## Shape 6 — Silent Default Substituted for Missing Data

### Finding 6-A
**Finding:** `vat_pct ?? 15` fallback in `unitCost`, `period_sales`, and `velocity` report substitutes 15% for any row where `vat_pct` is null.  
**Shape:** 6 — Silent default  
**File and line:** `src/app/page.jsx` lines 84, 260, 304  
**Current behaviour:** `const vat = (r.vat_pct ?? 15) / 100` — when `vat_pct` is null in the snapshot row, 15% is assumed.  
**Why it is wrong:** The `??` fallback is silent: the dashboard will show GP% for zero-rated products (fruit, vegetables, some infant products) as if they are standard-rated, overstating ex-VAT sales and therefore understating GP%. There is no flag or warning that the fallback was applied.  
**Severity:** MEDIUM (affects GP% accuracy for zero-rated product lines in period_sales, velocity, and focus area reports)  
**Proposed correction:** Log or flag rows where `vat_pct IS NULL` in the data quality view. For GP% computation, treat null `vat_pct` rows with a null GP% (show `—`) rather than substituting 15%.

---

### Finding 6-B
**Finding:** `ProductDetailPanel` uses `vatPct = latestDetail?.vat_pct ?? 15` for GP% calculation.  
**Shape:** 6 — Silent default  
**File and line:** `src/components/ProductDetailPanel.jsx` line 101  
**Current behaviour:** `const vatPct = latestDetail?.vat_pct ?? 15` — falls back to 15% if `vat_pct` is null in the detail row.  
**Why it is wrong:** Same as 6-A. Zero-rated product detail panels will show inflated GP%.  
**Severity:** MEDIUM  
**Proposed correction:** Show GP% as `—` when `vat_pct` is null.

---

## Shape 7 — Same Metric, More Than One Definition

### Finding 7-A: GP%
**Definition instances found:**

| Location | Formula | VAT handling |
|---|---|---|
| `page.jsx` line 1871 — KPI card | `(kpiSales/1.15 - kpiCost) / (kpiSales/1.15) * 100` | Fixed 1.15 on aggregate |
| `page.jsx` line 261 — period_sales report | `(period_sales/(1+vat_pct/100) - period_cost) / ex_vat * 100` | Per-row `vat_pct ?? 15` |
| `page.jsx` line 305 — velocity report | `(period_sales/(1+vat_pct/100) - period_cost) / ex_vat * 100` | Per-row `vat_pct ?? 15` |
| `page.jsx` line 418 — deptsummary report | `(d.sales/1.15 - d.cost) / (d.sales/1.15) * 100` | Fixed 1.15 on aggregate |
| `page.jsx` line 569 — dept margin trend | `(r.total_sales/1.15 - r.total_cost) / (r.total_sales/1.15) * 100` | Fixed 1.15 on aggregate |
| `FocusAreaPanel.jsx` line 128 | `(sell_price/1.15 - unit_cost) / (sell_price/1.15) * 100` | Fixed 1.15 on single price |
| `ProductDetailPanel.jsx` line 103 | `(sell_price/(1+vat_pct/100) - unit_cost) / ex_vat * 100` | Per-row `vat_pct ?? 15` |

**Finding:** GP% has two distinct implementations: per-row `vat_pct` (correct pattern) in the period_sales, velocity, and ProductDetailPanel; and a fixed `/1.15` divisor on aggregate totals in the KPI card, deptsummary report, dept margin trend, and FocusAreaPanel. This means the KPI card GP% and the line-item report GP% can disagree for any store mix containing zero-rated or non-standard lines.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** HIGH  
**Proposed correction:** Unify all GP% paths to use per-item ex-VAT split before aggregation. All aggregating views must expose `total_sales_ex_vat`.

---

### Finding 7-B: Stock Turn
**Definition instances found:**

| Location | Formula | Period days source |
|---|---|---|
| `page.jsx` line 1987 — KPI card | `(kpiCost / selectedDates.length * 365) / kpiCapTied` | `selectedDates.length` (date picker count) |
| `page.jsx` line 321 — velocity report | `(period_qty / soh) * (365 / selectedDates.length)` | `selectedDates.length` (date picker count) |
| Rule Book Section 3 | `annual_sales_cost / average_capital_tied` | 365-day annualisation |

**Finding:** Both in-code implementations use `selectedDates.length` as the period denominator. The Rule Book formula requires actual calendar days in the period. The two JS implementations are internally consistent with each other but both diverge from the Rule Book definition for any non-contiguous date selection.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** HIGH  
**Proposed correction:** Compute `daysInPeriod = (new Date(max(selectedDates)) - new Date(min(selectedDates))) / 86400000 + 1` and use it in both locations.

---

### Finding 7-C: Capital Tied
**Definition instances found:**

| Location | Formula | Population |
|---|---|---|
| `v_kpi_by_date` / `mv_kpi_by_date` SQL (KPI card source) | `SUM(soh * unit_cost) WHERE period_qty = 0 AND soh > 0` | Only slow-mover lines |
| `page.jsx` line 1818 — `capTiedByDept` (drill-down) | `SUM(soh * unitCost(r)) WHERE soh > 0` | All in-stock lines |
| Rule Book Section 3 | `sum(soh × unit_cost)` across all **active** lines | All active lines |
| `page.jsx` line 1807 — stalledLines | `(r.soh ?? 0) * cost` per stalled line | Only stalled lines |

**Finding:** Capital Tied has three materially different populations:
1. The KPI card (`v_kpi_by_date`) counts only `period_qty = 0 AND soh > 0` — slow movers only. The comment in the SQL says "capital tied = ZAR value of stock tied up in slow movers." This is **not** the Rule Book definition.
2. The drill-down modal (`capTiedByDept`) counts all `soh > 0` lines — all stock, not just slow movers. This matches the Rule Book.
3. The Rule Book says "all active lines" which includes active fast-movers.

The KPI card value is labelled "Capital Tied" but actually represents Capital Tied in Slow Movers only. The drill-down shows a different (higher) number. The two numbers will not reconcile.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** HIGH (headline KPI card is mislabelled — it shows a subset of capital tied)  
**Proposed correction:** Rename the SQL view column to `capital_tied_slow_movers` or compute full capital tied as `SUM(soh * COALESCE(unit_cost, 0)) WHERE soh > 0 AND is_placeholder = FALSE`. Update both views and the KPI card tooltip to clarify that the current figure is "Capital in Slow Movers."

---

### Finding 7-D: Slow Mover count
**Definition instances found:**

| Location | Condition |
|---|---|
| `v_kpi_by_date` / `mv_kpi_by_date` SQL | `period_qty = 0 AND soh > 0 AND is_placeholder = FALSE` |
| `mv_sparkline_14d` SQL | `period_qty = 0 AND soh > 0 AND is_placeholder = FALSE` |
| `rpc_kpi_dept_counts.sql` (latest: `fix_index_rule_dept_rpcs.sql`) | `soh > 0 AND period_qty = 0 AND NOT is_placeholder` |
| `buildReport` slow movers case (line 439–446) | `soh > 0 AND last_sales_date_iso < slowCutoff (refDate - 14 days) AND isActiveLine` |
| Rule Book Section 5 KPI 4 | `soh > 0, no sale in last 14 FIXED days, active line (sold in 364 days)` |

**Finding:** The KPI card slow mover count (from `v_kpi_by_date`) uses `period_qty = 0` as the "no sale" proxy — this is the Sigma MTD counter, not a 14-day window. A product that sold on 1 May but not since 2 May would show `period_qty > 0` and be excluded from the count even though it hasn't moved in 3+ weeks. The download report (lines 439–446) correctly uses `last_sales_date_iso < refDate - 14 days`. These two definitions produce different counts. The Rule Book requires the 14-day window.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** HIGH (KPI 4 Slow Movers card shows a different number than the download report)  
**Proposed correction:** Update `v_kpi_by_date`, `mv_kpi_by_date`, `mv_sparkline_14d`, and `rpc_kpi_dept_counts` to use `last_sales_date_iso < snapshot_date - INTERVAL '14 days'` as the slow-mover filter, consistent with Rule Book KPI 4.

---

### Finding 7-E: Lost Sales Value (KPI card vs download report)
**Definition instances found:**

| Location | Formula |
|---|---|
| `page.jsx` line 1904 — KPI card | `selectedDates.length * dailyRos * sell_price` |
| `page.jsx` line 357 — download report Signal A | `Math.max(1, daysSince) * dailyRos * sell_price` where `daysSince` = days since last sale |

**Finding:** The KPI card uses `selectedDates.length` (date picker count) as OOS days. The download report uses `daysSince` (actual elapsed days since last sale). For a 10-date selection on a product OOS for 45 days, the KPI card shows 10x × ROS × price; the download shows 45x × ROS × price. These are materially different figures for the same product.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** HIGH  
**Proposed correction:** See Finding 3-A. Use `daysSince` from `last_sales_date_iso` in the KPI card, matching the download report formula.

---

### Finding 7-F: Reorder Items count
**Definition instances found:**

| Location | Condition |
|---|---|
| Rule Book Section 5 KPI 3 | `soh <= 0 AND period_qty > 0` |
| `page.jsx` lostSalesItems query (line 1303–1304) | `soh <= 0 AND (period_qty IS NULL OR period_qty = 0)` |

**Finding:** The Reorder Items KPI 3 is not directly rendered from a dedicated KPI field — it appears to be derived from the `lostSalesItems` count. `lostSalesItems` uses `period_qty = 0` as a filter, which is the opposite of the Rule Book KPI 3 definition (`period_qty > 0`). `lostSalesItems` is the True OOS (Signal A) panel, not KPI 3 Reorder Items. These are different metrics. Confirm whether a Reorder Items KPI card exists and what its source is. If the displayed "Lost Sales" item count is being used as a proxy for Reorder Items, the definition is wrong.  
**Shape:** 7 — Same metric, more than one definition  
**Severity:** MEDIUM (requires live DB confirmation — see note below)  
**Note:** A live DB query is needed to confirm whether a separate Reorder Items KPI card exists and what its source query is. The audit cannot fully resolve this from static files alone.  
**Proposed correction:** Ensure Reorder Items KPI reads `soh <= 0 AND period_qty > 0` per Rule Book KPI 3. Ensure Lost Sales panel reads `soh <= 0 AND period_qty = 0` per Signal A definition.

---

## SQL Version Audit

### rpc_top20
**Versions in repo (by file, in apparent deployment order):**

| File | Signature | Key change |
|---|---|---|
| `fix_aggregation_rpcs.sql` | `(p_store_codes, p_dates, p_dept, p_subdept)` — 4 params | Original, no EAN filter |
| `add_ean_filter.sql` | `(p_store_codes, p_dates, p_dept, p_subdept, p_eans)` — 5 params | Added `p_eans` |
| `fix_top20_overload.sql` | Multiple, resolving overloads | Overload cleanup |
| `restore_top20_params.sql` | `(p_store_codes, p_dates, p_dept, p_subdept, p_eans, p_activity, p_parents)` — 7 params | non_movers branch added |
| `fix_non_movers_definition.sql` | 7 params | Corrected non_movers logic (v1) |
| `fix_non_movers_v2.sql` | 7 params | Corrected non_movers logic (v2 — DATE column fix) |
| `fix_rpc_top20_cte.sql` | 7 params (same) | CTE refactor |

**Flag:** The live DB may have any one of these versions deployed. The version history is not self-documenting in the DB. Confirm with: `SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname = 'rpc_top20'`. Exactly 1 row with 7 parameters should exist. Any other result indicates an overload or wrong version.

**Additional flag in `fix_non_movers_v2.sql` line 99:** Non-movers active line filter uses `INTERVAL '365 days'`, not `364 days`. This violates the Rule Book LY shift rule. See Rule Book Cross-Check section below.

---

### rpc_dept_summary
**Versions in repo:**

| File | Signature |
|---|---|
| `fix_aggregation_rpcs.sql` | `(p_store_codes, p_dates)` — 2 params |
| `add_ean_filter.sql` | `(p_store_codes, p_dates, p_eans)` — 3 params |
| `add_subdept_filter_to_kpi_rpcs.sql` | `(p_store_codes, p_dates, p_eans, p_subdept)` — 4 params |
| `fix_index_rule_dept_rpcs.sql` | `(p_store_codes, p_dates, p_eans, p_subdept)` — 4 params (index fix) |

**Flag:** The 2-param and 3-param versions are superseded. Confirm exactly 1 overload with 4 params in the live DB.

---

### rpc_kpi_dept_counts
**Versions in repo:**

| File | Signature | `p_eans` param | slow_mover definition |
|---|---|---|---|
| `add_dept_soh_counts.sql` | `(p_store_codes, p_dates)` | No | `soh > 0 AND period_qty = 0` |
| `add_subdept_filter_to_kpi_rpcs.sql` | `(p_store_codes, p_dates, p_subdept)` | No | `soh > 0 AND period_qty = 0` |
| `fix_index_rule_dept_rpcs.sql` | `(p_store_codes, p_dates, p_subdept)` | No | `soh > 0 AND period_qty = 0` |
| `rpc_kpi_dept_counts.sql` | `(p_store_codes, p_dates, p_subdept, p_eans)` | Yes | `period_qty = 0 AND soh > 0 AND is_placeholder = FALSE` |

**Flag — signature drift:** The latest file `rpc_kpi_dept_counts.sql` adds `p_eans` as a 4th parameter. The file `fix_index_rule_dept_rpcs.sql` (which was the index-fix deployment) defines only 3 parameters. The frontend at `page.jsx` line 1528 calls `rpc_kpi_dept_counts` with `p_eans: focusEans` — this will fail with a 500 error if the 3-param version from `fix_index_rule_dept_rpcs.sql` is the live version. Confirm: `SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname = 'rpc_kpi_dept_counts'`. Must show 4 params including `p_eans`.

---

### rpc_product_detail
**Versions in repo:**

| File | Returns `vat_pct`? | Returns `unit_cost`? |
|---|---|---|
| `phase2c_migrate_pulse.sql` | No | No |
| `fix_rpc_product_detail_pricing.sql` | Yes | Yes |

**Flag:** Only the latest version is correct. Confirm the live version returns all 10 columns including `unit_cost` and `vat_pct`.

---

### rpc_focus_chart
**Versions in repo:**

| File | Returns `sell_price`? | Returns `unit_cost`? | Returns `vat_pct`? |
|---|---|---|---|
| `rpc_focus_area.sql` | No | No | No |
| `fix_rpc_product_detail_pricing.sql` | Yes | Yes | **No** |

**Flag:** The current live version (from `fix_rpc_product_detail_pricing.sql`) returns `sell_price` and `unit_cost` but NOT `vat_pct`. This forces `FocusAreaPanel` to use the hardcoded `/1.15` divisor (Finding 1-E). Requires a further SQL update to add `vat_pct` to the return type.

---

### rpc_focus_top5 and rpc_dept_summary
**`rpc_focus_top5` (in `rpc_focus_area.sql`):** Uses `snapshot_date::text = ANY(p_dates)` — violates the index rule. This is the column-cast pattern. Confirm whether this function is still called (DB-SCHEMA does not list it as dropped). If active, this will cause full 18M-row scans.

---

## Rule Book Cross-Check

### LY Offset — Must be 364 days, never 365

**`sql/fix_non_movers_v2.sql` line 99:**  
`last_sales_date_iso BETWEEN (CURRENT_DATE - INTERVAL '365 days') AND (CURRENT_DATE - INTERVAL '28 days')`  
This uses `365` days for the active-line lookback in the non-movers branch of `rpc_top20`. This violates the Rule Book LY_SHIFT = 364 and ACTIVE_LINE_LOOKBACK = 364. The intent is "sold at least once in the last year" — the window must be `INTERVAL '364 days'`.  
**Severity:** MEDIUM

**`sql/fix_non_movers_definition.sql` line 95:** Same `INTERVAL '365 days'` — superseded file, but shows the pattern exists.  
**`sql/v_deleted_lines_audit.sql` lines 77, 90:** `INTERVAL '365 days'` — secondary audit view, LOW severity.

**`page.jsx` lines 1986–1987, 1989:** Uses `365` in annualisation factors for Stock Turn and Days Cover. These are annualisation constants (converting daily COGS to annual), not LY date offsets — `365` is correct here. Not a Rule Book violation.

---

### OOS Threshold — Must be `soh <= 0` (except KPI 5)

All primary OOS signal paths use `soh <= 0` correctly:
- `rpc_lost_sales_timeline` line 51: `soh <= 0` ✓
- `page.jsx` line 354: `soh <= 0` ✓
- `page.jsx` line 1303: `.lte('soh', 0)` ✓

KPI 5 Negative SOH uses `soh < 0` by design in all views ✓

---

### Slow Mover Window — Must be fixed 14 days, not date picker

The download report (`buildReport` slowmovers case, line 439) uses `shiftDate(refDate, -SLOW_MOVER_DAYS)` where `SLOW_MOVER_DAYS = 14`. The refDate is the latest selected date, not today's date. For a multi-date selection with the latest date being historical, this window shifts into the past — the slow mover cutoff becomes historical too.  
**Finding:** For multi-date selections with a historical max date, the slow mover 14-day window is anchored to `max(selectedDates)` rather than today. This is an inconsistency with the Rule Book which says "no sale in the last 14 days" — the 14-day window should be fixed relative to today (or the most recent push date), not the selected date range.  
**Severity:** MEDIUM

---

### SOH Source — Must be `dewas_PLU_s` based, never `PLU_s`

All SQL reads from `daily_snapshots.soh`, which is populated from `dewas_PLU_s` by the push script. No direct reads from `PLU_s` or `DBAUms` found in any active SQL file. ✓

---

### DBAUms as a sales/SOH source

No active SQL file uses DBAUms as a sales or SOH source. ✓

---

## Summary Table (HIGH → MEDIUM → LOW)

| # | Finding | Shape | Severity | File | Line(s) |
|---|---|---|---|---|---|
| 7-A | GP%: two definitions — per-row vat_pct vs aggregate /1.15 | 7 | HIGH | page.jsx, FocusAreaPanel.jsx | 1871, 261, 305, 418, 569, 128 |
| 7-C | Capital Tied: KPI card = slow movers only; drill-down = all stock | 7 | HIGH | page.jsx + p3_2_v_kpi_by_date.sql | 1818, view line 26–30 |
| 7-D | Slow Mover count: KPI card uses period_qty=0; report uses 14-day window | 7 | HIGH | page.jsx + p3_2_v_kpi_by_date.sql | 439–446, view line 24 |
| 7-E | Lost Sales Value: KPI card uses selectedDates.length; report uses daysSince | 7 | HIGH | page.jsx | 1904, 357 |
| 7-B | Stock Turn: both paths use selectedDates.length instead of calendar days | 7 | HIGH | page.jsx | 1987, 321 |
| 2-A | mergeByEan sums period_* (cumulative MTD) across multiple dates | 2 | HIGH | page.jsx | 176–178 |
| 2-B | mergeGroupRows sums period_* (cumulative MTD) across multiple dates | 2 | HIGH | page.jsx | 202–204 |
| 2-C | deptsummary report sums period_* from already-merged rows | 2 | HIGH | page.jsx | 410–413 |
| 3-A | lostSalesValue uses selectedDates.length as OOS days proxy | 3 | HIGH | page.jsx | 1904 |
| 4-B | kpiStockTurn annualises COGS using selectedDates.length | 4 | HIGH | page.jsx | 1987 |
| 1-A | buildDeptMarginReport divides aggregate total_sales by /1.15 | 1 | MEDIUM | page.jsx | 569, 573 |
| 1-B | KPI GP% divides kpiSales by /1.15 (assumed rate on aggregate) | 1 | MEDIUM | page.jsx | 1871 |
| 1-C | LY KPI GP% divides lyKpiSales by /1.15 | 1 | MEDIUM | page.jsx | 1971 |
| 1-E | FocusAreaPanel GP% divides sell_price by /1.15 (no vat_pct from RPC) | 1 | MEDIUM | FocusAreaPanel.jsx | 128 |
| 1-F | deptsummary report divides d.sales / 1.15 for aggregate GP% | 1 | MEDIUM | page.jsx | 418, 433 |
| 4-A | KPI GP% computed in JS from aggregated totals (no DB traceability) | 4 | MEDIUM | page.jsx | 1871–1873 |
| 5-A | unitCost proxy (sell_price × 0.8) substituted when unit_cost null | 5 | MEDIUM | page.jsx | 83–86 |
| 6-A | vat_pct ?? 15 silently defaults 0-rated products to 15% | 6 | MEDIUM | page.jsx | 84, 260, 304 |
| 6-B | ProductDetailPanel vatPct ?? 15 for GP% | 6 | MEDIUM | ProductDetailPanel.jsx | 101 |
| 7-F | Reorder Items: definition conflict between KPI and query | 7 | MEDIUM | page.jsx | 1303–1304 |
| 3-B | Velocity Stock Turn column uses selectedDates.length as period days | 3 | MEDIUM | page.jsx | 321 |
| SQL Rule Book | fix_non_movers_v2.sql uses 365 days instead of 364 | Rule Book | MEDIUM | fix_non_movers_v2.sql | 99 |
| SQL Rule Book | Slow mover refDate anchored to max(selectedDates), not today | Rule Book | MEDIUM | page.jsx | 439 |
| SQL Version | rpc_kpi_dept_counts signature drift (3-param vs 4-param) | Version | MEDIUM | rpc_kpi_dept_counts.sql vs fix_index_rule_dept_rpcs.sql | — |
| SQL Version | rpc_focus_chart missing vat_pct (confirmed from DB-SCHEMA) | Version | MEDIUM | fix_rpc_product_detail_pricing.sql | 74–111 |
| SQL Index | rpc_focus_top5 uses snapshot_date::text = ANY(p_dates) — full scan | Index rule | MEDIUM | rpc_focus_area.sql | 41 |
| 1-D | Sparkline GP% divides mv_sparkline_14d aggregate by /1.15 | 1 | LOW | page.jsx | 2023 |
| 4-C | Lost Sales Value uses VAT-inclusive sell_price (basis undocumented) | 4 | LOW | page.jsx | 357 |
| 5-B | gpPct helper returns 0 for negative sales instead of null | 5 | LOW | page.jsx | 93–96 |
| SQL Rule Book | v_deleted_lines_audit.sql uses 365-day window | Rule Book | LOW | v_deleted_lines_audit.sql | 77, 90 |

---

## Finding Counts

| Severity | Count |
|---|---|
| HIGH | 10 |
| MEDIUM | 17 |
| LOW | 4 |
| **Total** | **31** |

---

*Report written by: Claude Code (read-only audit, no code changed)*  
*Report file: `C:\Users\User\Desktop\DIWAAIS\socialbrand-dashboard\AUDIT-FULL-CALC-2026-05-29.md`*
