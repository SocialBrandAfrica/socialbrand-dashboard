# R33 cross-app audit: orderable stock against countable stock

**Ordered by:** PM. "Check the similarities between the orderable stock and countable stock. Are they duplicating engine work that could have been connected."
**Compared:** the ordering engine (Bloom recipe, pantry facts, desks, cache, ledger) and the count app (SB-CC-STOCKTAKE-001, ENG-241, live at dashboard.socialbrand.africa/stocktake).
**Written:** 14-10-2026 16:3x SAST, CC prep seat. System clock read 16:26 SAST at the last check.
**Status:** DRAFT for PM. Read-only. No database call was made. No ruling was taken. Every build named here is a proposal for PM to rule on.

**Scoped start-read, flagged.** I skipped the 25-file CLAUDE.md recital. This is the PM-approved scoped start-read of 20-07-2026 for one focused, read-only task. Section 9 lists what I read in full, what I read in part, and what I did not read. A reader should treat any claim about a file I did not read as unchecked.

---

## 1. The answer

**Partly. The count app connects to the engine where identity and stock facts are concerned. It does not connect where the engine already knows which lines are in doubt. It also copied six rules the engine holds in one place.**

Connected well (SAME DATA, one object):

- Identity. Both read `v_item_ean`, `v_scan_ref_decoded` and `l2_export_key`.
- Stock and cost. Both read `l2_stock_position`.
- The received-products fact. The supplier list reads `l2_received_placement`, the ordering desk fact of BLOOM-035 E1. That was the right move.
- Dates and config. Both use `store_local_today` and `forge_config`.
- The toolkit scoreboard already reads both worlds (`sql/eng240_stocktake_pool_single_home.sql:91-101, 108, 117`).

Duplicated or not connected:

1. **Which lines to count.** Two draw engines exist. The Forge ordering-impact count list still sits in the repo (`sql/create_rpc_forge_count_list.sql:48-181`). The app has its own (`sql/eng241_stocktake_count_app_core.sql:197-280`). The app draw reads none of the engine's doubt facts. No `eng24*` file reads `l2_range_state`, `l2_population_verdict`, `l2_stock_band` or `l2_bloom_ros_pantry` for the draw (checked by grep, 14-10-2026).
2. **Latest GRV supplier.** Ordering holds two copies (the placement fact and the population verdict). The count app reads one of them.
3. **Counted and sold in 91 days.** The counted test has four readers and two module filters. The sold test has three copies and three date anchors.
4. **The DC rest day.** The count app finds the DC calendar row by a text match on the route key. The ordering engine retired that habit in `rpc_bloom_desks` and has since added a DC fresh row that the match can pick up.
5. **The run log and compliance.** The app wrote its own ledger. `forge_count_run` was built to be the one ledger. Two compliance figures now reach readers.
6. **The exclusion set.** The count draw drops only `COST_ERROR`. The engine's range state drops four buckets and the count law drops deposits.

One test the count app owes by 16-10-2026 already exists in the engine (the weighed-line cost scale, `unit_incommensurable`). That is connection 1 below.

Two things I could not settle without the database: whether the DC fresh row is live and newer than the ambient row (L1), and how many World 2, deposit and non-stock lines sit in today's draw (L4).

### Scale, so nobody compares unlike things

All figures are CITED from other seats. They differ in date and definition. Do not subtract one from another.

| Population | Figure | Source and scope |
|---|---|---|
| Count pool at 10116 | pool 9,500, buy-and-sell range 9,238, uncounted 5,930 | `BUG-LOG.md:3050`, read 13-10-2026 |
| Mission critical (in the order pantry) | 6,649 · 738 · 4,449 · 592 · 593 at 10116 · 21355 · 80175 · 80176 · 80579 | `ENGINE-CANON-COUNT-LAW.md:64`, PM 23-09-2026 |
| Products received in 182 days, with a desk or a reason | 17,246 across five stores | `BUG-LOG.md:3125`, 14-10-2026 |
| Verdict rows (linked products) | 36,793 across five stores | `sql/create_l2_population_verdict.sql:21-22`, 10-09-2026 |
| World 2 products | 843, of which 563 received in 182 days | `BUG-LOG.md:3123`, 14-10-2026 |

---

## 2. How to read the tables

**Verdict labels**

- **SAME LOGIC (duplicated).** Two objects run the same rule.
- **SAME DATA (connected).** Two apps read one shared object.
- **DIFFERENT BY DESIGN.** The two questions differ, so the answers should differ.

**Evidence labels**

- **DEDUCTIVE.** Read from the code. True by construction.
- **CITED.** A measurement another seat made. Source and date named. I did not re-run it.
- **UNPROVEN.** Needs a live read. The read is named (L1 to L14, section 8).

**Recommendation labels.** CONNECT (name the shared object), LEAVE, DEFER. **R22** means: do the existing desks stay unchanged. **Perf** means: cost to the nightly chain and to the app reads. Where I say "not measured" I mean it.

File references are repo paths from `socialbrand-dashboard/`, except canon files in `Daisy/`. `core.sql` is short for `sql/eng241_stocktake_count_app_core.sql`. `recipe` is short for `sql/create_rpc_bloom_order_recipe.sql`. `e1` is `sql/bloom035_e1_received_placement.sql`. `verdict` is `sql/create_refresh_l2_population_verdict.sql`. `pool_v2` is `sql/eng241_stocktake_pool_v2.sql`. `draw_pantry` is `sql/eng241_stocktake_draw_pantry.sql`. `normalised` is `sql/eng241_stocktake_normalised.sql`.

---

## 3. The table, axis by axis

### (a) Which products are in scope

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| a1 Class gate | Class NORMAL through the KVI profile's own pool (`sql/create_l2_range_state.sql:58-59`, `sql/create_l2_stock_band.sql:231-236`, `recipe:528-575`) | Class NORMAL in `v_stocktake_pool` (`pool_v2:121-126`) | **SAME DATA.** Both read `l2_stock_position.class` (`sql/create_l2_stock_position.sql:187`). LEAVE. R22 none. Perf none. |
| a2 World 2 | Canon says no World 2 line rides any pool, screen or count stratum (`ORDERING-CANON.md:40`). The label sits in `l2_world_assignment` (`sql/create_supplier_desks_from_receipts.sql:46-70`, rule `95-134`). Only the desk builders and the placement fact read it (4 sql files, grep 14-10-2026). | Class NORMAL alone (`core.sql:253`, `pool_v2:126`). The brief says World 2 is out "through the engine's own class" (brief section 1, line 47). ENG-020 add.1 says the in-only signal is not in the class stack (`BUG-LOG.md:3159`). | **SAME GAP.** Neither the recipe pool nor the count draw reads the label. CITED: 843 World 2 products, 563 received in 182 days (`BUG-LOG.md:3123`). Size in the draw is UNPROVEN (L4). CONNECT at draw level after L4. R22 none for desks. A pool-level change moves the `count_coverage_91d` denominator, so go draw level first. Perf one PK join. |
| a3 Excluded buckets | `l2_range_state` EXCLUDED means bucket NON_STOCK, COST_ERROR, SOURCE_FIX or DEPOSIT (`sql/create_l2_range_state.sql:139`). The recipe drops EXCLUDED (`recipe:564`). | The draw drops `COST_ERROR` only (`core.sql:253`). Count law: deposits leave every stratum (`ENGINE-CANON-COUNT-LAW.md:32`). The old Forge list dropped DEPOSIT (`sql/create_rpc_forge_count_list.sql:100`). | **SAME LOGIC.** The count copy is narrower. Class NORMAL lines with a deposit or accounting description carry those buckets (`sql/create_l2_classification.sql:321-330, 353-363`). UNPROVEN how many reach the draw (L4). CONNECT: the draw reads `l2_range_state` EXCLUDED. Needs ruling Q3. R22 none for desks. Perf one PK join. |
| a4 Active link | The pool is the active links of the desk's supplier (`recipe:493-504`) | No link needed (`pool_v2:126`) | **DIFFERENT BY DESIGN.** A count needs no price agreement. CITED: 380 received products had no active link on 14-10-2026 (`BUG-LOG.md:3133`). LEAVE. |
| a5 Zero stock | A zero line enters only if it passes the life gate and is HERO or CORE (`ORDERING-CANON.md:96`, F2 `224-226`) | A zero-stock line that sold or was received in 91 days stays in the pool and a count of 0 confirms it (`pool_v2:126`, brief section 7) | **DIFFERENT BY DESIGN.** LEAVE. |
| a6 Non-stock that sells | Placement codes NON_STOCK_SOLD and EXPENSE_NOT_STOCK (`e1:141-142`). CITED 325 and 244 products on 14-10-2026 (`BUG-LOG.md:3134-3135`). | Class NORMAL keeps them out | **SAME DATA** (class). LEAVE. |

