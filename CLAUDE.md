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

**Step 2 — THE HARNESS IS A FULL READ (FILE-GOVERNANCE §0 v2.21, 2026-08-19).** Every registered canonical file the session's work can touch is read IN FULL at start. This is the standing rule and it is **never negotiated downward** — Pieter, 2026-07-27: *"this needs to hold accross all documentation. the best harnass i've had is the 10 files so far."* **The registered set has GROWN past the original ten because two carves landed** (§14 → ORDERING-CANON 2026-08-14; RULE-BOOK §2 → PROJECT-LEXICON 2026-08-14), and the carve children are registered canon, not optional extras. The current registered start-load:
```
Read("C:\Users\User\Desktop\Daisy\NORTH_STAR.md")
Read("C:\Users\User\Desktop\Daisy\RULE-BOOK.md")
Read("C:\Users\User\Desktop\Daisy\PROJECT-LEXICON.md")                      # SB-INDEX-023, the ONE home for definitions
Read("C:\Users\User\Desktop\Daisy\CLEANUP-ENGINE-CANON.md")                 # the 21KB spine + its §0 SECTION INDEX
Read("C:\Users\User\Desktop\Daisy\ORDERING-CANON.md")                       # SB-INDEX-018, the ordering law (-LEDGER on demand)
Read("C:\Users\User\Desktop\Daisy\STOCK-TRIAGE-TOOL.md")
Read("C:\Users\User\Desktop\Daisy\SIGMA-CLEANUP-WORKFLOW.md")
Read("C:\Users\User\Desktop\Daisy\DB-SCHEMA.md")
Read("C:\Users\User\Desktop\Daisy\FILE-GOVERNANCE.md")
Read("C:\Users\User\Desktop\Daisy\HANDOVER-CURRENT.md")
Read("C:\Users\User\Desktop\Daisy\SB-VIS-001_Product_Vision_and_Philosophy.md")
Read("C:\Users\User\Desktop\Daisy\SB-PRIORITY-FRAMEWORK-001.md")
```
plus the **`ENGINE-CANON-*` children your declared lane touches**, off the CLEANUP-ENGINE-CANON `## 0. SECTION INDEX` — `ENGINE-CANON-CLASSIFICATION` (§1-§11) · `ENGINE-CANON-CAPITAL-AND-CREDITORS` (§12) · `ENGINE-CANON-COUNT-LAW` (§15) · `ENGINE-CANON-CALENDAR` (§16) · `ENGINE-CANON-IDENTITY` (§17) — plus **PIETERSTYLE.md and the `socialbrand-style` skill** every session. The `-LINEAGE` / `-LEDGER` companions are REFERENCE class: read ON DEMAND, never at start, never counted in the byte budget. Memory is a pointer list, never a substitute for a file. **SB-VIS-001 is the `.md`** — converted from `.docx` 2026-07-27 night on Pieter's ruling, content unchanged, and the `.docx` plus its `.pdf` render are archived to `archive/evidence/`. Do not reach for either: they are no longer in root and the `.pdf` never rendered reliably anyway.

**The load is kept readable by capping the FILES, never by reading less (§0g THE DOCUMENT CEILING).** A file grown past 60,000 bytes is the defect; the fix is to split it and move its history to a `<NAME>-LINEAGE.md`, never to skim it. A document that cannot be read in full has stopped being canon and become an archive with a canonical name.

**§0g THE SPLIT AXIS — a split cuts on SUBJECT, never on version.** "Its own section boundaries" means subject boundaries. Where a section's internal structure is chronological (dated addendum versions layered v1..vN), those versions are HISTORY wearing law's numbering, and splitting on them scatters one subject across many fragments — measured on §14: 16 blocks, the promo rules alone spread across v7, v11, v14 and v15, so a lane would still read almost everything. Children are cut by SUBJECT and numbered `<parent>.1, <parent>.2 …`, each carrying the currently-true rules for one subject; superseded version blocks go to the LINEAGE file in version order. Two conditions make the carve auditable: **(a) a version→destination MAP rides with the split**, every source block landing in exactly one child or the LINEAGE file; **(b) CITATION CONTINUITY** — every existing "§14 vN item k" pointer in memory, briefs and BUG-LOG must still resolve, so each child's header lists the v-blocks it absorbed and the LINEAGE file keeps the v-numbers as anchors.

