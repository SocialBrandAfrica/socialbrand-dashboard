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

A live-data demo served to potential StockFlow developer partners. Shows 11 locked SKUs
from store 10116 (Delareyville) with 6-week weekly sales buckets, SOH, cost, sell price,
and seasonal factors. Refreshes on the push schedule.

The UI is a standalone HTML file (`StockFlow-DevCorner-Demo.html`) served at `/pulse-mini`
behind Pulse auth. It is NOT part of the main React app.

---

### Files owned by this project

| File | Role |
|------|------|
| `public/StockFlow-DevCorner-Demo.html` | The demo UI (standalone HTML, not a React component) |
| `src/app/api/dev-corner/lines/route.js` | Data endpoint — 11 fixed EANs, curated output |
| Middleware (`src/middleware.js`) | `/pulse-mini` path is auth-protected via Pulse middleware |

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
