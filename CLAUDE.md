# SocialBrand Dashboard — Project Instructions

## Session startup (run this first, every session)

This sequence is MANDATORY on every session start — including context-continuation sessions
that begin with a summary. A context summary is NOT a substitute for this procedure.
Do not touch any file, run any command, or begin any task until all four steps are done.

**Step 1 — ToolSearch (load browser + session tool schemas):**
```
ToolSearch({
  query: "select:mcp__Claude_in_Chrome__browser_batch,mcp__Claude_in_Chrome__javascript_tool,mcp__Claude_in_Chrome__computer,mcp__Claude_in_Chrome__find,mcp__Claude_in_Chrome__navigate,mcp__Claude_in_Chrome__tabs_context_mcp,mcp__Claude_in_Chrome__get_page_text,mcp__Claude_in_Chrome__read_page,mcp__Claude_in_Chrome__form_input,mcp__Claude_in_Chrome__tabs_create_mcp,mcp__Claude_in_Chrome__read_network_requests,mcp__Claude_in_Chrome__read_console_messages,mcp__computer-use__screenshot,mcp__computer-use__request_access,mcp__ccd_session__mark_chapter",
  max_results: 15
})
```
Do not skip — these tools are deferred and fail with InputValidationError if called without loading.

**Step 2 — Read the FULL start-load constitution (all ten, in this order — defined once in FILE-GOVERNANCE §0).** A hollow start (loading only some of these) is the documented root of drift and is a governance breach. Read every one, in full:
```
Read("C:\Users\User\Desktop\Daisy\NORTH_STAR.md")
Read("C:\Users\User\Desktop\Daisy\RULE-BOOK.md")
Read("C:\Users\User\Desktop\Daisy\CLEANUP-ENGINE-CANON.md")
Read("C:\Users\User\Desktop\Daisy\STOCK-TRIAGE-TOOL.md")
Read("C:\Users\User\Desktop\Daisy\SIGMA-CLEANUP-WORKFLOW.md")
Read("C:\Users\User\Desktop\Daisy\DB-SCHEMA.md")
Read("C:\Users\User\Desktop\Daisy\FILE-GOVERNANCE.md")
Read("C:\Users\User\Desktop\Daisy\HANDOVER-CURRENT.md")
Read("C:\Users\User\Desktop\Daisy\SB-VIS-001_Product_Vision_and_Philosophy.pdf")
Read("C:\Users\User\Desktop\Daisy\SB-PRIORITY-FRAMEWORK-001.md")
```
There are NO dated handover files in root — ever. If you find one, that is a governance breach: absorb its content into HANDOVER-CURRENT.md (your own section) and move the stray to `archive/handovers/`.

**Step 3 — RECITAL GATE (mandatory, the anti-hollow-start check). Before touching ANY file, running ANY command, or starting ANY task, output a checklist that names each of the ten files above with a ✓ confirming it was read THIS session.** If any line is not a ✓, the start is hollow — stop and read it. This recital is not optional and not satisfied by a context summary. (Added 2026-06-17 after a hollow start nearly shipped — Pieter: "I do NOT want to remind you OR Claude Code again.")

**Step 4 — Registry + clock gate:**
FILE-GOVERNANCE §0 (read in Step 2) is the Bible registry. Before creating ANY new file, run the §0 decision tree — if the content fits an existing canonical/log file, update that file in place. New root .md files are sanctioned ONLY as briefs (SB-XX-NNN-*) or PM-approved side-project folders. Take every date stamp from the system clock (`Get-Date` / `date`), never assumed — on 2026-06-07 two CC sessions were future-dated 06-08/06-09 and contaminated canon.

Only after the recital gate shows ten ✓: begin work.

Mid-session shortcut: `/autopilot` reloads all browser tool schemas if the session lost them.

---

## Standing references

- `C:\Users\User\Desktop\Daisy\RULE-BOOK.md` — domain vocabulary, time conventions, KPI formulas, GP% rules, mandatory SQL patterns, naming conventions. Authoritative: if a brief contradicts this, update here first, then update the brief.
- `C:\Users\User\Desktop\Daisy\DB-SCHEMA.md` — live schema, RPC function signatures, pending SQL tracker.
- **Sigma Fix Strategy (LIVING canon — read before ANY stock-cleanup / phantom-stock / TLX / Capital-Tied work):** `STOCK-TRIAGE-TOOL.md` (SB-INDEX-014) + `SIGMA-CLEANUP-WORKFLOW.md` (SB-INDEX-015). Every session develops and refines these — fold what you learn back in. CC's engine version = SB-CC-ANOM-001 Family 3 (Anomaly Radar item-outliers); the tool is the manual prototype you productionise.

---

## Project context

See memory files for full project context:
- `memory/MEMORY.md` — index of all memory files
- THE handover is `C:\Users\User\Desktop\Daisy\HANDOVER-CURRENT.md` — the only live one; read on session start
- No dated handover/session files in `memory/` either — session state belongs in HANDOVER-CURRENT.md; old dated memory handovers are archived in `Daisy\archive\handovers\`

## Team structure & design boundary (added 2026-06-19)

Three roles — know your lane:

| Role | Tool | Lane |
|---|---|---|
| **PM** | Cowork | Product decisions, briefs, R22 reconcile, approvals, this CLAUDE.md |
| **CC** | Claude Code (you) | All code commits, SQL, engine logic, performance — the heavy lifting |
| **CD** | Claude Design | CSS polish, visual refinements, component specs — design-system sandbox only |

**CD → CC handoff:** CD produces a spec (token names, behaviour notes, NEW-token labels). PM approves. CC implements from the spec. CC never touches CD's design-system project files. CD never edits live code in this repo.

**Priority order — non-negotiable:**
1. Data integrity (L1 sacred, R22 auditable, no silent skips)
2. Performance (server-friendly, fast loads, no seq-scan RPCs)
3. Design (CD's work yields if it costs performance or data accuracy)

If a design spec conflicts with performance or correctness, CC flags it to PM. Design waits. This is explicit and CD has been informed of the same.

**CD's GitHub snapshot:** CD reads this repo as read-only ground truth. It loaded from whatever was on `main` at setup time. When cosmetic branches are merged, CD should re-sync. CC does not need to do anything for this — it happens automatically on CD's next session.

---

## Key rules

- No Unicode in `.ps1` files — store servers are Windows-1252
- All scripts go in `socialbrand-dashboard/scripts/`; server output to `C:\socialbrand\` on store servers
- Full SQL files: fix the file in `sql/`, reference with path only — never dump full SQL in chat
- ASCII-only commit messages and PowerShell scripts
- Never edit code concurrently with a Cowork Claude — check who owns the file first

## Handover file rules (CORRECTED 2026-06-07 — the old "one file per calendar day" rule here was WRONG and caused duplicate handovers; FILE-GOVERNANCE wins)

There is exactly ONE live handover: `C:\Users\User\Desktop\Daisy\HANDOVER-CURRENT.md`. Both CC and PM write into it, each in their OWN section. Never create `HANDOVER_<date>.md`. Never use `Write` on it — always `Read` then `Edit` your own section (Write silently destroys the other author's content). Update the `Last touched:` line with name + system-clock timestamp on every edit; if it changed since you read, re-read before writing. Snapshots to `archive/handovers/` are made by PM at milestones — not by CC, not daily.