**§0g THE BYTE REPORT — every recital states the measured start-load total against the budget, from the filesystem, never estimated.** The report counts **the on-disk size in bytes of exactly the files the start gate names** — the registered start-load above, plus the `ENGINE-CANON-*` children the lane loads, plus PIETERSTYLE plus the style skill. Nothing else: not LINEAGE/LEDGER companions, not extracted text, not a lane's declined files. **Stated in bytes. KB means 1000, not 1024** — a 1024 divisor understates a 60 KB ceiling by 5%. **The skill counts wherever it lives; a registered file counts because the session carries it, not because of which folder it sits in. SB-VIS-001 counts ONCE, as the registered `.md`.** Measured **2026-08-27 09:51 SAST** on the full Bloom/ordering lane (19 files, all five ENGINE-CANON children loaded, `stat -c %s`): **879,809 bytes against 300,000 — 2.93×.** (Prior reading 2026-08-19 20:39: 765,340 b. R28 lineage: that figure is `retired_on` 2026-08-27, `superseded_by` this line. **It was 114,469 bytes light by the time it was quoted, and this line has now been wrong once — re-measure it, never carry it forward.**)

**THE INTERIM — in force ONLY while a start-load file breaches §0g. A declared debt with an owner, not the new normal.** Breaching as at **2026-08-27 09:51 SAST, measured**: **DB-SCHEMA 232,852 · ORDERING-CANON 90,275 · RULE-BOOK 88,955 · FILE-GOVERNANCE 84,066 bytes** against 60,000. (R28 lineage — the 2026-08-19 reading `DB-SCHEMA 208,439 · FILE-GOVERNANCE 69,926 · RULE-BOOK 69,590 · ORDERING-CANON 63,082` is `retired_on` 2026-08-27, `superseded_by` this line; **all four were stale, every one of them low, and the order of the list was wrong too — ORDERING-CANON is now the second-largest breach, not the smallest.** A transcribed measurement has nothing checking it: this is the DB-SCHEMA environment-facts defect (ENG-119) wearing a byte count.) **What changed since the 2026-07-28 list this file used to carry, all verified at source:** CLEANUP-ENGINE-CANON is **CLEARED** (246,345 → 21,079, the §12/§14/§15/§16/§17 subject carves shipped 2026-08-14) · **HANDOVER-CURRENT is CLEARED** (63,808 → 59,120, sixth rotation 2026-08-16 plus the §0g inflow control) · **FILE-GOVERNANCE and ORDERING-CANON are NEW breaches** the old list never named · DB-SCHEMA has grown, not shrunk, and is the biggest remaining lever (`SB-AUD-DOC-003`, PM's). HANDOVER-CURRENT keeps its own standing rule on top of §0g: it is meant to be read in full every session, so when it grows past a clean one-pass read it is snapshotted to `archive/handovers/` and trimmed back to open items — nothing excluded, only moved. While a breach holds, for a CC build-lane session:
- **Read in full:** HANDOVER-CURRENT · RULE-BOOK · FILE-GOVERNANCE · NORTH_STAR · SB-PRIORITY-FRAMEWORK-001 · SB-VIS-001 · PIETERSTYLE + the style skill · **DB-SCHEMA (CC's full read in the build lane)** · STOCK-TRIAGE-TOOL and SIGMA-CLEANUP-WORKFLOW **when the lane touches cleanup**.
- **CLEANUP-ENGINE-CANON: read the sections your DECLARED LANE touches, in full, off its own `## 0. SECTION INDEX`** (at the top of the file — read the index, never a remembered map).
- **Declare the lane WIDE rather than narrow.** If the lane changes mid-session, load the new lane's sections *before* working in it.

There are NO dated handover files in root — ever. If you find one, that is a governance breach: absorb its content into HANDOVER-CURRENT.md (your own section) and move the stray to `archive/handovers/`.

**§0h CANON IS WRITTEN FOR STORE #6 — the zero-context test.** Every sentence of canon must hold, unchanged, for a new store read with zero context. If a sentence needs OUR stores, OUR account or THIS month to be true, it is not canon. Four of its five points bind CC's build work directly:

- **SEED, UNDERIVED.** A store-specific or fitted constant lives in DEMO_CALIBRATION config, and canon names the key plus the rule for deriving it. **Where no derivation exists — the value was chosen, not derived — the key is stamped `SEED, UNDERIVED`, the seed value stays visible in config, and the derivation is logged as owed work.** A key with neither a derivation nor a SEED stamp is a hole store #6 inherits. Worked contrast: `regime_divergence_max` 2.0 is derived (group p95, n=5,194) and passes on one line; `corrector_min_observable_share` 0.5 and `corrected_ros_cap_multiple` 2.0 are seeds and say so.
- **THE CONFIG-KEY GATE.** The carve of a value a platform object CONSUMES is complete only when **the config key it reads EXISTS AND IS POPULATED**. The value moves, it is never merely deleted (R30). Strip the prose with no key and the consumer silently reverts while canon claims the general rule is live.
- **THE EVIDENCE CLASS TRAVELS VERBATIM.** DEDUCTIVE, CONTROLLED with its n and base rate, SINGLE-OBSERVATION, **or a RULING — and a ruling whose base rate is unstatable keeps that fact and its reason in the line.** Compression that lets a ruling read as a measured law is the exact failure R28 §5 exists to stop.
- **THE CALIBRATION SET.** Everything true of OUR five stores rather than of the platform (store/server registry, format groups, region and community-rhythm data, worked examples, validation runs, run records) belongs in the root **`Calibration/`** folder. Canon points, never contains; values an object consumes still live in DB config. **The deletion test:** with `Calibration/` absent, every canonical file must still read true, complete and buildable-from for a stranger's store. **The safety rule: no carve outside the audit — test-group material splits ONLY through SB-AUD-DOC-001**, per-file, one file per fresh seat, classifying every section GENERAL / TEST-GROUP / STATE / HISTORY with a destination and a dependent check per carve. Thorough beats fast here, by Pieter's explicit instruction.

**Step 3 — RECITAL GATE (mandatory). It now PUBLISHES what was read, not a bare tick.** Before touching ANY file, running ANY command, or starting ANY task, output **one line per file: its name, its version, and what was read — either FULL or the sections named.** State **the lane on its own line**. Name **every section not read and the file that forced it**. **Carry the §0g byte report — measured total in bytes against 300,000, and every breaching file with its own byte count.** A bare ✓ is no longer a recital, and a ✓ over a partial read is the hollow start wearing new clothes. A context summary or "I know this already" still fails the gate. (Gate added 2026-06-17 after a hollow start nearly shipped — Pieter: "I do NOT want to remind you OR Claude Code again.")

**Step 4 — THE THREE TEETH. They are what pays for any read smaller than everything.**
- **a. No canon rule is used from memory of a past read.** If the work needs a rule the lane did not load, **read that section first, then use it.** "I recall §14 says" is a breach, the same class as a hollow start.
- **b. The live database outranks every document on STATE.** Documents hold truth and law; what is built, populated, deployed or dropped is **verified at source before it is repeated** (Rule 18).
- **c. Under-declaring the lane is the failure mode.** A section skipped that then contradicts the session's work is a **governance breach — named and logged, never quietly absorbed.**

**Step 5 — Registry + clock gate:**
FILE-GOVERNANCE §0 (read in Step 2) is the Bible registry. Before creating ANY new file, run the §0 decision tree — if the content fits an existing canonical/log file, update that file in place. New root .md files are sanctioned ONLY as briefs (SB-XX-NNN-*) or PM-approved side-project folders. Take every date stamp from the system clock (`Get-Date` / `date`), never assumed — on 2026-06-07 two CC sessions were future-dated 06-08/06-09 and contaminated canon.

**And take it FRESH, at the moment you write it — a reading is not a fact about later.** A stamp taken at session start and quoted hours on is the same defect wearing a verified clock: on 2026-07-27 two config keys were stamped a day early because a session crossed midnight on a start-of-session reading, and the recital that same night reported a time an hour stale for the same reason. **Long sessions drift past their own clock reading.** Before any `effective_from`, any ageing anchor, any promo window or any handover timestamp, re-read the clock and cross-check it — local, UTC and DB `now()` should agree on the offset. If they disagree, the machine is wrong and nothing gets stamped until it is settled (canon §17, the 07-23/07-26 contamination).

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
| **PM** | Cowork | Product decisions, briefs, canon (Bible updates), R22 reconcile, approvals, the cross-app audit (R33) |
| **CC** | Claude Code (you) | All code commits, SQL, engine logic, performance — the heavy lifting. **Every file in THIS repo is CC's, including this CLAUDE.md, `DB-SCHEMA.md`, `DEPLOY-LOG.md` and everything under `sql/`** (§0d; re-proved on CC's catch 2026-08-19 after PM had listed two repo files as PM work) |
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
