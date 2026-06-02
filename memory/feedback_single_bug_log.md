---
name: feedback_single_bug_log
description: BUG-LOG.md is the one file for all bugs, fixes, and their current state — no separate fix files or new log files
metadata:
  type: feedback
---

All bugs, fixes, findings, and their latest state go into `BUG-LOG.md` in the DIWAAIS root. Do not create separate files like `AUDIT-FULL-CALC-2026-05-29.md`, `SB-CC-FIX-001-VERIFY-results.md`, or any new `-log.md` / `-fixes.md` file.

**Why:** Pieter wants one place to look. Separate files fragment state and create "which file is current?" confusion — exactly what FILE-GOVERNANCE.md was written to prevent.

**How to apply:**
- New bug found → append a row to BUG-LOG.md under the right section
- Bug fixed → update the Status/Fixed date/Commit on that row in place
- Audit or fix brief ships → close the brief (archive it), update BUG-LOG.md rows with commit hashes and fixed dates; do NOT write a separate results file
- Open items table at the bottom of BUG-LOG.md stays current — update it when status changes