### (b) How a product is assigned to a supplier or desk

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| b1 Who delivered it | **Two copies.** Placement: newest R or W receipt, any module, window to the store watermark (`e1:85, 91-101`). Verdict: module DIWAREPR only, whole history for the last delivery, window from store-local today (`verdict:95, 116-125, 227`). The recipe pool is the active links plus the verdict (`recipe:493-504, 565-567`). | Reads the placement copy: `latest_grv_supplier_nr` (`core.sql:410-414, 493-494, 511-512, 1022-1029`) | **SAME LOGIC twice inside ordering, read once by count.** The count read matches R7 "latest GRV" (`sql/create_supplier_desks_from_receipts.sql:3-4`). LEAVE the count read. DEFER merging the two ordering copies. Gap size UNPROVEN (L6, L7). R22 high if merged, because it moves the E1 rows in the order cache. |
| b2 Supplier or desk | The unit is the desk. Placement sets `desk_route_key` (`e1:119-122`). The label lives in `supplier_calendar.display_label` (`sql/create_rpc_bloom_desks.sql:98-108`). | The unit is the supplier account (`core.sql:1025-1029`). DC fresh is a department split of one DC account (`sql/bloom035_1b_dc_fresh_phase1.sql:79-81`), so a DC list cannot be cut to the fresh desk. | **DIFFERENT BY DESIGN today.** The data to cut by desk is already on the row. CONNECT as a second filter after ruling Q4. R22 none. Perf none. |
| b3 Catch-all accounts | `bloom_catchall_account` names ALGEMEEN, VARIOUS SINGLES and LOCAL GENERAL as not suppliers (`sql/bloom035_item1_v11_cadence_catchall.sql:37-51`). They get the desk DIRECT_CATCHALL (`sql/bloom035_eng202_catchall_desk.sql:98-103`). | The supplier list shows them as suppliers (`core.sql:1025`) | **SAME DATA, unused.** CONNECT the label only. R22 none. |
| b4 Reach | The verdict gives every linked line a desk, even a never-received one (HISTORY_RECEIPT, SUPP_CD, NO_RECEIPT, `sql/eng183a_desk_split_verdict.sql:21`, `verdict:265-284`) | Placement covers only products received in the last 182 days (`e1:94`, seed 182 at `sql/eng183a_desk_split_verdict.sql:17`). A pool line not received in 182 days has no supplier list. | **DIFFERENT BY DESIGN, with a gap.** Size UNPROVEN (L5). DEFER. Option for Q4: fall back to `l2_population_verdict.route_key`. |
| b5 Sheet split | One sheet per desk | Tabs by department, even for a supplier list (`src/lib/stocktake/sheet.js:149-173, 201-202`) | **DIFFERENT BY DESIGN.** LEAVE. |

### (c) Stock position and SOH, source and date

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| c1 Source and date | `v_l2_soh_effective` at the latest `l2_soh_daily` snapshot, corrected when the snapshot predates the till (`recipe:424, 505`, `sql/create_v_l2_soh_effective.sql:52-93`) | `l2_stock_position.soh`, the nightly lifecycle stock (`sql/create_l2_stock_position.sql:122, 281-284`), refreshed in the chain (`sql/create_refresh_l2_pipeline.sql:68`), frozen into the draw at 03:30 UTC (`draw_pantry:151-154`) and into the line (`core.sql:495-501`). `system_now` reads the same matview (`core.sql:567-576`), so it is not live. | **SAME QUESTION, TWO SOURCES.** Not measured (L8). DEFER until L8. Cheap part now: stamp the SOH data date on the cycle. `core.sql:461` already stores `draw_refreshed_at`. Caution: `create_l2_stock_position.sql` in the repo is the v1.0 file of 09-06-2026 with no live hash, so I treat it as unchecked against live. |
| c2 Cost | The chosen link's pack cost, with the SPAR DC supplier 1339 first, then the newest cost date (`recipe:503`, `verdict:211-215`) | `l2_stock_position.unit_cost`: newest valid link, smallest pack (`sql/create_l2_stock_position.sql:71-87`). It prices the rand rank and the variance value (`core.sql:230, 267-268, 684`). | **SAME TABLE, TWO PICKS.** Size UNPROVEN (L13). DEFER. Ruling Q8. |
| c3 Negative stock | Treated as zero (`ORDERING-CANON.md:116`) | Kept, and drawn first (`core.sql:261`) | **DIFFERENT BY DESIGN.** LEAVE. |

### (d) Classification and ranging states: NORMAL, HERO, KVI, SLOW, NEW

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| d1 Range state | HERO, CORE, SLOW, MARKDOWN, DERANGE, VERIFY, EXCLUDED (`sql/create_l2_range_state.sql:137-145`), read by the recipe (`recipe:527, 535`). Canon F1: the order, the worklists and Forge read it (`ORDERING-CANON.md:218`). The old Forge list did (`sql/create_rpc_forge_count_list.sql:87-88, 105`). | Reads none. The app draw uses four groups of its own: NEGATIVE, INACTIVE, SUSPECT, ZERO (`core.sql:261-262`). | **DIFFERENT BY DESIGN** by Pieter's 13-10 16:24 ruling (brief lines 21-27). **But canon expects the read.** CONNECT as an annotation. See connection 3. |
| d2 KVI and tier | `kvi_band` sets safety days (`recipe:643`). Old Forge tier 1 used it. | Unused | LEAVE until ruling Q2. |
| d3 NEW | Verdict NEW_RANGE: never sold, first receipt within 120 days (`verdict:292-294`) | A new line with stock and no till sale lands in INACTIVE with the story "nothing has sold in 28 days" (`core.sql:261-262, 504`) | **DIFFERENT BY DESIGN.** Pieter's inactive rule has no exemption. Size UNPROVEN (L11b). Ruling Q7. |
| d4 Doubt | `band_blocked` = bucket COUNT or AMBIGUOUS (`sql/create_l2_stock_band.sql:339`). VERIFY (`create_l2_range_state.sql:141`). PHANTOM_CLAIMS_STOCK (`verdict:317-318`). COUNT_FIRST rides the order row (`ORDERING-CANON.md:116`, `src/app/bloom/page.jsx:1387, 3295`). | SUSPECT means every other line with stock, ranked by rand value. It carries no signal of suspicion (`core.sql:261-262, 267-268`). The classification's own count verdict `artifact = 'stockflow'` (`sql/create_l2_classification.sql:429`) is not read. | **SAME DATA, unused.** CONNECT as an annotation. Connection 3. |
| d5 Counted state | LEAVE_COUNTED and PHANTOM_ZERO read `counted_91` as any I movement (`create_l2_classification.sql:222, 377, 380`) | DIWAINV only (`pool_v2:68-74`) | **SAME LOGIC, different module filter.** See f1. |
| d6 Normalised | No count-based input. Canon B8 says distrust is "earned per line" (`ORDERING-CANON.md:116`). | `l2_normalised_line` and `l2_normalised_count` (`normalised:87-158`). The tolerance is a seed (`pool_v2:145-146`). | Nothing to compare yet. DEFER. Revisit when a quarter of count history exists. |

