---
name: project_pulse_mini
description: SB-AP-007 Pulse Mini -- standalone demo project, parked unless explicitly called up
metadata:
  type: project
---

## SB-AP-007 — Pulse Mini (StockFlow Developer's Corner)

**Status:** PARKED. Do not touch unless Pieter explicitly says so.
This is a standalone demo project. Its scope, commits, and rules are separate from the main dashboard.

---

### What it is

A live-data demo for potential StockFlow developer partners. The CURRENT live page is the
**HMR Sushi consignment counter** for SPAR Delareyville (store 10116, `merch_group_nr=610`):
per-line per-day sales, sushi/Chinese split, a per-day feed-health strip, commission/owed split.
**Scope = group 610 ONLY** (sushi + Chinese consignment counter); the hot KITCHEN (HMR Hot Meals,
group 605) and the rest of the HMR department are store-owned production, **deliberately excluded** —
"no kitchen sales" is by design, not a bug. (An earlier "11 grocery SKUs / 6-week buckets" build
also exists at `src/app/api/dev-corner/lines/route.js` — LEGACY, not used by the live HTML.)

Live + **public** (commit 789aaf1, no longer auth-gated) at
`https://dashboard.socialbrand.africa/StockFlow-DevCorner-Demo.html`. NOT part of the main React app.
Go-live security = WIRE-001 Route 3 (dedicated restricted partner key); draft `sql/pmini_partner_lockdown.sql`.

**Data path:** HTML → `/api/dev-corner/sigma-lines` (sales + classification + feed health) +
`/api/dev-corner/consignment` (no-sales + price flags). Sales come from `rpc_consignment_lines`,
which reads the **`l2_consignment_daily` matview** — a NIGHTLY snapshot refreshed by
`refresh_l2_pipeline`. If the page looks stale/behind the live ledger, run
`refresh_l2_consignment_daily('10116')`, NOT a page change (this was the "dates not updated" cause,
2026-06-16). Classification (sushi='s'/Chinese='c') currently via `sigma_ean_master.barcode`-200000
(R25-deprecated; re-source off `v_item_ean`).

---

### Files owned by this project

| File | Role |
|------|------|
| `public/StockFlow-DevCorner-Demo.html` | The demo UI (standalone HTML) — HMR Sushi consignment |
| `src/app/api/dev-corner/sigma-lines/route.js` | **PRIMARY** data endpoint — per-line per-day sales + classification + feed health (DBUMBA) |
| `src/app/api/dev-corner/consignment/route.js` | Flags endpoint — no-sales lines + price mismatches |
| `src/app/api/dev-corner/lines/route.js` | **LEGACY** — old 11-grocery-SKU endpoint, NOT called by the live HTML |
| `src/middleware.js` | `/StockFlow-DevCorner-Demo.html` + `/api/dev-corner/*` are in `isPublic` (789aaf1) — page is public, NOT auth-gated |

**Briefs (DIWAAIS root):**
- `STOCKFLOW-DEVELOPERS-CORNER-BRIEF.md` — spec and security contract
- `STOCKFLOW-DEVELOPERS-CORNER-REPLIT-PROMPT.md` — Replit build prompt for partners
- `STOCKFLOW-ADHOC-STOCKTAKE-BRIEF.md` — related stocktake feature brief

---

### Security contract (brief §6a — do not change without explicit instruction)

- SELECT-only: anon key has no write rights on this data path
- Fixed output: exactly 11 lines, EAN list locked server-side — no query param can change what is returned
- No schema leak: response uses curated field names only (no table/column names, no internal IDs)
- CORS: same-origin (no `Access-Control-Allow-Origin: *`)
- Keys never in response, page, or URL

---

### Commit scope

Commits tagged `SB-AP-007` or `Pulse Mini:` belong to this project. They are independent
of the main dashboard release train. When reviewing main-project status, ignore these commits.

---

### Park rule

**Why:** Pulse Mini is a demo/pitch tool, not a production feature. Work on it is episodic
and brief-driven. Treating it as part of the main project pollutes standups, handovers,
and the open-items list.

**How to apply:** If a handover, status summary, or task list mentions Pulse Mini without
an active brief from Pieter, note it as "parked" and exclude it from the open-items count.
Only pick it up when Pieter explicitly names it or references SB-AP-007.
