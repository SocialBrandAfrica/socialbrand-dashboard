---
name: feedback_supabase_incremental_sql
description: Large SQL files time out or fail in Supabase SQL editor — must be run step by step, one STEP block at a time
metadata:
  type: feedback
---

Large SQL deployment files (multi-step, multiple function drops + recreates + MV refresh) time out or fail partway through in the Supabase SQL editor. Do not tell Pieter to paste and run the whole file in one go.

**Why:** Supabase kills long-running queries. A single paste of a 500+ line file that drops functions, recreates them, refreshes a materialized view, and runs a reconcile block is too much for one execution.

**How to apply:** When a SQL deployment file has multiple STEP blocks, break it into one paste per STEP. Present each step as a separate numbered instruction with the exact lines to copy. Tell Pieter which step comes next only after he confirms the previous step passed. Label each block clearly (e.g. "Step 1 of 5 — lines 1–45").

See [[feedback_sql_deployment_workflow]] for the general SQL handoff pattern.