### (e) Delivery calendar and cadence, against the count calendar and the draw refresh

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| e1 DC rest day | Desks come from calendar rows. `is_dc` comes from config presence, never from the route key text (`sql/create_rpc_bloom_desks.sql:35-39, 94-124`). The calendar key is (store, route) (`sql/create_supplier_calendar.sql:22`). ENG-204 writes a DC_FRESH row stamped `effective_from` today (`sql/bloom035_1b_dc_fresh_phase1.sql:107-110`). | The rest day is the newest calendar row whose key starts with DC (`core.sql:438-441`, `976`). The text was copied from the Composer's issue job (`sql/create_refresh_forge_daily_issue.sql:48-50, 90-91`). The ruling was for the DC **ambient** day (brief line 108). | **SAME LOGIC, duplicated, and the ordering engine moved under it.** DEDUCTIVE on the mechanism. Live state UNPROVEN (L1). CONNECT: read `rpc_bloom_desks` (`is_dc`, `delivery_dows`) and ask PM which DC desks count (Q1). R22 none for desks. It changes a banner and the `non_count_day` flag. Perf none. |
| e2 Cadence and cut-off | `cycle_weeks`, median drop gap, order cut-off (`ORDERING-CANON.md` A4 to A5) | None. A count is a store-day rotation. | **DIFFERENT BY DESIGN.** LEAVE. |
| e3 Nightly order | Pipeline 20:15 UTC, 22 to 24 min on 18 nights (CITED `BUG-LOG.md:3231`). Desks and placement 21:00 UTC (CITED `BUG-LOG.md:3121`). Order cache 23:30 UTC (`e1:23-24`). | Draw 03:30 UTC (`draw_pantry:199-202`). It does not check that the chain finished. ENG-236 option H is applied and its full run is not proven (CITED `BUG-LOG.md:3225`). | **DIFFERENT BY DESIGN, with a gap.** The app shows when the draw was stocked. It does not show the data date the draw was stocked from. CONNECT small: stamp the data date. L2 and L3 measure. |
| e4 Windows | `desk_receipt_window_days` is config (182). The 91-day sold test in placement is a literal (`e1:112`). | The 91 is a literal in four places (`pool_v2:71, 87, 93, 117`). The compliance window is config (`sql/eng241_stocktake_compliance.sql:65`). | **SAME LOGIC, both literal.** DEFER. A section 0h hole on both sides. |

### (f) Evidence channel: movements I, M, DIWAINV as count evidence

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| f1 What counts as counted | Classification reads any I movement (`sql/create_l2_classification.sql:222`). The stock band flow check re-anchors on any I (`sql/create_l2_stock_band.sql:313`). The Forge evidence view reads DIWAINV, issue day plus 2 (`sql/create_v_forge_count_line_evidence.sql:44-54`). | `l2_last_counted` reads DIWAINV, one row per product (`pool_v2:68-74`). `stocktake_count_days` reads DIWAINV, one per product per day (`core.sql:152-158`). | **SAME LOGIC, four readers, one differs.** CITED: 9 lines are counted only by module DIWAZENT, 4 at 21355 and 5 at 80175 (brief section 7, lines 206-207). DEFER the classification change. It moves LEAVE_COUNTED and PHANTOM_ZERO, so range state and the order pools (R22 high). Measure first (L9). |
| f2 Proof of posting | The Forge evidence view proves a posting against an issued line | `awaiting_posting` is a timer (`core.sql:968-970`). Nothing checks that a finalised line landed as a DIWAINV. The wait is a seed with its derivation owed (`pool_v2:153-154`). | **SAME DATA available.** CONNECT: after the wait, read `stocktake_count_days` against the finalised lines and list the ones not posted. R22 none. Perf: a 14-day window per store. |
| f3 Sales evidence | Recipe and placement read `sigma_sales` T, K1, qty above 0 (`recipe:517-526`, `e1:111-112`). Classification and world assignment read K movements (`create_l2_classification.sql:217`, `create_supplier_desks_from_receipts.sql:99-101`). | `sigma_sales` T, K1, qty above 0 (`core.sql:213-218`, `pool_v2:84-89`) | Two tables for one fact. LEAVE. |

### (g) Capture and upload path, against order submission

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| g1 Persistence | Edits live in the browser. "Submit" locks the screen only. Persistence is BLOOM-015, not built (`src/app/bloom/page.jsx:17-18, 2061, 3305`). | Cycle, line and event tables, RLS on, RPC-only writes (`core.sql:28-117`). Capture (`607-717`). Finalise (`781-825`). | **DIFFERENT BY DESIGN today.** LEAVE. When BLOOM-015 starts, copy the pattern (cycle, line, event, RPC-only writes). Do not share the tables. |
| g2 TLX writer and gate | Built in the browser. Gate is `l2_export_key.export_eligible` through `rpc_bloom_export_eligibility` (`page.jsx:2244-2269`, `sql/create_l2_export_key.sql:91-130`). The test is narrow on purpose (`create_l2_export_key.sql:22-39`). | Built in SQL, md5 stored on the event (`core.sql:855-872`). Gate is stricter: classification REAL, export eligible, both keys equal, 8 or 12 to 14 digits, valid GS1 check digit (`core.sql:257-260`). | **SAME DATA, DIFFERENT BY DESIGN on the gate.** A wrong key in an order drops a line. A wrong key in a count writes a wrong count in Sigma. CITED: 24 REAL lines have two keys that disagree (`BUG-LOG.md:3059`, 13-10-2026). LEAVE the gates. CONNECT the 24 as one Sigma correction list for both apps (L14 recounts). |
| g3 Import key | Header "Product Code" and "Order Qty" (`page.jsx:2343-2347`) | Hidden LineId column (`sheet.js:33`, `345`) | **DIFFERENT BY DESIGN.** LEAVE. |
| g4 Run log and compliance | `forge_count_run` was built as "one ledger for every surface", source forge, stockflow or bloom (`sql/create_forge_count_run.sql:16-21, 44-45`). The weekly report reads it (`src/app/api/forge/weekly-report/route.js:68-71`). | The app wrote its own ledger (`core.sql:28-111`). The toolkit pane reads `rpc_stocktake_compliance` (`src/app/api/stocktake/measures/route.js:31-35`, `public/toolkit.html:393`). | **SAME PURPOSE, TWO LEDGERS, TWO PUBLISHED COMPLIANCE FIGURES** (R33 clause 1, `RULE-BOOK.md:334`). CONNECT after ruling Q5. R22 none for desks. It moves the published adherence figure, so the ENG-187 dependents are warned (`ENGINE-CANON-COUNT-LAW.md:45`). |
| g5 Second draw | `rpc_forge_count_list`, `refresh_forge_daily_issue` and `/api/forge/export-stocktake` are still in the repo (`src/app/api/forge/export-stocktake/route.js:45`). `public/toolkit.html:4-6` says the Composer is retired. The draw pantry header says `forge-daily-issue` still runs at 04:30 UTC (`draw_pantry:17`). | The app draw | **SAME PURPOSE, TWO ENGINES.** Whether job 25 still runs is UNPROVEN (L2, L12). Ruling Q5. |
| g6 Spreadsheet library | `xlsx` (`page.jsx:23`, `src/app/api/forge/export-stocktake/route.js:16`) | `exceljs` (`sheet.js:18`) | Two libraries. DEFER. |

