---
name: project_2026-05-30-held-commits-pending-sql
description: Held (unpushed) commits and pending SQL as of 2026-05-30 — push after Pieter's verification
metadata:
  type: project
---

Four commits held unpushed on main. Push all at once once Pieter confirms Top-20 / Batch A-B verification passes.

| Commit | What |
|---|---|
| cdcc526 | SB-CC-PUSH-001: push script v3.17 false-push fix; PushStatusStrip freshness by snapshot_date |
| e9065d9 | SB-CC-SEL-001 P1+P4: LY/WoW Sales/Cost/GP/Qty dept-aware; Lost Sales dept-filtered; Stock Turn wired |
| 94af2fa | Tooltip below card; corrected today_sales label; Sales Trend anchors to last selected date (13 weeks back) |
| 693aae6 | SB-CC-SEL-001 P2: LY NegSOH/SlowMove now dept/subdept-aware via lyDeptSohCounts (5th call in dept effect, single latest LY date) |

**SEL-001 status:**
- P1 DONE (e9065d9)
- P2 DONE (693aae6)
- P3 SQL ON HOLD — blocked on Batch C / SB-AP-003 (redefining Capital Tied). Frontend already reads defensively; no regression.
- P4 DONE (e9065d9)

**Why held:** Pieter's live Top-20 / Batch A-B verification was in progress when these were committed. Stable bundle needed.

**How to apply:** `git push` once Pieter confirms verification pass. All 4 build clean.

**Capital SQL:** `sql/sb_cc_dept_kpi_001_capital_in_dept_summary.sql` — ON HOLD. Do not run until Batch C / SB-AP-003 settles the Capital Tied definition.
