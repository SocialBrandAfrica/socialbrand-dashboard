# Memory Index

- [2026-06-03 session handover — READ FIRST next session](C:/Users/User/Desktop/DIWAAIS/HANDOVER_2026-06-03.md) — Patch 1 deployed (R606k excluded, R8.33M Capital Tied). Phantom R7.9M confirmed absent from PRSSALE.DAT (Sigma TAC export gap, not a push script issue). SB-STRATEGY-001 written -- PM must answer 6 questions before further architecture work. SEL-001 P3 still pending.
- [SB-STRATEGY-001 data architecture](C:/Users/User/Desktop/DIWAAIS/SB-STRATEGY-001-data-architecture-vision.md) — Master PM brief: SQL-direct pipeline vision, three-layer schema design, migration phases, DoD, 6 blocking PM questions.
- [SB-AP-004 Option C decision](project_sb_ap_004_option_c_decision.md) — Bridge investigation closed; Option C (dept/sub-dept exclusion) deployed; Option B (SQL pipeline) planned; dashboard never depends on manual pulls; Replit = teardown specimen
- [SB-AP-005 non-stock flip](project_sb_ap_005_nonstock_flip.md) — Flip Record Stock Qty=No on 1,581 Dela PRODUCTION/NON_STOCK lines via Overview Maintenance. Owners: Sparrie + Mari. 1,220 ready | 70 TLX | 291 manual. Due date carry-over -- reset with Sparrie/Mari. TLX_Converter.html is barcode-keyed (not Product Code).
- [Pulse Mini — PARKED](project_pulse_mini.md) — SB-AP-007 standalone demo project. Do not touch unless explicitly called up. Files: public/StockFlow-DevCorner-Demo.html + api/dev-corner/lines. Commits tagged SB-AP-007/Pulse Mini are separate from main release train.

- [Project overview](project_overview.md) — SocialBrand dashboard: Next.js + Supabase, architecture decisions, key data model facts
- [2026-06-01 handover](handover_2026-06-01.md) — SB-AP-003 partial deploy; EAN mismatch (DIWAAIS2 PLU ≠ PRSSALE PLU for scale items); ghost stock R7.9M confirmed; PM decision pending on classifier fix path
- [Single bug log rule](feedback_single_bug_log.md) — BUG-LOG.md is the one file for all bugs, fixes, and current state — no separate fix/results/audit-output files ever
- [2026-05-30 session handover](handover_2026-05-30.md) — Audit SB-CC-AUDIT-001, verification SB-CC-FIX-001-VERIFY, hotfix diagnosis (rpc_top20 42702 + Sales Trend 90-date timeout). Gate checks passed. Batch A+B verified, not yet committed.
- [Capital tied sanity bounds](feedback_capital_tied_sanity.md) — dEKL is cost/pack (always divide by pack_size). Capital tied should be 15–60 days cover; rarely exceeds 2× monthly turnover.
- [SQL deployment workflow](feedback_sql_deployment_workflow.md) — Never use browser to paste SQL. CC writes the file, Pieter pastes it, returns result text. No screenshots when Pieter is present — ask for text/JSON.
- [Supabase incremental SQL](feedback_supabase_incremental_sql.md) — Large SQL files fail/time out in Supabase. Always split multi-STEP files into one paste per STEP. Give next step only after previous one confirms clean.
- [2026-05-30 held commits + pending SQL](project_2026-05-30-held-commits-pending-sql.md) — 4 commits held (PUSH-001, SEL-001 P1/P2/P4, tooltip/trend). SEL-001 all frontend done. Capital SQL ON HOLD (Batch C).