### (h) What the count app recomputes that the engine holds, and the reverse

| Row | Ordering engine | Count app | Verdict and recommendation |
|---|---|---|---|
| h1 Weighed-line cost scale | `l2_bloom_ros_pantry.unit_incommensurable` is true when the article unit is not EA, or is unmapped (`sql/create_l2_bloom_ros_pantry.sql:168, 237-241`) | Owed by 16-10-2026 and not built (`BUG-LOG.md:3059`). CITED: one line, F/L BANANAS LSE, product 3970 at 10116, is R1,918,252 of a R2,008,391 net loss for the week ending 11-10-2026. | **SAME DATA exists.** The count app is about to build a second test. CONNECT. Connection 1. |
| h2 Sold in 28 days | The pantry holds corrected rates (`ros_28d`) | Recomputed from `sigma_sales` inside the compute (`core.sql:213-218`). It is 1.3 s of an 11 to 16 s call (`draw_pantry:4-6`, CITED 13-10-2026). | **DIFFERENT BY DESIGN.** The count test is "any positive sale". The pantry value is a corrected rate. LEAVE. |
| h3 Sold or received in 91 days | `l2_classification` (`create_l2_classification.sql:217-220`), placement (`e1:111-112`) | `l2_count_range` (`pool_v2:81-96`) | **SAME LOGIC, three copies.** Three anchors: store-local today, freshest ledger date, store watermark. DEFER. L10 measures the gap. |
| h4 Identity | `v_item_ean`, `v_scan_ref_decoded` | Same views (`core.sql:219-228`) | **SAME DATA, connected.** LEAVE. |
| h5 Config reader | Inline `forge_config` reads in each function (`verdict:91`) | `stocktake_cfg` (`core.sql:124-134`) | **SAME LOGIC, small.** DEFER. |
| h6 Today's date | `store_local_today` (`verdict:95`) | `store_local_today` (`core.sql:206`) | **SAME DATA.** Placement alone anchors on the watermark (`e1:85`). LEAVE. |
| h7 Toolkit scoreboard | `rpc_forge_integrity` reads the count pool, the order pantry and the KVI profile (`eng240_stocktake_pool_single_home.sql:91-101, 108, 117`) | Same function | **SAME DATA, connected correctly.** LEAVE. |
| h8 List size on the page | n/a | `generateCounts` repeats min(volume, pool) for display (`src/app/stocktake/components/GeneratePanel.jsx:17-32`), mirroring `LIMIT v_n` (`core.sql:487, 514`) | Display only. LEAVE. |

---

## 4. The three most valuable connections, ranked by value over risk

### Rank 1. Use the pantry's unit test for weighed lines, before the toolkit shows shrinkage in rand

- **Why first.** It is cheap, it has a date (16-10-2026), and the figure it protects is large. One weighed line was 95 percent of a R2.0m weekly shrinkage number (`BUG-LOG.md:3059`, CITED).
- **Shared object.** `l2_bloom_ros_pantry.unit_incommensurable`. A second candidate is `sigma_articles.scale_flag` and `plu_flag`, which `l2_stock_position` already carries.
- **Who changes what.** Count side only. `rpc_stocktake_normalised` and the draw's rand rank join the pantry row. A line with the flag true, or no pantry row, has its rand value withheld and its units kept. Ordering changes nothing.
- **R22.** None. No order sheet reads the count tables.
- **Perf.** One PK join in a nightly refresh and in a read RPC. Not measured.
- **Risk to watch.** The flag means "unit is not EA". It may over-flag boxes and cases. L12 sizes that before anyone builds.
- **Ruling needed.** None. CC already owes the test.

### Rank 2. One calendar read for the rest day

- **Shared object.** `rpc_bloom_desks(store)` and its `is_dc` and `delivery_dows` (`sql/create_rpc_bloom_desks.sql:78-125`).
- **Who changes what.** Count: `rpc_stocktake_generate` (`core.sql:438-441`) and `rpc_stocktake_overview` (`core.sql:976`). Forge: `refresh_forge_daily_issue` (`create_refresh_forge_daily_issue.sql:48-50, 90-91`) if it stays. Ordering changes nothing.
- **Why.** The ordering engine now adds DC desks on its own (ENG-204, ENG-202). The count rule should not change when it does. Five SQL lines in the count app and the Composer's issue job read the DC row by text (`grep "LIKE 'DC%'" sql/`, 14-10-2026). `rpc_derive_order_cutoff` holds the same habit inside ordering (`sql/create_rpc_derive_order_cutoff.sql:127-143`). That one is ordering's own to fix.
- **Condition.** If L1 shows the DC fresh row live and newer, this is a live defect at 10116 and 80175. If L1 shows no fresh row, still do it before the fresh desk lands (`ORDERING-CANON.md:39` says those two stores carry a fresh cycle).
- **R22.** None for desks. A banner and the `non_count_day` flag change.
- **Perf.** One function call per generate and per overview. Trivial.
- **Ruling needed.** Q1.

### Rank 3. Read the engine's doubt and mission-critical facts into the draw as an annotation, with the ruled order unchanged

- **Shared objects.** `l2_population_verdict` (`population_state`, `flag_phantom_claims_stock`), `l2_range_state` (VERIFY), `l2_stock_band` (`band_blocked`), and membership of `l2_bloom_ros_pantry` for "mission critical" (`ENGINE-CANON-COUNT-LAW.md:62-64`). The verdict table names Forge as an intended reader (`sql/create_l2_population_verdict.sql:3-6`). Its verified readers are Bloom objects only (`create_l2_population_verdict.sql:26-30`). No count or Forge object reads it today.
- **What.** The stocked draw gains a few columns (a doubt code, a doubt sentence, a mission-critical flag). The generate story appends the engine's own reason. The four groups and their order do not change.
- **Who changes what.** Count: `stocktake_candidates_compute` (`core.sql:197-280`), `l2_stocktake_draw` (`draw_pantry:33-60`), the story text in `rpc_stocktake_generate` (`core.sql:502-506`), and `refresh_l2_stocktake_draw`. Ordering changes nothing.
- **Value.** It closes R33 clause 3 for the verdict. It tells the floor why a line is in doubt. It gives PM the numbers (L11) to rule on ranking (Q2).
- **R22.** None for desks. Draw rows gain columns only.
- **Perf.** Four joins on PK or (store, product) indexes inside a compute measured at 15 to 34 s per store (`draw_pantry:202`, CITED 13-10-2026). Not measured with the joins. Test by plain EXPLAIN first.
- **Coverage limit.** The verdict holds linked products only (36,793 rows group-wide on 10-09-2026, CITED). An unlinked line carries no reason. Say so on the line.
- **Ruling needed.** None for the annotation. Ranking by it needs Q2.

