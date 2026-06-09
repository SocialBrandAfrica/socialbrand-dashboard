# SocialBrand Dashboard — Deploy Log

Reverse-chronological. Each entry = one production deploy.

---

## 2026-06-09 — Pulse Mini live: auth gate removed + weather + no-data fixes

**Commit:** 789aaf1 (feat(pulse-mini): make app publicly accessible + fix weather bugs)
**Status: LIVE 2026-06-09 — auto-deployed to Vercel from GitHub push.**

**Changes:**

| File | Change |
|---|---|
| `middleware.js` | Added `/StockFlow-DevCorner-Demo.html` + `/api/dev-corner/*` to `isPublic` — app was previously auth-gated (required dashboard login). Now publicly accessible. |
| `public/StockFlow-DevCorner-Demo.html` | Weather month label: removed hardcoded `' Jun'`, now uses `MON[dt.getMonth()]`. Today highlight: was `i===0`, now compares ISO date string. WX_FB fallback dates: converted from static June 6-12 to dynamic 7-day window from `new Date()`. No-data message: removed internal table name reference. |
| `src/app/api/dev-corner/consignment/route.js` | Added `replit` to origin allow list (consistent with sigma-lines endpoint). |

**Live URL:** `https://dashboard.socialbrand.africa/StockFlow-DevCorner-Demo.html`

**Data layer (all pre-existing, confirmed live):**
- `l2_consignment_daily` — June data live (deployed 2026-06-08 by Pieter)
- `rpc_consignment_lines` — thin SELECT from L2, no join at fetch
- `rpc_feed_health_daily` — per-day completeness for feed health strip

**Open wire:** `refresh_l2_consignment_daily('10116')` must still be added to the nightly extractor post-push chain for July+ data to auto-populate. Until then, Pieter runs it manually in SQL Editor at month-start. Bundle with next extractor version.

---

## 2026-06-08 — SB-INDEX-005 Phase 1: l2_kpi_daily sales source migrated to sigma_sales

**Commit:** 63b1ef9 (feat(SB-INDEX-005): Phase 1 -- l2_kpi_daily sales from sigma_sales)
**Status: LIVE 2026-06-08 — deployed by Pieter, acceptance query returned 0 delta rows (all stores match sigma_sales exactly).**

**Change:** `sales_agg` CTE in l2_kpi_daily rewritten. Source changed from `daily_snapshots` to `sigma_sales`.

| Before | After |
|---|---|
| `MAX(snapshot_date)` per store from `daily_snapshots` | `MAX(sale_date)` per store from `sigma_sales` (period_kind='T' AND txn_kind=1) |
| `SUM(today_sales/cost/qty)` | `SUM(sales_incl_vat/qty)` from sigma_sales; `sales_cost=0`; `gp_pct=NULL` |

**PM rulings (SB-INDEX-005 v1.3, 2026-06-08):**
- Decision 1: Option A (NULL/0 now) + Option B (dEKUmsatz via extractor) bundled with next extractor version
- Decision 2: Phase 2 (v_kpi_by_date migration) = separate PM brief, not concurrent

**Pre-deploy verification (live DB, 2026-06-08):**
- sigma_sales latest_date = 2026-06-07 on all 5 stores (80579 date lag now resolved in sigma_sales)
- sigma_sales 2026-05-29 for 10116: R383,388 / 2,786 lines — CONFIRMED (the missing EOD exists in DBUMBA)
- Expected post-deploy sales_incl_vat vs current daily_snapshots values:

| Store | daily_snapshots (current) | sigma_sales 06-07 (post-deploy) | Delta |
|---|---|---|---|
| 10116 | R153,801 | R155,537 | +1.1% (PRSSALE variance) |
| 21355 | R6,720 | R6,720 | 0.0% |
| 80175 | R91,553 | R91,811 | +0.3% |
| 80176 | R22,244 | R22,244 | 0.0% |
| 80579 | R33,072 @ 06-06 | R2,712 @ 06-07 | Date moves; R2,712 Sunday TOPS plausible |

- Nothing in frontend or RPCs reads l2_kpi_daily.gp_pct (verified 2026-06-08)
- stock_agg/capital/signals: unchanged (still from l2_stock_position)

**Acceptance query (run after deploy + REFRESH):**
```sql
SELECT
    kpi.store_code,
    kpi.sales_date,
    ROUND(kpi.sales_incl_vat::numeric, 0)  AS kpi_sales,
    ROUND(sig.sigma_sales::numeric, 0)      AS sigma_src,
    ROUND((kpi.sales_incl_vat - sig.sigma_sales)::numeric, 0) AS delta
FROM l2_kpi_daily kpi
JOIN (
    SELECT store_code, SUM(sales_incl_vat) AS sigma_sales
    FROM sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1
      AND sale_date = (SELECT MAX(sale_date) FROM sigma_sales
                       WHERE store_code = sigma_sales.store_code
                         AND period_kind = 'T' AND txn_kind = 1)
    GROUP BY store_code
) sig ON sig.store_code = kpi.store_code
ORDER BY kpi.store_code;
-- Expected: delta = 0 (kpi_sales sourced directly from sigma_sales)
```

---

## 2026-06-08 — AUDIT-002 L2 restructure: l2_consignment_daily + rpc_consignment_lines thin SELECT

