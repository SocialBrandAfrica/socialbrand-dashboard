---
name: feedback-capital-tied-sanity
description: Domain rules for validating capital tied figures — pack size correction, stock/turnover ratio bounds
metadata:
  type: feedback
---

Pack sizes are used everywhere in ordering — the pack_size / list_cost distinction is not a niche edge case. dEKL in sigma_supplier_link is always cost per order pack (case); always divide by pack_size to get unit cost.

Capital tied sanity bounds (Pieter's rules of thumb):
- **Upper bound:** stock value rarely exceeds 2× monthly turnover. If capital_tied > 2× monthly_sales, something is wrong.
- **Lower bound:** days cover rarely falls below 15 days across the whole range. A store-level average below 15 days is a red flag.
- These bounds apply at store level across the full active range.

**Why:** Pack sizes drive ordering, and stock holding is a managed ratio to turnover. These bounds are reliable enough to use as automated sanity checks in future validation queries or dashboard alerts.

**How to apply:** When capital_tied figures are produced (L2 or L1), cross-check: capital_tied / (monthly_sales / 30) should be between ~15 and ~60 days. Figures outside that range should trigger a diagnostic before being trusted.