### What comes after these three

- The draw drops DEPOSIT, NON_STOCK, SOURCE_FIX and World 2 (a2, a3). **If L4 shows these in the first 200 lines of a draw, move this above rank 3.** It needs Q3 because it can move the coverage KPI.
- A supplier list by desk (b2, b4). Needs Q4.
- One run log (g4, g5). Needs Q5.
- Proof of posting (f2). Small, count-internal, and it closes a derivation the app already owes (`pool_v2:153-154`).

---

## 5. What must NOT be connected, and why

1. **Order timing or delivery date into the count rank.** Canon rules it out. The reason for a count is doubt, never proximity to an order date (`ENGINE-CANON-COUNT-LAW.md:67`). The Forge list ranks on order proximity (`sql/create_rpc_forge_count_list.sql:16-31, 117-123`). That is one more reason not to copy it.
2. **`l2_stock_band.soh_flow_open` as a count signal.** It fired on 94 percent of CORE lines at 10116, all in the HEALTHY bucket. It is now surfaced with no verdict on purpose (`sql/create_l2_stock_band.sql:176-179`, CITED). A flag that fires on everything says nothing.
3. **The desk pools as the count pool.** A pool by active link and cycle department drops lines that need a count most. CITED on 14-10-2026: 380 received products with no active link, and 2,458 whose desk exists but whose pool does not hold them (`BUG-LOG.md:3130, 3133`). The coverage KPI denominator would also shrink (brief section 7, defect 1).
4. **The order cache as a source for count priority.** `bloom_order_cache_line` is a rendered sheet for one delivery date, built at 23:30 UTC, with some rows withheld (`e1` header, lines 14-21). Read the L2 facts. R32 says the pantry is stocked and an app reads it.
5. **The two TLX gates as one.** The harms differ (g2). Share the data and the correction list. Keep two gates.
6. **The 28-day sold test onto the ROS pantry (h2).** The meaning differs. The saving is 1.3 s once a night.
7. **The classification's `counted_91` realigned in a pass with anything else (f1).** It moves range state and with it the order pools. It needs its own R22 per desk, in rands.
8. **A swap of the SOH source on the count sheets before L8.** It would re-rank every draw and change every printed sheet.
9. **A merge of the verdict and placement copies of latest GRV inside this audit (b1).** It moves the E1 rows in the order cache. It is its own ship.
10. **The order flow onto the count tables (g1).** The life cycles differ. Copy the pattern for BLOOM-015. Do not share the tables.

---

## 6. Open questions for PM

I list these as missing rulings. I did not decide any of them.

1. **Rest day.** The 13-08 rule says no forced count on "the store's DC ambient delivery day". Does that mean the ambient desk only, or every DC desk including DC fresh? (e1)
2. **Counting priority.** Does Pieter's 13-10 16:24 order stand alone? Or does the 23-09 ruling that mission-critical lines are counted first on doubt (`ENGINE-CANON-COUNT-LAW.md:60-69`) rank inside each group? If it ranks, is the test "in the order pantry" or "in doubt"? (d1, d4, connection 3)
3. **Draw exclusions.** Should the draw also drop DEPOSIT, NON_STOCK, SOURCE_FIX and the World 2 label (`ORDERING-CANON.md:40`, `ENGINE-CANON-COUNT-LAW.md:32`)? At draw level, or at pool level, which moves `count_coverage_91d`? (a2, a3)
4. **Supplier lists.** By supplier account (today), or by desk (which adds DC fresh and the catch-all desk)? For lines not received in 182 days, is "no supplier list" acceptable, or should they fall back to the verdict's desk? (b2 to b4)
5. **One run log.** Bridge the app's cycles into `forge_count_run` with a new source value? Or retire the Forge issuance and point `rpc_forge_compliance_summary` and the weekly report at the app? Is cron job 25 and `/api/forge/export-stocktake` to be retired? (g4, g5)
6. **Which latest-GRV is master.** The verdict (DIWAREPR only, whole history) or placement (any module, 182 days)? Decide with the 32 "on another desk" products of 14-10-2026 (`BUG-LOG.md:3136`). (b1)
7. **New lines in INACTIVE.** Should a line received in the last N days be exempt from the "nothing sold in 28 days" group? (d3)
8. **Cost.** Which unit cost prices the draw and the variance value: the stock position's pick or the desk's chosen link? (c2)
9. **Counted in 91 days in the classification.** Align it to DIWAINV only, and when? It moves range state, so order pools. (f1)
10. **SOH on the sheet.** The engine's `soh_effective` or the lifecycle stock? Wait for L8. (c1)
11. **COUNT_FIRST hand-off.** Canon B8 says "the count list travels with the order". Does the buyer's `#` mark on the order sheet produce a count list for the floor, and through which app? (d4)

---

## 7. Defect candidates the audit surfaced

These are claims from the files. Each needs its live read before anyone calls it a defect.

| # | Candidate | Evidence | Read |
|---|---|---|---|
| 1 | The rest-day rule may read the DC fresh calendar row at 10116 and 80175 | `core.sql:438-441, 976` and `bloom035_1b_dc_fresh_phase1.sql:107-110` | L1 |
| 2 | The draw may hold World 2, deposit, non-stock and source-fix lines | `core.sql:253` against `create_l2_range_state.sql:139` | L4 |
| 3 | The weekly Chairman and VP report reads a different compliance figure from the toolkit | `weekly-report/route.js:68-71` against `measures/route.js:31-35` | L12 |
| 4 | The Composer's daily issue may still run | `draw_pantry:17`, `toolkit.html:4-6` | L2, L12 |
| 5 | The draw has no gate on the nightly chain, and ENG-236's full run is unproven | `draw_pantry:199-202`, `BUG-LOG.md:3225` | L2, L3 |
| 6 | Two latest-GRV copies may disagree on module and window | `e1:85, 91-101` against `verdict:95, 116-125` | L6, L7 |

---

## 8. Live reads for the 20:00 to 22:00 SAST window

All are read-only. None writes. Heavy ones are marked. Run one store at a time where the note says so. Run them as the database owner (the MCP role), because several objects here are service_role only. **I ran none of them.** Every figure in this report that depends on one is marked UNPROVEN.

**L1. Which DC row does the count rule pick, and is there a fresh row? (rows e1, defect 1)**

```sql
SELECT s.store_code,
       (SELECT sc.route_key FROM supplier_calendar sc
         WHERE sc.store_code = s.store_code AND sc.route_key LIKE 'DC%'
         ORDER BY sc.effective_from DESC LIMIT 1) AS picked_route,
       (SELECT sc.delivery_dows FROM supplier_calendar sc
         WHERE sc.store_code = s.store_code AND sc.route_key LIKE 'DC%'
         ORDER BY sc.effective_from DESC LIMIT 1) AS picked_dows,
       (SELECT string_agg(sc.route_key || ' ' || sc.delivery_dows::text || ' from ' || sc.effective_from::text,
                          ' | ' ORDER BY sc.route_key)
          FROM supplier_calendar sc
         WHERE sc.store_code = s.store_code AND sc.route_key LIKE 'DC%') AS all_dc_rows
FROM stores s WHERE s.is_active ORDER BY s.store_code;

SELECT c.store_code, c.generated_on, EXTRACT(ISODOW FROM c.generated_on)::int AS isodow,
       c.non_count_day, c.non_count_reason, COUNT(*) AS cycles
FROM stocktake_cycle c
WHERE c.generated_on >= CURRENT_DATE - 14
GROUP BY 1, 2, 3, 4, 5 ORDER BY 2 DESC, 1;
```

