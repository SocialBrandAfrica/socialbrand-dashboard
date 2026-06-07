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

**Step 2 — Read RULE-BOOK:**
`Read("C:\Users\User\Desktop\DIWAAIS\RULE-BOOK.md")`

**Step 3 — Read DB-SCHEMA:**
`Read("C:\Users\User\Desktop\DIWAAIS\DB-SCHEMA.md")`

**Step 4 — Read THE handover file (there is exactly one):**
`Read("C:\Users\User\Desktop\DIWAAIS\HANDOVER-CURRENT.md")`
There are NO dated handover files in root — ever. If you find one, that is a governance breach: absorb its content into HANDOVER-CURRENT.md (your own section) and move the stray to `archive/handovers/`.

**Step 5 — Registry + clock gate:**
Read `C:\Users\User\Desktop\DIWAAIS\FILE-GOVERNANCE.md` §0 (the Bible registry). Before creating ANY new file, run the §0 decision tree — if the content fits an existing canonical/log file, update that file in place. New root .md files are sanctioned ONLY as briefs (SB-XX-NNN-*) or PM-approved side-project folders. Take every date stamp from the system clock (`Get-Date` / `date`), never assumed — on 2026-06-07 two CC sessions were future-dated 06-08/06-09 and contaminated canon.

Only after all five steps: begin work.

Mid-session shortcut: `/autopilot` reloads all browser tool schemas if the session lost them.

---

## Standing references

- `C:\Users\User\Desktop\DIWAAIS\RULE-BOOK.md` — domain vocabulary, time conventions, KPI formulas, GP% rules, mandatory SQL patterns, naming conventions. Authoritative: if a brief contradicts this, update here first, then update the brief.
- `C:\Users\User\Desktop\DIWAAIS\DB-SCHEMA.md` — live schema, RPC function signatures, pending SQL tracker.

---

## Project context

See memory files for full project context:
- `memory/MEMORY.md` — index of all memory files
- THE handover is `C:\Users\User\Desktop\DIWAAIS\HANDOVER-CURRENT.md` — the only live one; read on session start
- No dated handover/session files in `memory/` either — session state belongs in HANDOVER-CURRENT.md; old dated memory handovers are archived in `DIWAAIS\archive\handovers\`

## Key rules

- No Unicode in `.ps1` files — store servers are Windows-1252
- All scripts go in `socialbrand-dashboard/scripts/`; server output to `C:\socialbrand\` on store servers
- Full SQL files: fix the file in `sql/`, reference with path only — never dump full SQL in chat
- ASCII-only commit messages and PowerShell scripts
- Never edit code concurrently with a Cowork Claude — check who owns the file first

## Handover file rules (CORRECTED 2026-06-07 — the old "one file per calendar day" rule here was WRONG and caused duplicate handovers; FILE-GOVERNANCE wins)

There is exactly ONE live handover: `C:\Users\User\Desktop\DIWAAIS\HANDOVER-CURRENT.md`. Both CC and PM write into it, each in their OWN section. Never create `HANDOVER_<date>.md`. Never use `Write` on it — always `Read` then `Edit` your own section (Write silently destroys the other author's content). Update the `Last touched:` line with name + system-clock timestamp on every edit; if it changed since you read, re-read before writing. Snapshots to `archive/handovers/` are made by PM at milestones — not by CC, not daily.
