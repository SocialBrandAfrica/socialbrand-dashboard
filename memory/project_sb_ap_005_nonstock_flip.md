---
name: project_sb_ap_005_nonstock_flip
description: SB-AP-005 -- flip production/non-stock lines to Record Stock Qty=No via Sigma Overview Maintenance
metadata:
  type: project
---

## SB-AP-005 -- Non-stock flip sprint (Sparrie + Mari Vorster)

**Status:** Carry-over (original due 31 May, now overdue -- reset date with Sparrie and Mari)
**Owners:** Sparrie (Roosville), Mari Vorster (Delareyville)
**Runs:** separate from dashboard Option C fix. Does NOT block it. Both run in parallel.

### The task

Flip the "Record Stock Qty" flag to No on the 1,581 Delareyville lines that the funnel
classified as PRODUCTION or NON_STOCK. This prevents Sigma from accumulating phantom SOH
on lines that will never be sold as retail units.

### Method

Sigma > Overview Maintenance > filter by sub-dept > uncheck "Record Stock Qty" > confirm.
This zeroes the SOH ledger for those lines on the server (the Sigma source of truth).
See SIGMA-SERVER-SCHEMA-MAP.md §9f for the mechanism note.

**Zero-first constraint:** Sigma requires SOH = 0 before the flag can be changed.
Split into two groups:
- 1,220 lines: already at SOH = 0 -- ready to flip immediately via Overview Maintenance
- 361 lines: have positive SOH -- must be cleared first, then flip
  - 70 lines: clearable via TLX (barcode-based stock adjustment). Use TLX_Converter.html.
  - 291 lines: no barcode (scale/packaging PLU items) -- manual stock adjustment in Sigma, then flip

### TLX tool pointer

**TLX_Converter.html** (in DIWAAIS) -- barcode-keyed stocktake import tool.
Key caveat confirmed 2026-06-02: Sigma's stocktake import matches on barcode/EAN, NOT
Product Code. No-barcode packaging and scale items CANNOT go through TLX. Use manual
stock adjustment for those 291 lines.
The tool's on-screen note, column label, and auto-detect all updated to reflect this.

### Planning sheet pointer

Planning sheet in DIWAAIS (linked from SB-AP-005 brief). Contains the 1,581-line split:
1,220 ready | 70 TLX | 291 manual.

### What this fixes

Once complete, those 1,581 lines will stop accumulating SOH on the server. The dashboard
Option C exclusion (classify_snapshot_item) handles the Capital Tied display in the
interim. SB-AP-005 fixes it at source in Sigma so the data is correct from the origin,
not just masked at the dashboard layer.

### What it does NOT do

Does not block or affect the dashboard. Option C (commit e8d6369) is live regardless.
Does not require any CC work until Sparrie/Mari report completion -- then CC can:
  a) re-run the funnel to confirm those lines no longer carry SOH
  b) verify Capital Tied on the live dashboard reflects the source fix
  c) close the remaining items in the Ghost Stock report

### Due date

Original: 31 May 2026 (carry-over, 2 days overdue). Reset date with Sparrie and Mari.