**L2. Which jobs run, and how long? (rows e3, g5, defects 4 and 5)**

```sql
SELECT j.jobid, j.jobname, j.schedule, j.active, left(j.command, 120) AS command
FROM cron.job j
WHERE j.jobid IN (15, 25, 43, 52, 53, 54)
   OR j.jobname ILIKE ANY (ARRAY['%forge%', '%stocktake%', '%bloom%', '%pipeline%'])
ORDER BY j.jobid;

SELECT j.jobid, j.jobname, d.status, d.start_time, d.end_time, d.end_time - d.start_time AS took
FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobid IN (15, 25, 43, 54) AND d.start_time > now() - interval '7 days'
ORDER BY d.start_time DESC LIMIT 60;
```

Note: for the one-transaction chain, `status` can read succeeded early. Judge job 15 by `took` and by L3.

**L3. How old is the data the draw was stocked from? (row e3, defect 5)**

```sql
SELECT ps.store_code, ps.refreshed_at AS draw_stocked_at,
       (SELECT MAX(c.snapshot_date) FROM l2_classification c WHERE c.store_code = ps.store_code) AS classification_date,
       (SELECT MAX(x.refreshed_at) FROM l2_last_counted x WHERE x.store_code = ps.store_code) AS last_counted_at,
       (SELECT MAX(x.refreshed_at) FROM l2_count_range x WHERE x.store_code = ps.store_code) AS count_range_at,
       (SELECT MAX(x.positioned_at) FROM l2_stock_position x WHERE x.store_code = ps.store_code) AS position_at,
       (SELECT MAX(x.snapshot_date) FROM l2_soh_daily x WHERE x.store_code = ps.store_code) AS soh_snapshot_date
FROM l2_stocktake_pool_summary ps ORDER BY ps.store_code;
```

**L4. What is in today's draw that canon says should not be? (rows a2, a3, defect 2)**

```sql
SELECT d.store_code, d.grp,
       COUNT(*) AS draw_lines,
       COUNT(w.product_code) AS world2_lines_in_draw,
       COUNT(*) FILTER (WHERE d.rank_overall <= 200) AS in_first_200,
       COUNT(w.product_code) FILTER (WHERE d.rank_overall <= 200) AS world2_in_first_200
FROM l2_stocktake_draw d
LEFT JOIN l2_world_assignment w
       ON w.store_code = d.store_code AND w.product_code = d.product_code AND w.world = 'WORLD_2'
WHERE d.kind = 'DRAW'
GROUP BY d.store_code, d.grp ORDER BY d.store_code, d.grp;

WITH lat AS (SELECT store_code, MAX(snapshot_date) AS d FROM l2_classification GROUP BY store_code)
SELECT dr.store_code, COALESCE(c.bucket, '(no classification row)') AS bucket,
       COUNT(*) AS draw_lines,
       COUNT(*) FILTER (WHERE dr.rank_overall <= 200) AS in_first_200,
       ROUND(SUM(ABS(COALESCE(dr.rand_value, 0)))) AS abs_rand_value
FROM l2_stocktake_draw dr
JOIN lat ON lat.store_code = dr.store_code
LEFT JOIN l2_classification c
       ON c.store_code = dr.store_code AND c.product_code = dr.product_code AND c.snapshot_date = lat.d
WHERE dr.kind = 'DRAW'
GROUP BY 1, 2 ORDER BY 1, 3 DESC;
```

**L5. How many draw lines can a supplier list reach, and which desks hold several supplier accounts? (rows b2 to b4)**

```sql
SELECT dr.store_code,
       COUNT(*) AS tlx_draw_lines,
       COUNT(rp.product_code) AS with_latest_grv_supplier,
       COUNT(*) FILTER (WHERE rp.product_code IS NOT NULL AND rp.state <> 'DESK') AS placement_state_not_desk,
       COUNT(*) FILTER (WHERE rp.desk_route_key = 'DC_FRESH') AS on_dc_fresh
FROM l2_stocktake_draw dr
LEFT JOIN l2_received_placement rp
       ON rp.store_code = dr.store_code AND rp.product_code = dr.product_code
WHERE dr.kind = 'DRAW' AND dr.route = 'TLX'
GROUP BY dr.store_code ORDER BY dr.store_code;

SELECT rp.store_code, rp.desk_route_key,
       COUNT(DISTINCT rp.latest_grv_supplier_nr) AS supplier_accounts,
       COUNT(*) AS products,
       string_agg(DISTINCT rp.supplier_name, ' | ') FILTER (WHERE rp.supplier_type = 'Z') AS dc_account_names
FROM l2_received_placement rp
WHERE rp.state = 'DESK'
GROUP BY rp.store_code, rp.desk_route_key
HAVING COUNT(DISTINCT rp.latest_grv_supplier_nr) > 1
ORDER BY rp.store_code, products DESC;
```

**L6. Do the placement desk and the verdict desk agree? (row b1)**

```sql
SELECT rp.store_code,
       COUNT(*) AS desk_products,
       COUNT(pv.product_code) AS with_verdict_row,
       COUNT(*) FILTER (WHERE pv.product_code IS NOT NULL
                          AND pv.route_key IS DISTINCT FROM rp.desk_route_key) AS desk_differs,
       COUNT(*) FILTER (WHERE pv.product_code IS NULL) AS no_verdict_row
FROM l2_received_placement rp
LEFT JOIN l2_population_verdict pv
       ON pv.store_code = rp.store_code AND pv.product_code = rp.product_code
WHERE rp.state = 'DESK'
GROUP BY rp.store_code ORDER BY rp.store_code;
```

**L7. Which modules post receipts? Placement takes any module, the verdict takes DIWAREPR only (row b1). Moderate cost. Run once per store, changing the literal.**

```sql
SELECT m.store_code, m.module, COUNT(*) AS receipt_lines, COUNT(DISTINCT m.product_code) AS products
FROM sigma_movements m
WHERE m.store_code = '10116'
  AND m.movement_type IN ('R', 'W') AND m.qty > 0
  AND m.movement_date > (SELECT MAX(x.movement_date) FROM sigma_movements x WHERE x.store_code = '10116') - 182
GROUP BY 1, 2 ORDER BY 3 DESC;
```

**L8. Do the two stock figures differ? (row c1). Moderate cost. Run once per store, changing both literals.**

