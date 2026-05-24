# SocialBrand Dashboard — Deploy Log

Reverse-chronological. Each entry = one production deploy.

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
