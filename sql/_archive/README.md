# sql/_archive — superseded SQL sediment

**Archived 2026-06-17 by SB-CC-RECONCILE-001 Phase 1.** These files were moved
here (via `git mv`, history preserved) because they are no longer the canonical
source of any live object. They are kept, not deleted — reversible via git history
and the `restore-point-2026-06-17` tag.

A file landed here only if it is one of:
- a **superseded duplicate creator** — its object now has a canonical
  `sql/create_<object>.sql` (the dominant case: the `fix_*`, `phase2c_*`, `p3_2_*`,
  `sb_ap_003_a3`, `sb_ap_004_c_*`, `rpc_focus_area`, `rpc_kpi_dept_counts`,
  `rpc_search_detail`, `deploy_rpc_stock_integrity_report`, old `mv_*`/`v_rate_of_sale`
  copies, etc.);
- a **spent one-off migration / data-fix / diagnostic / verify** that already ran
  and creates no live object (`migrate_*`, `add_*`, `drop_daily_aggregates`,
  `drop_stock_snapshots`, `cleanup_*`, `sb_ean_002_fix*`, `sb_rhy_001_*`,
  `verify_*`, `vacuum_*`, `mobile_auth_setup`, `fresh_start_schema`, the
  `sb_sch_001_step3/step5` migrations, `_SUPERSEDED`);
- the **orphan** engine `create_l2_stock_count_plan.sql` +
  `refresh_l2_stock_count_plan.sql` (dropped — see
  `../drop_l2_stock_count_plan_orphan.sql`).

**Nothing here is run on deploy.** The live schema is reproduced from the active
`sql/create_*.sql` set plus the dedicated canonical files that remained in `sql/`.
Per-object canonical mapping: `Daisy/SB-CC-RECONCILE-001_OBJECT-INVENTORY_2026-06-17.csv`.