```sql
SELECT sp.store_code,
       COUNT(*) AS normal_lines,
       COUNT(*) FILTER (WHERE e.product_code IS NULL) AS no_snapshot_row,
       COUNT(*) FILTER (WHERE e.product_code IS NOT NULL AND e.soh_effective IS DISTINCT FROM sp.soh) AS soh_differs,
       COUNT(*) FILTER (WHERE e.product_code IS NOT NULL AND ABS(e.soh_effective - sp.soh) >= 1) AS differs_by_one_or_more,
       MAX(e.snapshot_date) AS snapshot_date
FROM l2_stock_position sp
LEFT JOIN v_l2_soh_effective e
       ON e.store_code = sp.store_code AND e.product_code = sp.product_code
      AND e.snapshot_date = (SELECT MAX(x.snapshot_date) FROM l2_soh_daily x WHERE x.store_code = '10116')
WHERE sp.store_code = '10116' AND sp.class = 'NORMAL'
GROUP BY sp.store_code;
```

**L9. Do the two counted definitions disagree, and what does the live classification read? (rows d5, f1)**

```sql
WITH lat AS (SELECT store_code, MAX(snapshot_date) AS d FROM l2_classification GROUP BY store_code)
SELECT c.store_code,
       COUNT(*) FILTER (WHERE c.counted_91) AS classification_counted,
       COUNT(*) FILTER (WHERE c.counted_91 AND NOT v.counted_91) AS classification_counted_pool_not,
       COUNT(*) FILTER (WHERE NOT c.counted_91 AND v.counted_91) AS pool_counted_classification_not
FROM l2_classification c
JOIN lat ON lat.store_code = c.store_code AND lat.d = c.snapshot_date
JOIN v_stocktake_pool v ON v.store_code = c.store_code AND v.product_code = c.product_code
GROUP BY c.store_code ORDER BY c.store_code;

SELECT position('DIWAINV' IN pg_get_functiondef('public.refresh_l2_classification(text, date)'::regprocedure)) AS diwainv_position,
       length(pg_get_functiondef('public.refresh_l2_classification(text, date)'::regprocedure)) AS definition_length;
```

**L10. Do the sold-in-91-days copies agree? (row h3)**

```sql
SELECT rp.store_code, COUNT(*) AS products,
       COUNT(*) FILTER (WHERE rp.sold_91d AND NOT COALESCE(cr.sold_91, false)) AS placement_sold_range_not,
       COUNT(*) FILTER (WHERE NOT rp.sold_91d AND COALESCE(cr.sold_91, false)) AS range_sold_placement_not
FROM l2_received_placement rp
LEFT JOIN l2_count_range cr ON cr.store_code = rp.store_code AND cr.product_code = rp.product_code
GROUP BY rp.store_code ORDER BY rp.store_code;
```

**L11. How much of the draw is in doubt or mission critical? (rows d1, d4, connection 3)**

```sql
SELECT d.store_code, d.grp,
       COUNT(*) AS lines,
       COUNT(pv.product_code) AS in_verdict,
       COUNT(*) FILTER (WHERE pv.population_state = 'PHANTOM_CLAIMS_STOCK') AS phantom_claims_stock,
       COUNT(*) FILTER (WHERE pv.population_state = 'NEW_RANGE') AS new_range,
       COUNT(*) FILTER (WHERE rs.range_state = 'VERIFY') AS range_verify,
       COUNT(*) FILTER (WHERE sb.band_blocked) AS band_blocked,
       COUNT(rop.product_code) AS in_ros_pantry,
       COUNT(*) FILTER (WHERE d.rank_overall <= 200) AS first_200,
       COUNT(*) FILTER (WHERE d.rank_overall <= 200 AND rop.product_code IS NOT NULL) AS first_200_in_ros_pantry
FROM l2_stocktake_draw d
LEFT JOIN l2_population_verdict pv ON pv.store_code = d.store_code AND pv.product_code = d.product_code
LEFT JOIN l2_range_state rs        ON rs.store_code = d.store_code AND rs.product_code = d.product_code
LEFT JOIN l2_stock_band sb         ON sb.store_code = d.store_code AND sb.product_code = d.product_code
LEFT JOIN l2_bloom_ros_pantry rop  ON rop.store_code = d.store_code AND rop.product_code = d.product_code
WHERE d.kind = 'DRAW'
GROUP BY d.store_code, d.grp ORDER BY d.store_code, d.grp;
```

**L11b. How many INACTIVE lines are new? (row d3)**

```sql
SELECT d.store_code, COUNT(*) AS inactive_lines,
       COUNT(*) FILTER (WHERE cr.received_91) AS received_in_91d,
       COUNT(*) FILTER (WHERE pv.first_receipt_date >= CURRENT_DATE - 28) AS first_received_in_28d,
       COUNT(*) FILTER (WHERE pv.never_sold) AS never_sold
FROM l2_stocktake_draw d
LEFT JOIN l2_population_verdict pv ON pv.store_code = d.store_code AND pv.product_code = d.product_code
LEFT JOIN l2_count_range cr        ON cr.store_code = d.store_code AND cr.product_code = d.product_code
WHERE d.kind = 'DRAW' AND d.grp = 'INACTIVE'
GROUP BY d.store_code ORDER BY d.store_code;
```

**L12. Would the pantry flag catch the weighed lines, and does the Composer still issue lists? (rows h1, g4, g5, connection 1)**

```sql
SELECT rop.store_code, rop.product_code, rop.unit, rop.unit_incommensurable,
       a.unit AS article_unit, a.scale_flag, a.plu_flag
FROM l2_bloom_ros_pantry rop
JOIN sigma_articles a ON a.store_code = rop.store_code AND a.product_code = rop.product_code
WHERE rop.store_code = '10116' AND rop.product_code = 3970;

SELECT d.store_code, COUNT(*) AS draw_lines,
       COUNT(*) FILTER (WHERE rop.product_code IS NULL) AS no_pantry_row,
       COUNT(*) FILTER (WHERE COALESCE(rop.unit_incommensurable, true)) AS incommensurable_or_unmapped,
       COUNT(*) FILTER (WHERE a.scale_flag = '1' OR a.plu_flag = '1') AS scale_or_plu_flag,
       ROUND(SUM(ABS(COALESCE(d.rand_value, 0)))) AS abs_rand_all,
       ROUND(SUM(ABS(COALESCE(d.rand_value, 0))) FILTER (WHERE COALESCE(rop.unit_incommensurable, true))) AS abs_rand_flagged
FROM l2_stocktake_draw d
LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code = d.store_code AND rop.product_code = d.product_code
LEFT JOIN sigma_articles a        ON a.store_code = d.store_code AND a.product_code = d.product_code
WHERE d.kind = 'DRAW'
GROUP BY d.store_code ORDER BY d.store_code;

SELECT x.store_code, x.product_code, x.description, x.count_date, x.correction, x.unit_cost, x.rand_value,
       a.unit AS article_unit, a.scale_flag, rop.unit_incommensurable
FROM (
  SELECT c.*, sp.description,
         ROW_NUMBER() OVER (PARTITION BY c.store_code ORDER BY ABS(c.rand_value) DESC NULLS LAST) AS rn
  FROM l2_normalised_count c
  LEFT JOIN l2_stock_position sp ON sp.store_code = c.store_code AND sp.product_code = c.product_code
  WHERE c.count_date >= CURRENT_DATE - 182
) x
LEFT JOIN sigma_articles a        ON a.store_code = x.store_code AND a.product_code = x.product_code
LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code = x.store_code AND rop.product_code = x.product_code
WHERE x.rn <= 10
ORDER BY x.store_code, x.rn;

SELECT r.store_code, r.source, r.mode,
       (r.issued_at AT TIME ZONE 'Africa/Johannesburg')::date AS issued_day,
       COUNT(*) AS runs, SUM(r.line_count) AS lines
FROM forge_count_run r
WHERE r.issued_at > now() - interval '14 days'
GROUP BY 1, 2, 3, 4 ORDER BY 4 DESC, 1;

SELECT c.store_code, c.generated_on, c.list_type, COUNT(*) AS cycles, SUM(c.line_count) AS lines,
       COUNT(*) FILTER (WHERE c.status = 'FINALISED') AS finalised
FROM stocktake_cycle c
WHERE c.generated_on >= CURRENT_DATE - 14 AND c.status <> 'CANCELLED'
GROUP BY 1, 2, 3 ORDER BY 2 DESC, 1;
```

