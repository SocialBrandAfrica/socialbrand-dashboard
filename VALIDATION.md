# Data Validation Guide — Phase 3 Dashboard

Before you deploy or share the dashboard with Kagiso, you must confirm the numbers
match what Sigma reports. This guide walks you through the three-way check.

---

## Step 1 — Start the dashboard

1. Open File Explorer → Desktop → DIWAAIS → socialbrand-dashboard
2. Click in the address bar, type `powershell`, press Enter
3. Type `npm run dev` and press Enter
4. Open Chrome and go to http://localhost:3000

---

## Step 2 — Pick a reference date

Choose a date where you have the Sigma end-of-day printout or know the daily total
from memory. A good candidate is any day from the first two weeks of May 2026
where SPAR Delareyville (store 10116) had a normal trading day.

Write down:
- The date (format: YYYY-MM-DD, e.g. 2026-05-07)
- The Sigma daily sales total for that store on that date (excl. VAT)

---

## Step 3 — Run the SQL check in Supabase

1. Go to https://supabase.com/dashboard/project/crklvhfwyxlisfcvqenc
2. Click **SQL Editor** in the left sidebar
3. Paste the query below, replacing the date with your chosen date:

```sql
-- Direct raw-table total (the ground truth from the database)
SELECT
    store_code,
    snapshot_date,
    SUM(today_sales)  AS sql_total_sales,
    SUM(today_cost)   AS sql_total_cost,
    SUM(today_qty)    AS sql_total_qty,
    COUNT(*) FILTER (WHERE soh < 0)                        AS neg_soh,
    COUNT(*) FILTER (WHERE period_qty = 0 AND soh > 0
                     AND is_placeholder = FALSE)            AS slow_movers
FROM daily_snapshots
WHERE store_code = '10116'
  AND snapshot_date = '2026-05-07'   -- ← change this date
GROUP BY store_code, snapshot_date;
```

4. Also run the view version to confirm it matches the raw query:

```sql
-- View total (what the dashboard now reads)
SELECT
    store_code,
    snapshot_date,
    total_sales,
    total_cost,
    total_qty,
    neg_soh_count,
    slow_mover_count
FROM v_kpi_by_date
WHERE store_code = '10116'
  AND snapshot_date = '2026-05-07';  -- ← same date
```

---

## Step 4 — Compare the three figures

| Source | Total Sales (excl. VAT) |
|---|---|
| Sigma end-of-day printout | R _______ |
| SQL direct query (daily_snapshots) | R _______ |
| v_kpi_by_date view | R _______ |
| Dashboard KPI strip (SPAR Del selected, correct date) | R _______ |

**What the results mean:**

- If **all four match** → data is trustworthy. Proceed to Vercel deploy.
- If **Sigma ≠ SQL** → the parser or upload script introduced an error. Do not deploy.
  Check `parse_all_stores.bat` output and `upload_snapshots.py` logs for the date.
- If **SQL = Sigma but view ≠ SQL** → the view definition has a bug (unlikely, but
  re-run `supabase_views.sql` in the SQL Editor to recreate the views).
- If **view = SQL but dashboard ≠ view** → a component still has a stale query.
  Check the browser console for errors (F12 → Console tab).

---

## Notes

- The dashboard reads `total_sales` which is **excl. VAT** — make sure you compare
  against the Sigma excl. VAT figure, not the inc. VAT till total.
- If you get `null` or `0` from the view query but the raw query has data, the views
  may need to be recreated — run `supabase_views.sql` again in the SQL Editor.