**Commits:** 450928f (sql/create_l2_consignment_daily.sql NEW + sql/rpc_consignment_lines.sql REWRITE)
**Deployed by Pieter in SQL Editor — both files LIVE 2026-06-08.**

**Structural change:** rpc_consignment_lines was performing the sigma_sales x sigma_articles classification join at fetch time (L2 logic in the L3 path). Restructured per PM GO:

**sql/create_l2_consignment_daily.sql (NEW — L2 derived table):**
- DROP + CREATE per Rule 19. L2 engine output for HMR SUSHI consignment (store 10116, merch_group 610).
- Pre-classifies at refresh: sigma_sales x sigma_articles join, BREAKFAST + MABELA excluded, anchor sale_date >= 2026-06-01 (combo-launch boundary; pre-June recycled 100k-range product codes do not map to current sigma_articles — blank by design, R20 class).
- Per-row: store_code, sale_date, product_code, description, item_type (s/c), sales, qty, commission (10%), owed (90%).
- Refresh function refresh_l2_consignment_daily(p_store): DELETE + re-INSERT current month only; historical months committed.
- GRANT SELECT TO anon. Unique: (store_code, sale_date, product_code).
- Nightly refresh: call after l2_kpi_daily. Pending wiring into extractor post-push chain.

**sql/rpc_consignment_lines.sql (REWRITE — thin SELECT):**
- Plain SELECT from l2_consignment_daily. No join at fetch. No classification at fetch.
- Signature unchanged (p_month, p_store, p_group, p_client) for backward compat.
- Pre-June returns 0 rows by design.

**Regression verified to the rand (all 7 June days):**
Jun 1=8110 / Jun 2=4119 / Jun 3=5093 / Jun 4=2179 / Jun 5=4598 / Jun 6=3957 / Jun 7=2731
rpc thin SELECT: R30,787 total / 37 distinct lines / 7 days loaded.

**Classification note:** item_type='s' vs 'c' currently all 'c' — June product_codes link to sigma_ean_master barcodes outside 200000+ range. Column structurally correct; split populates when barcode data is reconciled (separate data-maintenance item, no impact on totals).

**Standing rule established:** applets source sales from sigma_sales (DBUMBA) only. daily_snapshots acceptable for non-sales data (shelf price, SOH, EAN catalogue) until those are mirrored directly. A missed EOD must never create a silent hole in any number driving a business decision. Core pipeline migration (l2_kpi_daily sales input) = SB-INDEX-005.

---

## 2026-06-08 session 2 — L2-001 Steps 3+SOH: extractor v1.4, l2_ranging_tier, l2_soh_daily

**Commit:** 254191e (feat(L2-001): extractor v1.4 + l2_ranging_tier + l2_soh_daily SQL)

**Extractor v1.4 (scripts/Invoke-ExtractFromSigmaSQL.ps1):**
- Invoke-SnapshotSohDaily added. Runs before Invoke-ExtractLifecycle.
  Reads product_code, dBestand (soh), dStdBest (standard_stock) from DBStAr.
  Pushes to l2_soh_daily with ON CONFLICT DO NOTHING (ignore-duplicates).
  UTF-8 POST body (PGRST102 prevention). ASCII-only. Batches at $BatchSize.
- ValidateSet updated: soh_daily now a valid -TableName value for reruns.
- Version history in .NOTES updated with v1.3 (UTF-8 fix) and v1.4 entries.

**sql/create_l2_soh_daily.sql (Gate 2 Option A):**
- Persistent history table: one row per (client_id, store_code, product_code, snapshot_date).
- PK enforces ON CONFLICT DO NOTHING idempotency.
- Two indexes: idx_l2_soh_store_date, idx_l2_soh_latest.
- Scale: ~325k rows/day, 13-month retention, ~7.8 GB at full scale.

**sql/create_l2_ranging_tier.sql (Step 3):**
- MV: DENSE_RANK per store by 91d value DESC and qty DESC from l2_rate_of_sale.
- Tier: TOP_100 (value_rank<=100 AND qty_rank<=100), TOP_1000 (either<=1000), BOR.
- Carries: in_both_top100, value_rank, qty_rank, daily_ros_91d, never_sold (for l2_kpi_daily).
- Four indexes: PK, store+tier, TOP_100 partial, value_rank.
- Does NOT join l2_item_classification (Gate 3 still open).

**Pending Pieter SQL-Editor actions (all pre-commit SQL done, deploy via Supabase SQL Editor):**
1. REFRESH MATERIALIZED VIEW l2_movements_typed; (picks up 4 new stores)
2. REFRESH MATERIALIZED VIEW l2_rate_of_sale;   (picks up 4 new stores)
3. Run sql/create_l2_item_classification.sql    (Step 2 classifier MV)
4. Run the Gate 3 verification queries at the bottom of that file
5. Run sql/create_l2_soh_daily.sql             (Gate 2 history table)
6. Run sql/create_l2_ranging_tier.sql          (Step 3 tier MV)

**Self-updater will carry v1.4 to all 5 servers on next nightly run.**

---

## 2026-06-08 — L2-001 Step 2: l2_item_classification SQL committed

**What (SB-CC-L2-001 step 2):** Keystone Layer 2 classification MV written
to `sql/create_l2_item_classification.sql`. Pending Pieter's run in Supabase
SQL Editor (read-only MCP cannot run REFRESH or CREATE).