**L13. Do the two unit costs differ on draw lines? (row c2)**

```sql
SELECT d.store_code, COUNT(*) AS draw_lines_in_verdict,
       COUNT(*) FILTER (WHERE pv.chosen_unit_cost IS NOT NULL AND d.unit_cost IS NOT NULL
                          AND ABS(pv.chosen_unit_cost - d.unit_cost) > 0.05 * GREATEST(pv.chosen_unit_cost, d.unit_cost)) AS cost_differs_over_5pct
FROM l2_stocktake_draw d
JOIN l2_population_verdict pv ON pv.store_code = d.store_code AND pv.product_code = d.product_code
WHERE d.kind = 'DRAW'
GROUP BY d.store_code ORDER BY d.store_code;
```

**L14. Recount the REAL lines whose two keys disagree (row g2)**

```sql
WITH lat AS (SELECT store_code, MAX(snapshot_date) AS d FROM l2_classification GROUP BY store_code)
SELECT c.store_code, COUNT(*) AS real_lines_where_keys_disagree
FROM l2_classification c
JOIN lat ON lat.store_code = c.store_code AND lat.d = c.snapshot_date
JOIN l2_export_key k ON k.store_code = c.store_code AND k.product_code = c.product_code
WHERE c.ean_status = 'REAL' AND k.export_eligible AND k.export_key <> c.ean_key
GROUP BY c.store_code ORDER BY c.store_code;
```

---

## 9. What I read and what I did not

**Scoped start-read.** I did not run the CLAUDE.md recital. I read the files below because they govern this task. Anything not listed is unread.

**Read in full**

- Count SQL, all 8 files: `sql/eng241_stocktake_count_app_core.sql` (1,149 lines), `eng241_stocktake_supplier_lists.sql`, `eng241_stocktake_upload_unread.sql`, `eng241_stocktake_pool_v2.sql`, `eng241_stocktake_draw_pantry.sql`, `eng241_stocktake_normalised.sql`, `eng241_stocktake_compliance.sql`, `eng240_stocktake_pool_single_home.sql`.
- Count code: `src/lib/stocktake/` (`sheet.js`, `server.js`, `qty.js`, `reasons.js`). `src/app/stocktake/page.jsx`, `api.js`, and the components `format.js`, `GeneratePanel.jsx`, `CountTable.jsx`, `CycleView.jsx`, `StoreList.jsx`, `StoreScreen.jsx`, `VarianceReview.jsx`. All 15 routes under `src/app/api/stocktake/`.
- Canon and brief: `ENGINE-CANON-COUNT-LAW.md`. `SB-CC-STOCKTAKE-001_count-app_2026-10-13.md` (the Forge copy is byte-identical, checked with `cmp`).
- Ordering SQL: `bloom035_eng202_catchall_desk.sql`, `bloom035_1b_dc_fresh_phase1.sql`, `bloom035_a1_latest_grv_overlap.sql`, `bloom035_e1_received_placement.sql`, `create_supplier_desks_from_receipts.sql` (v1.0, the live v1.1 is `bloom035_item1_v11_cadence_catchall.sql`, which I only grepped), `create_rpc_bloom_desks.sql`, `create_supplier_calendar.sql`, `create_v_l2_soh_effective.sql`, `create_l2_range_state.sql`, `create_l2_export_key.sql`, `create_v_item_ean.sql`, `create_l2_stock_position.sql`, `create_l2_last_counted.sql`, `create_rpc_forge_count_list.sql`, `create_v_forge_count_line_evidence.sql`.
- Other code: `src/app/api/forge/export-stocktake/route.js`.

**Read in part**

- `sql/create_rpc_bloom_order_recipe.sql`: lines 1-200 (header), 380-670 (route scope, supplier link, pool, tiers, promo match), plus a grep of every CTE name and the `count_first` and `range_state` lines. The quantity logic (lines 670 to the end) is not read.
- `sql/create_refresh_l2_population_verdict.sql`: lines 1-330.
- `sql/create_l2_classification.sql`: lines 1-180 and 180-521 in two reads (the cascade and the scope).
- `sql/create_l2_stock_band.sql`: lines 60-240 and 296-366, plus grep.
- `sql/create_l2_population_verdict.sql`: lines 1-110.
- `sql/create_refresh_forge_daily_issue.sql`: lines 1-60, plus grep.
- `sql/create_forge_count_run.sql`: lines 1-70, plus grep.
- `src/app/api/forge/weekly-report/route.js`: lines 1-120.
- `src/app/bloom/page.jsx`: lines 10-24, 2056-2068, 2222-2278, 2318-2398, plus grep.
- `ORDERING-CANON.md`: lines 1-122 and 214-244. `RULE-BOOK.md`: R33, lines 328-344.
- `BUG-LOG.md`, by grep and line range only: ENG-241 (lines 3041-3061), ENG-234 add.3 and add.4 (3117-3155), ENG-020 add.1 (3157-3163), ENG-236 add.3 (3223-3235).
- `scripts/stocktake-sheet-selftest.mjs` and `scripts/stocktake-render-test.mjs`: the first 50 to 70 lines each. They test the sheet builder and the page. They hold no engine logic.
- Grep only: `create_refresh_l2_pipeline.sql`, `create_l2_bloom_ros_pantry.sql`, `bloom035_1b_dc_fresh_phase0.sql`, `bloom035_item1_v11_cadence_catchall.sql`, `public/toolkit.html`, `src/middleware.js`.

**Not read**

- Count UI glue: `draftStore.js`, `saveQueue.js`, `errors.js`, `routeState.js`, `layout.jsx`, `stocktake.css`, and the components `EventLog`, `FinalisePanel`, `HistoryTab`, `LineHistory`, `LoadError`, `Notice`, `PendingCards`, `ReadyCard`, `ReadyPanel`, `StepBar`. I grepped `src/app/stocktake` for engine logic (calendar, cost, variance, list size) and found only the items in rows e1 and h8.
- `BUG-LOG.md` as a whole, `DEPLOY-LOG.md`, `HANDOVER-CURRENT.md`, `DB-SCHEMA.md`, the rest of `ORDERING-CANON.md` and its companions, `RULE-BOOK.md` except R33, `PROJECT-LEXICON.md`, the other canon children.
- The ordering quantity logic, budgets, promo and gearing, which this audit does not need.
- The live database. I had no access and made no call.

**Limits of the repo copies.** Per the task, `sql/create_*.sql` and `sql/bloom035_*.sql` copies are md5-equal to live as of 14-10-2026 15:30 SAST. I did not re-prove that. Two exceptions I know of: `create_l2_stock_position.sql` is the v1.0 file with no live hash, and `create_v_forge_count_line_evidence.sql` is the 08-13 version. ENG-187 changed the live compliance view after that. Where I rely on either, I say so.
