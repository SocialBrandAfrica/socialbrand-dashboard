# SocialBrand Dashboard — Project Instructions

## Session startup (run this first, every session)

This sequence is MANDATORY on every session start — including context-continuation sessions
that begin with a summary. A context summary is NOT a substitute for this procedure.
Do not touch any file, run any command, or begin any task until all four steps are done.

**Step 1 — ToolSearch (load browser + session tool schemas):**
```
ToolSearch({
  query: "select:mcp__claude-in-chrome__browser_batch,mcp__claude-in-chrome__javascript_tool,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__find,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__form_input,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__read_network_requests,mcp__claude-in-chrome__read_console_messages,mcp__computer-use__screenshot,mcp__computer-use__request_access,mcp__ccd_session__mark_chapter",
  max_results: 15
})
```
Do not skip — these tools are deferred and fail with InputValidationError if called without loading.

**Step 2 — THE HARNESS IS A FULL READ (FILE-GOVERNANCE §0 v2.5, 2026-07-27).** Every registered canonical file the session's work can touch is read IN FULL at start. This is the standing rule and it is **never negotiated downward** — Pieter, 2026-07-27: *"this needs to hold accross all documentation. the best harnass i've had is the 10 files so far."* The named ten are its proven form:
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
plus **PIETERSTYLE.md and the `socialbrand-style` skill** every session. Memory is a pointer list, never a substitute for a file.

**The load is kept readable by capping the FILES, never by reading less (§0g THE DOCUMENT CEILING).** A file grown past 60KB is the defect; the fix is to split it and move its history to a `<NAME>-LINEAGE.md`, never to skim it. A document that cannot be read in full has stopped being canon and become an archive with a canonical name.

**THE INTERIM — in force ONLY while a start-load file breaches §0g. A declared debt with an owner, not the new normal.** Breaching as at 2026-07-27: **CLEANUP-ENGINE-CANON 234KB · DB-SCHEMA 158KB · RULE-BOOK 79KB.** While that holds, for a CC build-lane session:
- **Read in full:** HANDOVER-CURRENT · RULE-BOOK · FILE-GOVERNANCE · NORTH_STAR · SB-PRIORITY-FRAMEWORK-001 · SB-VIS-001 · PIETERSTYLE + the style skill · **DB-SCHEMA (CC's full read in the build lane)** · STOCK-TRIAGE-TOOL and SIGMA-CLEANUP-WORKFLOW **when the lane touches cleanup**.
- **CLEANUP-ENGINE-CANON: read the sections your DECLARED LANE touches, in full, off its own `## 0. SECTION INDEX`** (at the top of the file — read the index, never a remembered map).
- **Declare the lane WIDE rather than narrow.** If the lane changes mid-session, load the new lane's sections *before* working in it.

There are NO dated handover files in root — ever. If you find one, that is a governance breach: absorb its content into HANDOVER-CURRENT.md (your own section) and move the stray to `archive/handovers/`.

**Step 3 — RECITAL GATE (mandatory). It now PUBLISHES what was read, not a bare tick.** Before touching ANY file, running ANY command, or starting ANY task, output **one line per file: its name, its version, and what was read — either FULL or the sections named.** State **the lane on its own line**. Name **every section not read and the file that forced it**. A bare ✓ is no longer a recital, and a ✓ over a partial read is the hollow start wearing new clothes. A context summary or "I know this already" still fails the gate. (Gate added 2026-06-17 after a hollow start nearly shipped — Pieter: "I do NOT want to remind you OR Claude Code again.")

**Step 4 — THE THREE TEETH. They are what pays for any read smaller than everything.**
- **a. No canon rule is used from memory of a past read.** If the work needs a rule the lane did not load, **read that section first, then use it.** "I recall §14 says" is a breach, the same class as a hollow start.
- **b. The live database outranks every document on STATE.** Documents hold truth and law; what is built, populated, deployed or dropped is **verified at source before it is repeated** (Rule 18).
- **c. Under-declaring the lane is the failure mode.** A section skipped that then contradicts the session's work is a **governance breach — named and logged, never quietly absorbed.**

**Step 5 — Registry + clock gate:**
FILE-GOVERNANCE §0 (read in Step 2) is the Bible registry. Before creating ANY new file, run the §0 decision tree — if the content fits an existing canonical/log file, update that file in place. New root .md files are sanctioned ONLY as briefs (SB-XX-NNN-*) or PM-approved side-project folders. Take every date stamp from the system clock (`Get-Date` / `date`), never assumed — on 2026-06-07 two CC sessions were future-dated 06-08/06-09 and contaminated canon.

Only after the recital publishes every file, its version, what was read, and the lane: begin work.

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