**Signal stack (priority cascade):**
- S1 NON_STOCK_DEPT: dept in (AIRTIME, FRONTEND PACK, EXPENSES, DORMANT,
  NON SCAN SALES, ONLINE *, SPAR MOBILE, dept 99). Deterministic. conf=1.00.
- S2 DIM_EXCLUDED: dept_nr=0 (DEPT_ZERO_PLACEHOLDER) OR subdept orphan
  (merch_group_nr absent from sigma_subdepts). Deterministic. conf=1.00.
- S3 PROD_INPUT_SUBDEPT: subdept name contains INGREDIENTS, PACKAGING, or
  WASTAGE. conf=0.95. Covers all production depts (Bakery/Deli/Butchery/HMR
  /FishShop/Produce/Flowers/CoffeeShop via *XING/*XPAC/*XWAS short codes).
- S4 RECEIPTING_BREAK: scale_flag='0' AND SOH < -1000. Scale items excluded
  (their negative SOH is Type A depletion, not a data error). conf=0.90.
- S5 PROD_DEPT_NEVER_SOLD: production dept + last_sale_date=1990-01-01
  sentinel. Base conf=0.80; boosted to 0.85 by S7, 0.88 by S6, 0.92 by both.
- NORMAL: everything else. conf=0.99.

**Design decisions verified against live 10116 data (2026-06-08):**
- scale_flag from cWAG (one A): valid (0=67,024 / 1=2,775). Not cWAAGE.
- 1990-01-01 sentinel = never-sold in sigma_lifecycle (64,289 articles on 10116).
- sigma_lifecycle.last_sale_date always populated (0 nulls on 10116).
- DIM_EXCLUDED covers sigma_dimension_exclusions rules without querying that
  table directly (dept_nr=0 catches DEPT_CODE; NULL subdept join catches SUBDEPT_ORPHAN).
- plu_flag='1': 99 articles on 10116 (SPAR only). Boosts PRODUCTION confidence.

**80175 SPAR Roosville Gate 1 verified this session:** All 12 tables loaded,
1,049,117 sales rows, span 2025-02-01 to 2026-06-07. Gate 1 PASS. All 5
stores now hold full Layer 1 history.

**Two pending Pieter SQL-Editor actions:**
1. REFRESH MATERIALIZED VIEW l2_movements_typed;
   REFRESH MATERIALIZED VIEW l2_rate_of_sale;
   (picks up the 4 new stores loaded since Step 1 was created)
2. Run sql/create_l2_item_classification.sql (creates the MV + indexes).
   Then run the Gate 3 verification queries at the bottom of the file.

---

## 2026-06-07 session 3 — ROLLOUT-001 complete (4/5), L2-001 Step 1 LIVE, gates 2+4 written

**ROLLOUT-001 — Layer 1 full-refresh + scheduled tasks:**
- 21355 TOPS Delareyville: all 12 tables loaded (sales 114k, movements 123k, articles 52k). Gate 1 PASS.
- 80176 TOPS Roosville: all 12 tables loaded (sales 121k, movements 122k, articles 46k). Gate 1 PASS.
- 80579 TOPS Dice: all 12 tables loaded (sales 118k, movements 109k, articles 52k). Gate 1 PASS.
- 80175 SPAR Roosville: first run partial (sales+movements only); second run in progress at handover.
  Gate 1 pending — verify on next session start.
- 10116 SRSDELAREYVILES: delta catch-up run (no -FullRefresh). Sales now current to 2026-06-07.
- All 5 servers: SocialBrand Sunday Push task registered (weekly Sunday 16:15, based on observed
  TAC zip times 15:23-15:34 on 4 Sundays). Script: Create-SundayPushTask.ps1.
- All 5 servers: SocialBrand-ExtractDelta task registered (daily 19:40). Script: Create-ExtractorScheduledTask.ps1.

**L2-001 Step 1 SQL — LIVE (Pieter ran in Supabase SQL Editor, 2026-06-07):**
- l2_movements_typed: 1,340,758 rows, 5 movement classes, 10116 only.
- l2_rate_of_sale: 69,798 rows (= all sigma_articles), 10116 only.
- Both MVs need REFRESH once 80175 load completes (picks up all 5 stores).
  Run in SQL Editor: REFRESH MATERIALIZED VIEW l2_movements_typed;
                     REFRESH MATERIALIZED VIEW l2_rate_of_sale;

**L2-001 brief SB-CC-L2-001 updated:**
- Gates 2+4 proposals written (CC, data-backed from 10116 analysis).
  Gate 2 rec: Option A (sigma_lifecycle.soh daily snapshot -> l2_soh_daily). Gate 4 rec: sigma_supplier_link.list_cost.
- SOH data quality section added: ghost stock patterns + negative SOH patterns documented with 10116 evidence.
  Engine handles programmatically via classification signal stack (no per-store manual fixes).
- Scope expansion: sigma_promotions + sigma_promotion_articles added as L1 additions (DBPROME/DBPROMAR);
  l2_promotion_effect + l2_production_yield added to object map.
- configuration_group_map (production reverse-cost engine) documented as non-L1 config table.
- PM ratification required before Step 2 build starts.

---

## 2026-06-07 — L2-001 Step 1 SQL migrations committed (commit 180d00c)

**What (SB-CC-L2-001 step 1):** Two Layer 2 materialised view migrations added to
`sql/` — pending Pieter's run in Supabase SQL Editor.

- `sql/create_l2_movements_typed.sql` — MATERIALIZED VIEW over sigma_movements.
  Classifies every DBBEBE row by movement_class (RECEIPT/IDT/ADJUSTMENT/
  EOD_CORRECTION/OTHER) and adds `is_excluded` flag (TRUE for IDT; IBT slot
  reserved). 4 indexes. Verified against live 10116 distribution (1,340,758 rows,
  K/null 81%, R/W 13%, I/M 3%).
- `sql/create_l2_rate_of_sale.sql` — MATERIALIZED VIEW over sigma_articles + sigma_sales.
  91-day and 14-day rolling ROS windows relative to CURRENT_DATE at refresh.
  daily_ros_91d feeds l2_ranging_tier; days_since_last_sale + never_sold feed
  classifier (gate 6). Base: sigma_articles (69,798 rows). 4 indexes.

**Pending:** Pieter runs both files in Supabase SQL Editor (read-only MCP).
After run: verify row counts match sigma_articles, spot-check top sellers.

---

## 2026-06-07 — Push v3.19 + extractor sidecar + delta schedule script (commit 2e898df)

**What (ROLLOUT-001 CC prep):**
- `Push-SigmaToSupabase.ps1 v3.18 -> v3.19`: Added `Invoke-DeployExtractor()`
  sidecar that downloads `Invoke-ExtractFromSigmaSQL.ps1` from GitHub raw on every
  nightly run. Non-fatal on failure. Deploy path: self-updater carries v3.19 to all 5
  servers on tonight's 20:00 push; extractor then present on disk for Pieter's
  `-FullRefresh` RDP sessions per store.
- `scripts/Create-ExtractorScheduledTask.ps1` (new): Run once per server as Admin
  after full-refresh verifies (ROLLOUT-001 Gate 1-4). Creates
  `SocialBrand-ExtractDelta` task at 19:40 daily (after EASYDB rebuild ~19:20,
  before nightly push at 20:00). Requires Pieter's RDP; ASCII-only.

---

## 2026-06-07 — CRASH-001 fix: isActiveLine scope bug (commit c71dedf)

**What (SB-CC-CRASH-001):** Fixed production crash that white-screened the entire
dashboard whenever any report was opened.

Root cause: `sellThroughRate` useMemo (page.jsx ~2073) called `isActiveLine(r)` —
a helper defined inside `buildReport()` (line 255) — but the useMemo runs in
component body scope where `isActiveLine` does not exist. ReferenceError escaped
the memo with no error boundary, crashing the whole page.

Fix: Defined `refDate` + `activeLineCutoff` + `isActiveLine` inside the
`sellThroughRate` memo (3 lines), using the byte-identical definition from
`buildReport` (`cutoff = shiftDate(refDate, -ACTIVE_LINE_LOOKBACK)`). Added
`selectedDates` to the dependency array.

Deploy path: pushed to GitHub main; Vercel auto-deploy active.

---

## 2026-06-05 — DIWAAIS governance repo live (SocialBrandAfrica/diwaais-governance)

**What:** The DIWAAIS governance layer (Bible, handovers, briefs, archive — 215 files) is
now under version control at `https://github.com/SocialBrandAfrica/diwaais-governance`
(private repo). Broken `.git` cleared, fresh init, branch `main`, 233 objects pushed.
`.gitignore` excludes `socialbrand-dashboard/` (separate repo), store data dirs
(`SPAR_*/`, `TOPS_*/`), CSVs, binaries, and secrets.

---

## 2026-06-05 — Push-SigmaToSupabase v3.18: UTF-8 body fix + empty-key guard (commit 040895f)

**What (SB-CC-PUSH-003):** All data POST bodies in `Push-SigmaToSupabase.ps1` now sent
as UTF-8 bytes (`[System.Text.Encoding]::UTF8.GetBytes($json)`) with
`Content-Type: application/json; charset=utf-8`. Callsites fixed: `Send-Batch` batch
+ row-by-row fallback, `Write-PushError`, `Push-RefTables` dept + subdept.
Added empty-key guard: clear diagnostic if `C:\socialbrand\sb-key.txt` is blank.
**Root cause:** same PGRST102 bug as extractor v1.3 (CLAUDE-CODE-RULES R15) — NBSP and
non-ASCII in product descriptions sent invalid UTF-8, causing silent row drops in
`daily_snapshots` on every store every night.
**Deploy path:** self-updater carries v3.18 to all 5 servers on tonight's 20:00 push.
**Verify:** after tonight's run, confirm an accented product (e.g. NBSP in description)
lands correctly in `daily_snapshots`. Check push_log for SUCCESS + expected row count.

---

## 2026-06-05 — Search-from-source fix: cache optimistic-only (commit 5ecdf6b)

**What:** `page.jsx` scoped search path (dept/store filter active) no longer uses
localStorage as authoritative. Cache is shown immediately (optimistic UX) then always
replaced by a live `product_search_index` fetch. Key bumped `v1→v2` to flush stale
caches on first load. New products from overnight pushes are now visible in search
immediately after load.
**Deploy path:** pushed to GitHub main, Vercel picks up automatically.

---

## 2026-06-04 — O1 fix: rpc_dept_summary overload collision (commit ce69e60)

**Bug (O1 / SB-VAL-001):** "Sales by Department" panel showed "No sales data".
Root cause: TWO `rpc_dept_summary` overloads coexisted (PGRST203) — the index-safe
version from `fix_index_rule_dept_rpcs.sql` `(…,p_eans,p_subdept)` and a second one
created by `sb_cc_dept_kpi_001` whose `DROP` named the wrong signature, so the drop
missed. The new overload also re-introduced the Rule-4 `snapshot_date::text` cast.
Separately, a 3-arg `classify_snapshot_item` call hit 42725 (ambiguous against
patch1's 4-arg DEFAULT NULL overload).
**Fix:** `sql/fix_rpc_dept_summary_overload_collision.sql` — dropped both explicit
signatures, recreated ONE canonical `rpc_dept_summary(p_store_codes, p_dates,
p_subdept, p_eans)` returning `…, capital_tied`, using index-safe
`snapshot_date = ANY(p_dates::date[])` and the 4-arg
`classify_snapshot_item(...,last_sales_date_iso)` so dept capital mirrors
`v_kpi_by_date` exactly.
**Verify:** pg_proc shows 1 `rpc_dept_summary` row; live dashboard "Sales by
Department" renders depts + LY deltas (GROCERIES FOODS R367.2k, BUTCHERY R137.2k…).
**Confirmed working:** YES (live, 2026-06-04).
**Note:** surfaced that `mv_kpi_by_date` is stale (multi-date headline still R9.83M);
`v_kpi_by_date` is already patch1-applied (~R1M). MV recreate+refresh + orphan 3-arg
`classify_snapshot_item` drop pending — diagnostics in `sql/diag_classify_mv_state.sql`.

---

## 2026-05-24 — Session 18, push v3.11 parse fix (commit 07e7108)

**Bug:** `$finalStatus:` in backfill Write-Host line was parsed by PowerShell as a
namespace-scoped variable reference (`$env:PATH` pattern). Hard parse error prevented
the entire script from loading — all 5 servers failed silently, no push_log entries.
**Fix:** `${finalStatus}:` — curly braces delimit the variable name.
Self-updater cannot fix a parse error (script can't load to run the updater).
Servers must be manually updated to v3.11 via Invoke-WebRequest.

---

## 2026-05-24 — Session 18, Google OAuth live + super-admin decision

**Google Cloud OAuth credentials configured (2026-05-24):**
- Project: `dashboardsocialbrandafrica`
- Client ID + Secret: stored in Supabase Auth > Providers > Google (not in git -- public repo)
- Authorized redirect URI: `https://crklvhfwyxlisfcvqenc.supabase.co/auth/v1/callback`
- Supabase Google provider: **ENABLED**

**PM decision — Phase 1 access tiers:**
All authenticated users have super-admin (owner) access until access tiers are
formally introduced. user_profiles row is optional — if missing, full access is
granted anyway. Store isolation by role is code-complete but disabled.

**Code change (page.jsx):**
- `loadProfile` no longer blocks on user_profiles row.
  Missing row → synthetic `{ role: 'owner' }` profile → all 5 stores visible.
- `isManagerLocked` hardcoded `false` (store selector always shown).
- "Access Pending" screen remains in code but is unreachable until tiers are wired.

---

## 2026-05-24 — Session 18, MOBILE-AUTH-BRIEF (commit b1f4e38)

**New package:** `@supabase/ssr` ^0.5.2

### Google OAuth + Supabase Auth
- `middleware.js`: auth guard — all routes redirect to `/login` if no valid session.
  Allows `/login`, `/auth/*`, and static `.html` files through unauthenticated.
- `src/app/auth/callback/route.js`: PKCE callback — exchanges OAuth code for session cookie.
- `src/app/login/page.jsx`: dark-theme Google sign-in page. No email/password.
- `src/lib/supabase.js`: switched from `createClient` to `createBrowserClient` from `@supabase/ssr`.
  Cookie-based session storage required for middleware auth checks.

### Store isolation
- `src/app/page.jsx`:
  - `storeCodes` now initialises to `[]` (populated after profile load, not on mount).
  - Auth useEffect: fetches `user_profiles` on mount; sets `storeCodes` to all stores (owner)
    or `[profile.store_code]` (manager).
  - `isManagerLocked`: hides store selector chips for non-owner roles.
  - Loading screen while profile loads; "Access Pending" screen if no profile row found.
  - Sign-out button in header (top-right): shows user's first name + exit icon.

### Phone layout
- `src/app/globals.css`: `zoom: 1.25` overridden to `zoom: 1` at max-width 767px.
  Without this, 375px phones render at an effective 300px width causing overflow.
- `src/app/dashboard.css`: mobile touch targets raised from 36px to 44px (WCAG minimum).

### SQL migration
- `sql/mobile_auth_setup.sql`: adds `full_name` + `updated_at` columns to `user_profiles`,
  updates role CHECK constraint to include `owner` and `manager`, adds RLS policy
  `users_read_own_profile` (auth.uid() = id), adds FK to auth.users.
  **Pieter must run this in Supabase SQL Editor.**

### Pending (Pieter's manual steps)
See `PIETER-OAUTH-SETUP.md` on the Desktop for step-by-step instructions:
1. Create OAuth credentials in Google Cloud Console (~5 min)
2. Enable Google provider in Supabase Auth settings + set redirect URLs
3. Run `sql/mobile_auth_setup.sql` in Supabase SQL Editor
4. Sign in and seed Pieter's owner row in user_profiles

---

## 2026-05-24 — Session 17, data verification + push_log fix (v3.10)

**Commits:** af8c8b8 (Capital Tied fix), 8c360d0 (v3.10 push script)

### Bug fix: Capital Tied multi-date accumulation
- `src/app/page.jsx` line 1452: `kpiCapTied` changed from `kpiData.reduce()` to
  `latestKpiByStore.reduce()`. Stock KPIs are point-in-time; summing across dates gave 7x value on 7-day range.

### Bug fix: push_log snapshot_date / tac_filename always NULL (v3.10)
- Root cause: `Get-Headers` included `Prefer: resolution=merge-duplicates` on PATCH calls.
  This is an INSERT hint that caused PostgREST to silently drop unrecognised columns (the
  4 new push_log columns were added without `pg_notify` so cache was stale).
- Fix: added `Get-PatchHeaders` (omits resolution=merge-duplicates). Updated
  `Complete-PushLog` and `Clear-StuckRuns` to use it.
- `sql/fix_push_log_schema_cache.sql` -- **run once in Supabase SQL Editor** to reload
  PostgREST schema cache. Required before v3.10 will actually populate snapshot_date.
- `sql/sb_sch_001_step5_push_log_migration.sql` -- added pg_notify step for future re-runs.

**Pending:** deploy v3.10 to all 5 servers (Invoke-WebRequest from GitHub raw URL).

---

## 2026-05-24 — Session 16, CC-BRIEF-2026-05-24 (diagnostic + two-tier storage)

**Commit:** 5d877d4

### Diagnostic security fix (Item 1)
- `sql/rpc_diag_push_log.sql` — SECURITY DEFINER RPC replaces direct push_log REST query.
  **Must be run in Supabase SQL Editor before /diagnostics.html push_log section will work.**
- `public/diagnostics.html` — diagnose.html deployed to Vercel static at `/diagnostics.html`.
  Secret key removed; all queries use anon key via SECURITY DEFINER RPCs.
- Footer: subtle "Data Quality" link added to dashboard bottom, opens `/diagnostics.html`.
- `globals.css` — `zoom: 1.25` added (125% scale, from earlier in this session).

### Two-tier storage (Item 2 — SQL files ready, run order below)
- `sql/sb_ret_002_quarterly_aggregates.sql` — CREATE TABLE quarterly_aggregates + 2 indexes.
  **Run first.**
- `sql/sb_ret_002_purge_function_v2.sql` — Replaces purge_old_snapshots() with aggregate-then-delete.
  pg_cron job id=4 unchanged (same function name). **Run second.**
  Verify after: `SELECT jobid, jobname, active FROM cron.job WHERE jobname = 'sb-monthly-purge';`

### Other fixes this session
- `sql/add_pgcron_kpi_refresh.sql` — pg_cron job 5 created (nightly-kpi-refresh at 22:00 UTC).
  Already run and confirmed (job id=5 active).
- TAC50525.zip backfill: 33,537 rows pushed for TOPS Dice 2025-05-25.
- mv_kpi_by_date manually refreshed (view was stale -- 2025-05-25 now visible).

---

## 2026-05-24 — Session 14, Supabase secret key rotation

**No commit — key not stored in repo.**

- Old key: legacy JWT service_role (was in git history of public repo -- CRITICAL)
- New key: `sb_secret__rpmX...` (Supabase new-style Secret key, named "push-scripts")
- Updated: `upload_snapshots.py` line 39 (local machine, not in git)
- Updated: `C:\socialbrand\sb-key.txt` on all 5 store servers (SPAR Del, TOPS Del, SPAR Roos, TOPS Roos, TOPS Dice)
- Verified: `Get-Content` on each server returned new key

**Still to do to fully close the old key:**
1. Update dashboard to use new publishable key (`sb_publishable__5cXL...`) instead of legacy anon JWT
2. Click "Disable JWT-based API keys" on Supabase legacy API keys page
   (this will make the old service_role JWT in git history permanently invalid)

---

## 2026-05-24 — Session 14, PULSE-BUG-001 + MOBILE-BRIEF complete

**Commits:** a0fe5f6, 09fc30a, 8e5c67b

### PULSE-BUG-001 — all 8 bugs fixed
**Status: Deployed to GitHub main.**
**File:** `src/app/page.jsx`

- **BUG-1:** focusEans wired into rpc_top20, rpc_dept_summary, rpc_kpi_dept_counts — Focus Area basket now actually filters all data panels
- **BUG-2:** Cancellation flag on rpc_focus_top5 auto-populate effect — prevents race condition overwriting manual basket
- **BUG-3:** normalizeDept() applied before dept_name comparisons in kpiNegSOH + kpiSlowMove (dotted names e.g. GROCERIES.FOODS now match)
- **BUG-4:** KPI useMemos now branch on subDeptFilter using pre-filtered deptSummary/deptSohCounts — KPI strip responds to sub-dept filter
- **BUG-5:** clearStoreSelection sets [] not ALL_STORE_CODES (was a no-op)
- **BUG-6:** fetchAllRows capped at 10,000 rows — prevents 17+ RPC calls on large multi-store multi-date sets
- **BUG-7:** slowmovers + negsoh KPI cards now have onClick (open drawer), matching the reorder card
- **BUG-8:** activeProducts gives selectedProduct priority over focusBasket; top20 useMemo skips filter for non_movers; handleClose corrected

### MOBILE-BRIEF — all 17 items + critical bugs
**Status: Deployed to GitHub main.**
**Files:** `src/app/layout.jsx`, `src/app/dashboard.css`, `src/app/page.jsx`, `src/components/ProductDetailPanel.jsx`, `src/components/PushStatusStrip.jsx`

- Viewport meta tag (layout.jsx)
- useIsMobile hook; isMobile conditionals for drawer/Reports button
- Responsive CSS classes + @media (max-width: 767px) overrides in dashboard.css
- Filter bar, main padding, header context, KPI strip, Top20+Dept grid, Reports drawer — all converted to CSS classes
- PushStatusStrip: sb-push-strip-inner (horizontal scroll on mobile)
- ProductDetailPanel BUG 0 (slice -90 dates), BUG A (minWidth:0/overflow:hidden), BUG B (XAxis interval max 12 ticks), BUG C (fixed 8px bars)
- ITEM 15: compact prop — skip charts + rpc_product_detail when multiple products active
- ITEM 16: min chars 4 before RPC; fetchLimit 150 cap; local results shown immediately while RPC runs
- ITEM 17: localStorage search index cache (24h TTL); viewsCache + deptCache + top20Cache (session Maps); _detailCache (module Map)

---

## 2026-05-24 — Session 12, v3.7 + Block 8 complete

**Commit:** dcc7667

### Push script v3.7 (Block 8 Step 12)
**Status: Pushed to GitHub main. Self-updater deploys tonight.**
**Files:** `scripts/Push-SigmaToSupabase.ps1`

**push_log enrichment:** `Complete-PushLog` now writes `snapshot_date`, `rows_expected`,
`tac_filename`, `duration_seconds` on every push_log update.

**PARTIAL status:** When `rows_pushed > 0 AND rows_failed > 0`, status is `PARTIAL` (not SUCCESS).
Full failure stays `FAILED`. Zero failures stays `SUCCESS`.

**Both nightly and backfill** modes updated with timing + new columns.

### Block 8 SQL files (all run in Supabase)
- `sql/sb_sch_001_step5_push_log_migration.sql` — push_log 4 new columns + index
- `sql/sb_sch_001_step6_push_errors.sql` — push_errors snapshot_date added
- `sql/sb_sch_001_step7_orders.sql` — orders shell
- `sql/sb_sch_001_step8_product_aliases.sql` — product_aliases shell
- `sql/sb_sch_001_step9_user_profiles.sql` — user_profiles shell (RLS, no policies)
- `sql/sb_sch_001_step10_audit_log.sql` — audit_log shell
- `sql/sb_ret_001_purge_function.sql` — purge_old_snapshots() + pg_cron job id=4
- `sql/sb_rhy_001_mini_payday_seed.sql` — 5th community_rhythm profile (Mini-payday, 13-16, x1.10)

---

## 2026-05-23 — Session 11, v3.6 + SQL

**Commit:** 93a587a

### Push script v3.6 + upsert_search_index delta (Push script + SQL)
**Status: Script committed. SQL pending Pieter running upsert_search_index_delta.sql in Supabase.**
**Files:** `scripts/Push-SigmaToSupabase.ps1`, `sql/upsert_search_index_delta.sql`

**NULL-date guard:** `Test-IsoDate` validates snapshot_date extracted from each TAC zip before
any rows are pushed. Invalid date writes FAILED to push_log and aborts that date cleanly.
Applies in both nightly and backfill modes.

**Delta search index:** `upsert_search_index` now accepts optional `p_snapshot_date date`.
Nightly mode passes today's date -- only re-indexes EANs seen in today's push (fast).
Backfill mode passes nothing -- full rebuild (existing behaviour).
Self-updater will deploy v3.6 to all 5 servers on next nightly push (after SQL runs).

**How to verify:** Check push_log output tomorrow morning -- search_index line should show
"delta YYYY-MM-DD" not "full rebuild".

---

## 2026-05-23 — Session 11, Bug Fix

**Commit:** 92f6a78

### upsert_search_index — null last_seen on dormant products (SQL)
**Status: Deployed and verified in Supabase**
**File:** `sql/fix_upsert_search_index_null_last_seen.sql`

Root cause: dormant/placeholder products in daily_snapshots have snapshot_date IS NULL.
MAX(snapshot_date) over an all-NULL group returns NULL, which violated the NOT NULL
constraint on product_search_index.last_seen. GREATEST(existing, NULL) also returns NULL
on the conflict-update path, making it hit even for existing rows.

Fix: added `AND snapshot_date IS NOT NULL` to the WHERE clause in upsert_search_index.
Products with no valid snapshot date are excluded from the search index.

Verified: SELECT upsert_search_index('80579') ran without error and returned NULL (void).

---

## 2026-05-21 — Session 2, Batch 3

**Commits:** pending push after this entry

### Issue 1 — rpc_dept_summary + rpc_kpi_dept_counts 18-second regression (SQL)
**Status: Deployed and verified in Supabase**
**File:** `sql/fix_index_rule_dept_rpcs.sql`

Root cause: `snapshot_date::text = ANY(p_dates)` in both functions. Casting the column
to text prevents PostgreSQL from using the snapshot_date index on the 10.4M-row
daily_snapshots table. Has been in every version since add_ean_filter.sql; became
noticeable as the table grew.

Fix: `snapshot_date = ANY(p_dates::date[])` — cast the parameter array, not the column.
Both functions dropped (CASCADE, no signature) and recreated clean with correct rule.
After running, Sales by Department should load in under 3 seconds.

### Issue 2 — Search: stale closure caused incorrect RPC params (Frontend)
**Status: Deployed in this batch**

Root cause: `deptFilter`, `subDeptFilter`, and `deptNormMap` were used inside the
ProductSearchBar debounce effect but were NOT in its deps array. On switching from a
specific dept (populated local index) to All Depts, the effect re-ran with stale
dept-filter values. The RPC was called with wrong `p_dept_names` (showing results
filtered to the previous dept). Also missing effect cleanup (timer not cleared on unmount).

Fix:
- Added `deptFilter`, `subDeptFilter`, `deptNormMap` to the useEffect deps array
- Added `return () => { if (timerRef.current) clearTimeout(timerRef.current) }` cleanup

To confirm: type 3+ chars in the search box with All Depts + All Stores selected.
A POST to `rpc_search_products` must appear in the network tab within 400ms of
the last keystroke.

### Issue 3 — Bug 7: Reorder Items KPI card onClick not wired
**Status: Already fixed in commit 80b681c (previous batch)**

The `onClick` is correctly wired to the card div and calls
`setCurrentReport('reorder'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport()`.
The sub-label "Open report drawer" is styled teal/underlined when the onClick exists.
PM's report was based on a pre-fix version.

To confirm: click anywhere on the Reorder Items KPI card — the Reports & Downloads
drawer must slide open with Reorder List pre-selected.

### Issue 4 — Top 20 button layout: two rows instead of one coherent group (Frontend)
**Status: Deployed in this batch**

Root cause: By Qty/By Value toggle and Movers/Non-Movers toggle were rendered in two
separate `<div>` rows with `justifyContent: 'flex-end'` on the second. Looked broken —
the two controls were visually disconnected.

Fix: Collapsed to a single flex row in the panel header. Title on the left; on the right,
both pill-groups sit inline with a 1px vertical divider (height 14, rgba(255,255,255,0.12))
between them. Layout: `[By Qty][By Value] | [Movers][Non-Movers]`.

To confirm: Top 20 Movers panel header shows title on left and both toggle groups on the
right as one inline control bar separated by a thin vertical rule.

### Issue 5 — Non-Movers definition wrong (SQL)
**Status v1: Deployed but broken — superseded by v2**
**Status v2: Deployed and verified in Supabase**
**File v2:** `sql/fix_non_movers_v2.sql`

v1 root cause (fix_non_movers_definition.sql): two bugs discovered after deploy:
  1. last_sales_date_iso is a DATE column, not text. NULLIF(col, '') on a date column
     fails silently in plpgsql — returned zero rows instead of an error.
  2. period_qty = 0 (Sigma month-to-date) is the wrong metric for "no sales in 4 weeks".
     A product that sold on the 1st shows period_qty > 0 even if it hasn't moved since.

v2 definition (per PM brief — ROS > 0, no sales 4 weeks, SOH > 0, sold within 1 year):
  Replaces both conditions with a single BETWEEN on the DATE column:
    last_sales_date_iso BETWEEN (CURRENT_DATE - 365 days) AND (CURRENT_DATE - 28 days)
  NULL last_sales_date_iso rows (never sold) are excluded automatically by BETWEEN.
  Diagnostic confirmed 1,336,612 qualifying rows across all stores.

Movers branch is unchanged. Signature unchanged (still 7 params).

---

## 2026-05-21 — Session 2, Batch 2

**Commits:** 558ab7e, 928b07a, 80b681c

- `sql/restore_top20_params.sql` — rpc_top20: 7-param version with p_activity + p_parents
  restored. Confirmed in Supabase: 1 row, 7 arguments.
- `sql/fix_refresh_kpi_view.sql` — refresh_kpi_view: timeout fix via set_config.
  Confirmed in Supabase: 1 row, security_definer = true.
- Frontend: Movers/Non-Movers toggle, top20Activity state, p_activity/p_parents wired.
- Bug 7: Reorder Items KPI card clickable, opens drawer, pre-selects Reorder List.

---

## 2026-05-21 — Session 2, Batch 1

**Commits:** 3c37d97

- `sql/fix_top20_overload.sql` — rpc_top20 HTTP 500: nameless DROP CASCADE + 5-param
  recreate. Resolved the overload ambiguity. Superseded by restore_top20_params.sql.

---

## 2026-05-21 — Session 1

**Commits:** e904960, 8278c05, 78059f1, d97c5f2, 94c1550, 05abe42

PULSE-BUG-001 items 1–8 + Search Index. See handover_2026-05-21.md for details.
