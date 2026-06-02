---
name: project_sb_ap_004_option_c_decision
description: SB-AP-004 bridge and exclusion decisions -- survives across sessions
metadata:
  type: project
---

## SB-AP-004 Capital Tied exclusion — governing decisions (2026-06-02)

### Bridge decision

The dArtNr-to-daily_snapshots bridge is not available for PLU/scale items (PRODUCTION,
NON_STOCK) via any persistent server table. All candidates exhausted:
- IntellistoX_EAN_Master: PRODUCTION barcodes are NULL
- npos.dewas_PLU_s: npos-space only, no dArtNr
- npos.dewas_PLU_d: table does not exist on this server
- npos.PLU_EAN: EAN<->PLU only, no dArtNr
- product_catalog: sigma_product_code = dArtNr confirmed, but 0 PRODUCTION items in catalog

### Option C (current, 2026-06-02)

Apply funnel's structural classification rules directly to daily_snapshots.dept_name
and sub_dept_name via classify_snapshot_item() and is_fresh_perishable() SQL functions.
Self-contained, fully automated, no manual dependency.
Deployed in: sql/sb_ap_004_c_interim_exclusion.sql (commit e8d6369).
Marked as INTERIM in the Capital Tied tooltip.

### Option B (future)

Replace Option C when the push script migrates from PRSSALE.DAT to dw220sdb SQL.
At that point daily_snapshots is keyed on dArtNr natively and the bridge is trivial.
Restore product_classification JOIN (COALESCE(pc.band,'STOCK') != 'AUTO_EXCLUDE' pattern).
Note in classify_snapshot_item() docstring: "Option B REPLACE" instructions included.

### Dashboard manual-pull rule

The dashboard MUST NEVER depend on Pieter pulling data by hand. Any feed the dashboard
relies on must be automated. PRSSALE.DAT is automated -- safe to rely on as interim feed.
Manual SQL pulls are for building/proving the classifier only. Not a standing dependency.

### Data flow to Replit

Data flows out to Replit only. The Replit order sheet is a specimen for a dedicated
teardown session. Not a dependency of the live dashboard.
