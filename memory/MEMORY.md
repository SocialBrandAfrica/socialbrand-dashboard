# Memory Index

- [Project overview](project_overview.md) — SocialBrand dashboard: Next.js + Supabase, architecture decisions, key data model facts
- [SB-AP-004 Option C decision](project_sb_ap_004_option_c_decision.md) — Bridge investigation closed; Option C (dept/sub-dept exclusion) deployed; Option B (SQL pipeline) planned; dashboard never depends on manual pulls; Replit = teardown specimen
- [SB-AP-005 non-stock flip](project_sb_ap_005_nonstock_flip.md) — Flip Record Stock Qty=No on 1,581 Dela PRODUCTION/NON_STOCK lines via Overview Maintenance. Owners: Sparrie + Mari.
- [Pulse Mini — PARKED](project_pulse_mini.md) — SB-AP-007 standalone demo project. Do not touch unless explicitly called up.
- [Capital tied sanity bounds](feedback_capital_tied_sanity.md) — dEKL is cost/pack (always divide by pack_size). Capital tied 15-60 days cover; rarely exceeds 2x monthly turnover.
- [Single bug log rule](feedback_single_bug_log.md) — BUG-LOG.md is the one file for all bugs, fixes, and current state -- no separate fix/results/audit-output files ever
- [SQL deployment workflow](feedback_sql_deployment_workflow.md) — Never use browser to paste SQL. CC writes the file, Pieter pastes it, returns result text.
- [Supabase incremental SQL](feedback_supabase_incremental_sql.md) — Large SQL files fail/time out in Supabase. Always split multi-STEP files into one paste per STEP.
