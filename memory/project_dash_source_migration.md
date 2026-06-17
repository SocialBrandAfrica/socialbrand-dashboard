---
name: project_dash_source_migration
description: THE dashboard thread — migrate every number off PRSSALE daily_snapshots onto Sigma-native source (SB-INDEX-005). Phase 1 done, Phase 2 outstanding.
metadata:
  type: project
---

## The dashboard job is a SOURCE migration (SB-INDEX-005 / PRSSALE-TO-SQL-MIGRATION.md)

The whole dashboard currently fetches from `daily_snapshots`, which is the **PRSSALE** feed. PRSSALE is approximate (≈0.3-1.3% drift) AND structurally holed on any missed store EOD (FEED-001: 10116 lost its entire 2026-05-29 day, ~R383k, never healed). The job is to serve the **same information from the reliable Sigma-native source** already loaded in Supabase. Nothing else changes — not Layer 1/Layer 2 mechanics, not the page, not the files, not the direction. Only where the reads point.

**Field map (where each PRSSALE field comes from in Sigma):** sales/qty/cost → `sigma_sales` (DBUmBA, cPerKz=T cVorKz=1; cost_value=dEKUmsatz, 100% populated); period rollups → SUM sigma_sales; soh → `sigma_lifecycle`/`l2_soh_daily` (dewas_PLU_s native, never PLU_s); sell_price/unit_cost → `sigma_articles` (DBARTS/EASYDB); vat → per-item siMWST (fixes flat-1.15); dept/subdept → `sigma_departments`/`sigma_subdepts`; ean → `sigma_ean_master`; description → sigma_articles; last_sale → EASYDB; join key = dArtNr.

## Status

- **Phase 1 — DONE + LIVE** (commit 7a98200 + Option B bffe0b3): `l2_kpi_daily` reads `sigma_sales`, zero `daily_snapshots` reference, sales exact to the rand, real GP% from cost_value. Proved the swap pattern at the L2 level.
- **Phase 2 — OUTSTANDING, needs the PM brief.** Migrate `v_kpi_by_date` (the live dashboard's PRIMARY KPI source: Total Sales, GP%, Slow Movers, Capital Tied) plus the panel RPCs (`rpc_dept_summary`, `rpc_top20`, `rpc_lost_sales_timeline`, `rpc_focus_chart`) and matviews (`mv_rate_of_sale`, `mv_sparkline_14d`) off `daily_snapshots` onto Sigma-native. HIGH blast radius (live prod) — own regression + sequencing. Phase 1 de-risked it by proving the pattern.

## Do not conflate

`dash-wire-001` (Capital Tied → `l2_classification`, R21M→R10M) is the **cleanup/purification** thread, a DIFFERENT job. The source migration is about reliable source (Sigma vs PRSSALE), not purified capital. Both PM and CC drifted by treating the one-KPI cleanup as the dashboard task. The dashboard task is the whole-dashboard SOURCE migration above.

**Why:** PRSSALE is unreliable; Sigma is exact to the ledger and already loaded. **How to apply:** when asked about "the dashboard," default to the SB-INDEX-005 source migration, Phase 2, not a single KPI. Schema = DB-SCHEMA.md; server map = SIGMA-SERVER-SCHEMA-MAP.md; source-of-truth = SOURCE-OF-TRUTH-MAP.md.
