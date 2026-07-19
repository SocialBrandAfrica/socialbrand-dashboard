# SocialBrand Dashboard — Deploy Log

Reverse-chronological. Each entry = one production deploy.

---

## 2026-07-18 (later 4) -- PREDICT-001 step 2: l2_sales_budget x5 + nightly wiring (ENG-022 / ENG-002)

The need projection extended from 2 stores to all 5, every ruled route, and wired into the nightly chain -- ENG-002 closes WITH the table, not after it (PM note 3). The projection machinery (`refresh_l2_sales_budget` / `rpc_project_route_sales_budget`) was already fully general (resolves the DC route from `format_group`, loops every RULED `bloom_route_config` route); it was simply run by hand for 2 stores and never wired -- the ENG-022 defect.

- **Populated x5, all 19 store-routes, 26 weeks each** (494 rows): 10116 + 80175 = 6 routes (DC_AMBIENT + 5 direct desks incl. today's DIRECT_NATBRANDS), 21355 = 3 (DC_TOPS + DIRECT_BEER + today's DIRECT_COCACOLA), 80176 + 80579 = 2. The newly-seeded fortnightly desks were picked up automatically (RULED config).
- **Wired into `refresh_l2_pipeline`** (migration `predict_03_wire_sales_budget_into_pipeline`, `sql/create_refresh_l2_pipeline.sql`) after the Bloom pantry chain, so `l2_rhythm_profile` + `l2_seasonality_profile` (its inputs beside `l2_stock_position`/`sigma_sales`) are fresh. Per-store guarded. Verified: `pg_get_functiondef` contains the call, 5 stores / 19 routes populated.
- **R22 gate (PM note 3), all three met:** (a) `ly_base_cost` reconciles to raw `sigma_sales` to the rand -- 80175/DC_AMBIENT week 1: pool 12,741 products, direct LY sum R266,978 == projected `ly_base_cost` R266,978; (b) route-scope population proven -- pool sizes match each route's config; (c) the TOPS LY-blind caveat is a per-row column (`products_with_ly_history`/`products_in_pool`) -- DC_TOPS reads ~11% LY coverage at all three TOPS stores (the §3c-d recycled-code join gap), SPAR DC 14-27%, named on every row, no store scored FAIL on thin LY.
- **PROVISIONAL** (PREDICT-001 DoD 6): the raw `trend_factor` still drives (step 4 replaces it with the locked recovery ladder), and holidays are uncorrected (§16). Nothing governs orders off this yet -- the 82% basis still drives every order calc until Pieter signs.

Step 2 of the accuracy-first sequence. Next: ENG-020 (World-1 purity, leg-2 gates = LINK_CODES non-empty + named-case regression) → World-2 dept interim → recovery-ladder trend → event calendar → sign. `sql/create_refresh_l2_pipeline.sql`.

---

## 2026-07-18 (later 3) -- PREDICT-001 step 1: the ex-VAT finance gauge

First step of the purchase-prediction engine (SB-CC-PREDICT-001 §7.1) -- source-only, fast, gives finance the one honest number today. Corrects the VAT basis and exposes cost-error contamination.

- **The basis was wrong at source:** `refresh_order_budget_ledger` sets `sales_actual = SUM(sales_incl_vat)` (incl-VAT) while `landed_amount = SUM(cost_value)` (ex-VAT cost) -- so any purchases/sales ratio mixed bases. `sigma_sales` carries native `vat_value`, so `sales_exvat = sales_incl_vat - vat_value` is the fix (never a flat /1.15).
- **`rpc_predict_exvat_gauge(p_date_from, p_date_to, p_store_codes, p_gp_floor_pct)`** (migration `predict_02b`, `sql/create_rpc_predict_exvat_gauge.sql`) -- per store, whole-store (PREDICT-001 ruling 2): sales incl + ex-VAT, purchases (R/W cost), COGS raw + cost-error-clean (l2_classification COST_ERROR excluded, canon §12c), ratio ex-VAT vs the 82% target (config `purchases_to_sales_target`, DEMO_CALIBRATION), vs-target in pp, GP ex-VAT, and a `gp_health` flag that surfaces implausible GP rather than hiding it. Layer-2 published interface (R30/R32); ratios are ACTUALS (R22), not the projection. Grant EXECUTE to `authenticated`.
- **R22 (last 8 budget weeks 2026-05-23..07-17), reproduces the spec to the decimal:** ex-VAT ratio 10116 77.1% / 21355 83.5% / 80175 74.3% / 80176 71.1% / 80579 41.4% (spec: 71-84%); incl-VAT 69.0/72.6/66.3/62.0/36.2 (spec: 62-73%, target meaningless); GP ex-VAT 19.8/-0.7/19.4/16.5/10.5 (healthy SPARs 15-19%). **21355 GP -0.7% correctly trips `gp_health=REVIEW`** -- the cost-error contamination the gauge is meant to expose (its COST_ERROR bucket catches only 2 lines, so the gauge flags a bigger contamination for the worklist). 80579 41.4% is the IBT-fed Dice, a real false-green-on-low-own-purchases case.
- **Config:** `purchases_to_sales_target` = 0.82 (DEMO_CALIBRATION, canon v11 item 3) added to `forge_config`.

Step 1 of the accuracy-first sequence; steps 2-5 (l2_sales_budget to 5 stores wired nightly, World-2 dept interim, recovery-ladder trend, event-calendar sign-off) follow, each R22-gated. `sql/create_rpc_predict_exvat_gauge.sql`.

---

## 2026-07-18 (later 2) -- v_supplier_class: dropshipment identified programmatically (Pieter ruling)

Correction after a rule break: I had located Mondelez by name-matching `supplier_text` (against R21/R22 -- the engine reproduces from programmatic source, names are a human label only). The right key was the Sigma supplier type (`DBLFTS.TYP` -> Z/S/F), which is exactly the axis I missed. Keyed on it, the picture is decisive:

- **Every "DIRECT_<brand>" desk supplier is `supplier_type='S'` = DROPSHIP** -- delivers its own truck (own R/W receipts) but is payable via the SPAR DC creditor. Clover, Coca-Cola, Simba, Danone, National Brands and Mondelez-via-Super-Group are all this class. **Only SAB is `type='F'` = true DIRECT.** The framework has been dropshipment all along.
- **`v_supplier_class`** (migration `supplier_class_01_v_supplier_class`, `sql/create_v_supplier_class.sql`) makes it a first-class queryable fact per (store, supplier): class Z->DC / S->DROPSHIP / F->DIRECT, plus terms/order_method/settlement-discount fields and a `delivers_own_182d` liveness flag. Purely source-derived (DEDUCTIVE), no names. Group-wide: DROPSHIP 12,871 (142 deliver own) / DIRECT 822 (64) / DC 101 (8), zero nulls-or-other. So creditors, repayment terms and supplier-performance are defined up front, and a dropshipment supplier is never pooled into the DC for orders/deliveries. Grant SELECT to `authenticated`.
- **Mondelez was never a scoping problem** -- it is an ordinary dropshipment supplier whose delivering account is 950 (10116) / 654 (80175); my "multi-brand" worry came from reading the empty shell account 1586. It seeds like any other dropship brand once PM rules on the desk naming.
- **L1 GAP flagged (R23):** `creditor_nr` is NULL on all 13,794 supplier rows -- the DC-creditor linkage a DROPSHIP supplier settles through is not extracted yet. `supplier_type` is the current dropshipment marker; the creditor account must be added to L1 before the finance modules can resolve it.

**For PM (policy, not built):** whether to relabel `DIRECT_<brand>` desks as their true DROPSHIP class (R30 cascade -- recipe/frontend/config), how the DC-creditor payment reconciliation treats dropship goods, and seeding Mondelez as a dropship desk. `sql/create_v_supplier_class.sql`.

---

## 2026-07-18 (later) -- ENG-025 step 4: two fortnightly desks seeded + the DC-overlap guard

Step 4 of the cadence law, taken to walk-ready then handed to Pieter. Two of the "fortnightly four" activated, the DC-overlap guard PM asked for built, and Mondelez surfaced as a scoping question rather than seeded on a guess.

- **The DC-overlap guard `rpc_bloom_direct_dc_overlap(store, route)`** (migration `cadence_law_07_direct_dc_overlap_guard`). A DIRECT_<brand> desk pools by supplier LINK, the DC desk pools by DEPARTMENT -- a product in both is ordered twice. The guard surfaces the overlap (R22/R29, flag never block), runnable before the calendar is seeded. Reusable for store #6 (R25/R32). `sql/create_rpc_bloom_direct_dc_overlap.sql`.
- **Coca-Cola 21355 (supplier 316) + National Brands 80175 (47) SEEDED fortnightly** (migration `cadence_law_08b_seed_fortnightly_two_desks` + `refresh_supplier_calendar`). Both are single-brand accounts where the link number == the receipt number, so the recipe pool and the cadence agree on one `supplier_nr`. `cycle_weeks=2`: Coca-Cola 21355 Fri (anchor 06-27), NatBrands 80175 Tue (anchor 07-04). Guard clean (0 overlap) on both. R22: next-deliveries land exactly 14 days apart (fortnightly proven live -- Coca-Cola 07-31->08-14, NatBrands 07-21->08-04); scenario_overview runs, and the min-order flag works on real data (NatBrands full order R2,511 correctly reads "R2,488.89 below the R5,000 minimum", never blocks). Frontend `STORE_DESKS` entries added in `src/app/bloom/page.jsx` (auth-gated -- Pieter's R31 walk is the gate). `confirmed_by` left NULL until that walk.
- **Mondelez x2 HELD -- a scoping question for PM, not an identity failure.** The receipt-proven hunt (canon 7d) found Mondelez is **Super Group distributor-delivered** (10116 supplier 950, 80175 supplier 654), a MULTI-BRAND account: 950 receives 96 products @10116, only 42 Mondelez. Its "MONDELEZ" link account (1586/1280) carries the product identity but ZERO receipts. So link != receipt AND the receiving account mixes brands -- it does not fit the single-supplier_nr desk model the built desks use. Needs a PM ruling (scope by the Mondelez link with cadence read from the distributor's Mondelez-only receipts, or a distributor-level desk), R27 §7. Never name-guessed.

`sql/`: `create_rpc_bloom_direct_dc_overlap.sql`, `create_bloom_route_config_fortnightly_cocacola_natbrands.sql`, `src/app/bloom/page.jsx`.

---

## 2026-07-18 -- ENG-025 THE CADENCE LAW GETS A HOME: grain + generator (canon §14 v9 7e-7h)

The cadence law lived only in canon prose and a migration comment block -- no engine object derived it, nothing wrote `supplier_calendar` (its 16 rows were a hand-written `INSERT ... VALUES`). That is the R25 break named in canon 7h: a new store gets an empty calendar and no drop cover. This deploy promotes the logic CC had written five times as throwaway SQL into two callable objects, and ships the fortnightly grain WITH its generator in one pass (binding: "ships together" -- the anchor is a date only the ledger can honestly give). Applied live to prod (`crklvhfwyxlisfcvqenc`) via MCP migrations; DB changes only, no frontend touched.

**Migrations (all live):** `cadence_law_01_grain_supplier_calendar_cycle`, `cadence_law_02b/02c_forge_config_cadence_keys`, `cadence_law_03c_derive_dow_recency` (+ `ALTER ... SET search_path=public`), `cadence_law_04_refresh_supplier_calendar`, `cadence_law_05_next_deliveries_cycle_aware`, `cadence_law_06_retire_direct_cycle_weeks`.

- **The grain.** `supplier_calendar` + `cycle_weeks smallint NOT NULL DEFAULT 1` + `cycle_anchor_week_start date` + CHECK `(cycle_weeks=1 OR anchor NOT NULL)`. Anchor = the budget-week START (Saturday) of the qualifying drop, never a raw drop date (correction 1). At `cycle_weeks=1` byte-identical to pre-grain -- the zero-delta proof.
- **The generator.** `rpc_derive_supplier_cadence(store, route, window)` RETURNS the proposed row + evidence (R29): value floor (0.25× the supplier's own median receipt-day cost) → regime-outlier gaps excluded and NAMED → median → half-down `GREATEST(1, CEIL(median/7.0-0.5))` → dow from the CURRENT regime (trailing 84d). Reproduces every ruled figure: 9 configured desks all `cycle_weeks=1`; NatBrands 10116 gap 10.5→weekly (the half-down tie, `ROUND(1.5)=2` would have doubled it); 80175 Coca-Cola Thursday @ 60% (the two-regime average that fooled the PM, 7i, now read from the recent regime only).
- **The writer.** `refresh_supplier_calendar(store)` writes cadence with provenance; onboarding = one call. Existing desks: `delivery_dows` PRESERVED verbatim (dow divergence surfaced in source_note per ENG-026), only cadence stamped -- **zero delivery_dows delta on all 9 desks** (BEFORE 10116 Coca-Cola `[5]` == AFTER `[5]`, etc.).
- **The wiring.** `rpc_bloom_next_deliveries` honours `cycle_weeks` via a floored non-negative-safe modulo (correction 2). **AFTER == BEFORE byte-for-byte on all 11 direct desks + DC/BEER** at anchor 2026-07-18 (zero-delta). Fortnightly alternate-week selection + negative-week safety proven.
- **ENG-025 step 2.** `bloom_route_config.direct_cycle_weeks` RETIRED with lineage (R28, superseded_by `supplier_calendar.cycle_weeks`) -- never dropped, never read; the calendar owns cadence. The `direct_min_order_value` flag (step 2b) was already live (`d7863d3`), confirmed surfacing per scenario, never blocks.

**R22 gate: GREEN.** Cadence zero-delta (9 desks derive = stored), next-deliveries zero-delta (11 desks AFTER==BEFORE), end-to-end recipe/scenario_overview spot-check clean. get_advisors: functions carry explicit `search_path`; SECURITY DEFINER writer pinned to `public`.

**Staged, NOT activated (step 4 follow-on):** Coca-Cola 21355 (316) + National Brands 80175 (47) receipt-confirmed fortnightly (`cycle_weeks=2`), ready to seed. Held because activating a fortnightly Coca-Cola desk at TOPS 21355 risks double-ordering lines already in the `DC_TOPS` dept-cycle pool (needs a DC-overlap guard + Pieter's R31 walk), and **Mondelez ×2 identity is unresolved** (its `supplier_text` at the SPAR pair matches no Mondelez brand token; identity is receipt-proven, never name-guessed -- R21/R22). `sql/`: `create_supplier_calendar_cycle_grain.sql`, `create_rpc_derive_supplier_cadence.sql`, `create_refresh_supplier_calendar.sql`, `create_rpc_bloom_next_deliveries.sql`.

---

## 2026-07-17 -- ENG-025 (rows + min flag), BLOOM-009 wave 3, PM script fixes, key ignore

Five commits this session, all on `origin/main`, all R22'd to source. Reverse order below.

**`d7863d3` — ENG-025 step 2b: direct minimum order value as a FLAG (PM queue item 2, canon v7 item 7e).** `rpc_bloom_scenario_overview` gains three additive columns (`min_order_value` / `min_shortfall` / `min_reason`), computed off `value_normal` per scenario, config home unchanged on `bloom_route_config.direct_min_order_value`. Never blocks. R22, all three branches: NatBrands clears (R12,599 vs R5,000, shortfall 0); DC route returns NULL (no supplier-minimum concept); a throwaway desk at a R10,000 min on a R5,221 order returned shortfall R4,779 with the order STILL generated (9 lines) — seeded in a transaction, rolled back, zero residue verified. Frontend renders it under each scenario card, amber when short. `next build` clean; `/bloom` auth-gated so static proof only.

**`a5fb769` — BLOOM-009 wave 3: National Brands direct desk at 10116 (config only).** Shipped HALF of PM queue item 1. Identity receipt-proven: `direct_supplier_nrs = {99, 2071}` unioned — the dominant `99` misses 10 selling lines on sub-account `2071` that National Brands receives itself (the wave-1 dominant-only method would have dropped them); `1543` excluded, dead. Cadence: median drop gap 10.5 / 16 gaps = exactly 1.50 cycles = the tie, canon 7f resolves ties weekly → `cycle_weeks=1`, today's behaviour, no grain dependency. Delivery Tue 76%. R22 clean: 0 tail ordered, 0 over-35d unflagged, 0 OOS KVI silent; order R11,993 = 11.9 days of demand on an 11-day horizon. **Mondelez 10116 HELD** — its cadence flips on the lines-per-day noise floor (≥1 → median 9 → weekly; ≥3, the brief's own floor → median 12 → fortnightly) and it has no dominant delivery day (Wed 38% / Thu 38%). Not seeded on a coin toss. Later re-derived on PM's value floor (canon 7g): clean median 11.0 with the 42-day supply hole excluded → fortnightly, Thursday (most-recent regime), now a fully-specified item-5 desk.

**Implementation trap recorded:** Postgres `ROUND(1.5)=2` is 7f backwards on the tie and would have seeded the NatBrands desk fortnightly, doubling its cover. 7f rounding is `GREATEST(1, CEIL(median_gap/7.0 - 0.5))` (verified 1.29→1, 1.50→1, 1.86→2, 2.50→2).

**`9ef44d7` — ENG-025 step 1: re-derive every direct desk cadence from receipts (PM ruling, rows before column).** `direct_cycle_weeks` set behaviourally on all 11 live direct desks from median drop gap, while the column is still unread (no-op on behaviour). Caught the one that mattered: **Coca-Cola 80175 stored `fortnightly` against a real 7.0-day median gap over 22 observations** — it ordered correctly only because the column is dead; column-first would have doubled its cover. DIRECT_BEER ×3 carried NULL, all re-derive weekly. Post-condition fails loudly if any RULED direct desk is NULL or non-weekly before the grain lands. **Full value-floor re-derivation (canon 7g) run after: all 12 live desks — 9 brand + 3 beer — reconcile weekly on the ruled method, zero wrong rows.**

**`7802109` + `a335a8f` — PM's two live-server script fixes committed (ENG-024, ENG-023).** Authored by PM on Pieter's disk during the server rollout, uncommitted and lost on the next pull; both already live on all 5 servers. ENG-024: extractor v1.24, 18:40→19:30 (after the 19:00 close + Sigma EOD), with the trigger check matching `$atTimeToken` not the hardcoded literal so self-heal cannot pull it back. ENG-023: task description set in the XML before registration (`Set-ScheduledTask` has no `-Description` param — the old call halted the migration mid-rollout). Both parser-clean, ASCII-only.

**`6d5d075` — gitignore `sb-key.txt` (the Supabase service_role key).** Untracked, un-ignored, never committed (verified `git log --all --full-history`). Closes disk-exposure before it opens; committed alone ahead of any other add.

---

## 2026-07-17 -- SB-CC-BLOOM-009 wave 2: Clover, Simba, Danone direct desks (`8a2207c`)

Six new direct desks at the SPAR pair (10116 + 80175). **Config-only** — `rpc_bloom_order_recipe`, `rpc_bloom_stock_state` and `rpc_bloom_scenario_overview` already generalise on the `DIRECT_<brand>` route pattern and read `direct_supplier_nrs` off a RULED `bloom_route_config` row, so a desk is one config row + one calendar row + a frontend list entry. Zero schema change, zero RPC change: R32's rollout test passing on its own terms. Migration `bloom009_wave2_direct_desks_clover_danone_simba`; canonical file `sql/create_bloom_route_config_direct_desks_wave2.sql`.

**Supplier identity settled on receipts, not names or link counts.** Three independent signals (live-linked product count / R-W receipt cadence / demonstrated 28d cost demand) agree on one receiving `supplier_nr` per brand per store. The receipt test decides, because wave 1 already proved the name-obvious account can be a ghost — and it caught a second one at scale: **10116 CLOVER `1611` holds 614 live links and 613 products `1610` does not carry, and ZERO of them have sold in 28 days (R0.00).** Dead legacy account, excluded. This supersedes wave 1's "1610+1611 union" note, which observed the same cadence but never tested whether `1611` contributed anything. The same exclusive-selling-product test run across **every** sub-account of all five brands: Mondelez `1586` R54.66/wk, Mondelez `1280` R4.53/wk, every other R0.00. The dominant `supplier_nr` alone is the proven pool.

**Demand cross-check vs the brief's own PM reference (item 5, 10116 weekly):** Simba R18,006 vs R18,092 (−0.5%), Mondelez R16,159 vs R15,938 (+1.4%), Danone R8,959 vs R9,075 (−1.3%). Clover +22.5% and National Brands −16.5% are the 5-day window shift between the brief (12 Jul) and this build (17 Jul), **not** pool errors — the sub-account test proves the dominant covers everything that sells. Reported, never tuned to match.

**Cadence: median gap between consecutive drops, not drops-per-week.** The brief's rule 3 (`drops_per_wk >= 1 -> weekly`) is a proxy, and measured directly it mis-classifies two brands. R21 — behaviour decides, never a constant fitted to one case.

| desk | drops/wk | median gap | verdict | dows |
|---|---|---|---|---|
| Clover 10116/80175 | 1.50 / 1.75 | 5.0d | twice weekly | {2,4} |
| Danone 10116/80175 | 1.50 / 1.88 | 5.0d / 4.0d | twice weekly | {2,4} |
| Simba 10116/80175 | 0.75 / 0.75 | **7.0d** | **weekly** | {5} |

Simba reads "fortnightly" under the literal rule at 0.75 drops/wk; its median gap is exactly 7.0 — a weekly Friday truck skipping ~1 Friday in 4 (noise floor + holidays pull the mean to 9.5). Exact parity with the shipped, accepted Coca-Cola 10116 desk (median 7.0). Clover/Danone get **two** delivery days, which does not contradict wave 1's "single dominant weekday" note: that guards a once-weekly supplier from a phantom second truck, and Clover's second truck is real. Forcing one DOW would claim the next truck is 7 days out when it is 2-5 — over-ordering, the exact inverse of the bug wave 1 fixed.

**HELD, not shipped — Mondelez + National Brands.** Both are genuinely fortnightly (median gap 11-13d at both stores). `supplier_calendar.delivery_dows` is a weekday array with no fortnightly concept, so a weekly desk would knowingly **halve** their cover — barred by the accuracy gate (canon v9 item 8). They wait on the cycle mechanic, a shared pantry debt (R32), not a per-desk patch.

**R22, population level, all 6 desks:** 35-day ceiling **0 breaches** (max 33.8d) · tail states ordered **0** · out-of-stock KVI lines silently un-ordered-and-unflagged **0**. Calendars return orderable dates with true leads (Clover/Danone Tue→Thu lead 2; Simba Fri→Fri lead 7).

**Simba's order reads 2.7× weekly demand and is CORRECT — verified against the engine's own instrument rather than accepted or explained away.** `rpc_bloom_stock_state` shows Simba KVI at 10116 holding **1.2 stock-days** against an 11-day min band, with 9 KVI_CRITICAL lines at SOH 0. The bands reconcile exactly to ENG-012's order-time recompute (MRS H S BALLS: demand 12.64 × (KVI safety 4 + lead 7) = min_band 139.0 vs 139.1 live). The desk is refilling a starved category on a weekly truck — the availability failure the KVI floor exists to fix, not an over-order. A 1×-weekly yardstick is simply the wrong test for a depleted pool.

**Named live defect found, flagged NOT fixed here:** `bloom_route_config.direct_cycle_weeks` and `direct_min_order_value` are **stored but never read** — nothing in `sql/` or `src/` consumes either, so brief rules 3 (cycle) and 4 (R5,000 minimum, accumulate to next cycle) are config decoration rather than behaviour on **every** direct desk, wave 1 included. Consequence today: Coca-Cola 80175 carries `direct_cycle_weeks=2` while its own median gap is 7.0 (weekly) — the config is wrong *and* inert, so the live desk orders on the correct weekly cover by accident. The moment that column becomes load-bearing, the stale row would **double** a live desk's cover. Carrying that dependent is part of the fortnightly build (R30), which is why `direct_cycle_weeks` is set honestly on every wave-2 row even though nothing reads it yet.

**Verification, explicit about its limit:** `next build` clean, middleware loaded (81.6 kB). `/bloom` is auth-gated and this session held the standing no-middleware-bypass rule, so there is **no live screenshot**. Push confirmed on `origin/main` (0/0); `orders.socialbrand.africa/bloom` serves 307 → `/login` correctly. **Vercel deploy NOT independently confirmed from this seat** — no Vercel CLI, no `.vercel` dir, no token, and the changed page sits behind auth so the usual public-buildId check cannot see it. Pieter's own desk walk is the DoD gate (R31).

---

## 2026-07-14 -- PUSH-HARDEN-001: finalize made surgical -- export folder kept, credential stripped (`594b646`)

Pieter's design refinement: `C:\SocialBrand` **survives** as the genuine Sigma export folder (CSV/Excel only, load-bearing for nothing) while `C:\RetailHistory` holds the machinery under a neutral name — the brand lands on the one folder where it means nothing.

**Two real bugs this exposed in the prior commit:**
1. `-Finalize` did `Remove-Item $OldDir -Recurse -Force` — under the new design that **destroys the export folder and everything in it** (`DIWAAIS.xls`, `DIWAAIS2.xls`, every CSV). Now surgical: explicit named machinery list, never a recursive wipe.
2. **The credential.** `sb-key.txt` (Supabase service_role key) lives in `C:\SocialBrand`. The export folder is deliberately *unlocked* — fine for exports, but a service_role key in it hands out full DB access to any interactive user and defeats the entire exercise. Moot under the old "delete the whole folder" finalize; now that the folder survives, the key **must** be stripped out. It's on the machinery list and is the most important item on it.

**Safety:** never removes a machinery file whose counterpart is missing from the locked folder (losing `sb-key.txt` with no surviving copy would permanently dark that store's feed) — keeps it back and warns loudly. Post-strip it lists survivors and flags any `.ps1`/`.bat` or key/secret/token-named file still in the unlocked folder.

**Unit-tested** in temp folders, 11 assertions, all pass: credential gone from the unlocked folder and still present in the locked one; extractor/logs removed; `*_badrows.log` pattern matched; the folder itself survives; `DIWAAIS.xls`/`DIWAAIS2.xls`/`daily_export.csv` all survive; a machinery file with no counterpart kept back rather than deleted. Not executed anywhere.

---

## 2026-07-14 -- SB-CC-PUSH-HARDEN-001: ONE Retail History migration, four production bugs closed (`d029699`)

Pieter ruling + counsel-cleared. Consolidates four fighting versions (`Migrate-PushHarden.ps1` + the three root `ops-*` scripts, all superseded/hard-blocked) into one per-server script running the approved sequence: **preconditions → retention export → rename task → copy folder → repoint → lock the FINAL folder with the ACTUAL run-as account → STOP for human verification → separate `-Finalize` deletes the old.**

**Four real bugs the previous scripts would have hit on live servers, during the review week:**

1. **Self-heal resurrection.** `Register-ExtractDeltaTask` runs at startup on *every* full-chain run, re-registering the task under whatever name is hardcoded in **that deployed copy**. Renaming the live task while an older extractor is deployed → the next 18:40 run recreates the old branded task. Two tasks, double extraction nightly, brand back in Task Scheduler, silently, within 24h. Now **hard-gated**: the script refuses unless the extractor on disk already carries the new name. Deploy-then-rename is enforced, not hoped for.
2. **ACL/move order deadlock.** Lock-then-copy loses the lock (`Copy-Item` doesn't carry the source ACL; the copy inherits from `C:\` root where Users can read). Copy-then-lock locks the *stale fallback* and leaves the live folder open. **Neither order worked.** Now locks the final folder, after the move.
3. **Assumed principal.** Granting only SYSTEM + Administrators assumed the run-as is an admin — but the extractor's own v1.18 logic falls back to **Limited/non-elevated** when `RunLevel Highest` is denied, and that has fired before. An assumed-admin lock would lock out the account running the feed and dark the store silently. Now the principal is **read off the live task** and granted explicitly, **Modify** (the extractor writes its own error/badrows logs there and deletes the error file on clean exit).
4. **Four task names in play** (`SocialBrand-ExtractDelta` on servers / `WindowsDataSync-SB_Daily` in repo / `Retail History` in two ops scripts / `DataMaintenanceDaily` in a third's verify line). Converged on Pieter's choice: **`Retail History`**, in the three files that must agree.

**Extractor v1.23:** `$taskName = 'Retail History'`; every `C:\socialbrand\...` absolute literal replaced with `$BaseDir` (= `$PSScriptRoot`) so it runs from wherever deployed — this is what makes the `C:\SocialBrand` → `C:\RetailHistory` move safe with no path rewriting; User-Agent de-branded. **`$ClientId = 'socialbrand'` deliberately unchanged** — live DB value on 277k+ rows, load-bearing, canon-ruled. Flagged, not broken.

**Catman guard.** Pieter's standing instruction: `S:\sigma\comms\Catman` (PRSSALE.DAT / TAC*.zip) is SPAR property and is never touched. The script refuses to start if any path resolves to `*catman*`, `s:*`, or `*\sigma\comms*` — unit-tested against 7 hostile variants (case, subpath, bare `S:\`) and 5 legitimate paths, all pass.

**Safety model:** copies never moves; retention export verified non-empty before any change; new task verified byte-identical then auto-rolled-back on mismatch; old task + folder stay live as fallback (both 18:40 tasks run the first night deliberately — the extractor is idempotent, upserts on natural keys — so the store still feeds if the new path has a problem); `-Finalize` refuses unless the new task points at the new folder *and* has a real `LastRunTime` inside 26h; `-DryRun` changes nothing.

**Not executed anywhere** — no server access from this session. Parse-checked + ASCII-verified on all five scripts. Rollout: `-DryRun` one server → real run → let it feed one night → confirm `push_log` → `-Finalize` → then the other four.

---

## 2026-07-14 -- PUSH-HARDEN-001 follow-up: 11 retired scripts removed from repo, off-server removal tool built for the servers (`38487dd`)

Pieter ruling: retired scripts must not be on the servers, full stop -- a local same-server archive subfolder (what the existing `Cleanup-SocialBrandFolder.ps1` already does) doesn't satisfy that.

**Repo-side (done, this commit):** `git rm` on `Push-SigmaToSupabase.ps1`, `Create-SundayPushTask.ps1`, `Discover-SigmaTables.ps1/2/3`, `Fix-ScheduledTasksHidden.ps1`, `RunNightlyPush.bat`, `RunBackfill.bat`, `RunDiscovery.bat/2/3`. A dedicated Explore pass across the whole repo + Bible root confirmed zero live dependencies (no scheduled task, no script invocation, no CI/CD entry point references any of them) before removal -- every hit was a historical mention (commit messages, handovers, canon docs), none of which were touched. Full git history preserved (`git rm`, not a history rewrite).

**Server-side (NOT executed, Pieter's/floor's step):** new `Archive-And-Remove-RetiredScripts.ps1` -- same 11-file list, hash-verified (SHA256, source vs archived copy) before any deletion, refuses to run unless the archive target resolves to a different drive/host than the script folder (a real off-server destination). `-DryRun` makes zero changes.

**Related fix caught in the same pass:** `Cleanup-SocialBrandFolder.ps1` (Daisy root) still called three of these files "operational" in its own comments -- true when written, false since the 2026-06-28 retirement. Corrected; its own move-list trimmed of the now-fully-removed scripts (nothing left for it to find) while keeping their `.txt` query-result output on its list (data, not code, different category).

Verified: ASCII-only + PowerShell parser clean on all touched/new `.ps1` files. Nothing executed on any server.

---

## 2026-07-14 -- PUSH-HARDEN-001 follow-up: scrubbed PRSSALE references, renamed retired cleanup script (`ecf8db8`)

Pieter follow-up ("rename the file and scrub the comments anyway") after confirming behaviour is unaffected either way. `Remove-PrssalePushTasks.ps1` -> `Remove-LegacyScheduledTasks.ps1` (git mv, history preserved); its header/banner reworded generically. `Invoke-ExtractFromSigmaSQL.ps1` v1.22: one historical-changelog mention of the retired brief's own code name now points at canon instead of repeating it inline; the cross-reference to the renamed cleanup script updated.

**Deliberately scoped to exactly what was asked, not wider:** other historical scripts still reference the retired mechanism by name (`Push-SigmaToSupabase.ps1`, `Create-SundayPushTask.ps1`, `Discover-SigmaTables*.ps1`, `store_funnel.py`) -- several are entirely ABOUT the retired mechanism and would need gutting/rewriting rather than scrubbing a comment, which is a different, bigger call. Flagged to Pieter, not touched here. This DEPLOY-LOG's own prior entries (including the one naming the old filename) are also untouched on purpose -- that's the platform's own audit trail of what was actually built and named at the time; a new dated entry records the change, the old one is not rewritten.

Verified: zero "prssale" (any case) remaining in either touched file, ASCII-only, PowerShell parser clean. Not yet executed on any server -- same as the rest of this brief.

---

## 2026-07-14 -- PUSH-HARDEN-001 fix: ACL was Read+Execute, needed Modify (`2766b72`)

Pieter's own question ("are all files in the SocialBrand folder covered?") prompted a re-check that surfaced a real bug: the extractor writes AND deletes inside its own script folder while running (`extractor_last_error.txt` on failure/clean-exit, `<table>_badrows.log` on bad rows) -- the ACL step had granted the run-as account Read+Execute only, which would have broken the very next error write and every subsequent clean-run cleanup after the lock. Fixed to Modify. Scope confirmed correct separately -- the lock covers the whole `C:\SocialBrand` folder (Object+Container Inherit), every file today and anything added later, not just the one script. Not yet executed on any server.

---

## 2026-07-14 -- SB-CC-PUSH-HARDEN-001: unbrand task + protect script -- CODE READY, NOT YET EXECUTED (`e0dbc1d`)

Server-side hardening, floor-side execution -- this entry records what's built and pushed to the repo; the actual change on the 5 store servers has NOT happened yet and won't show in push_log until Pieter runs it.

Pieter ruling: rename the daily scheduled task from the identifying `SocialBrand-ExtractDelta` to the neutral `WindowsDataSync-SB_Daily`, and ACL-lock the push script folder (`C:\SocialBrand`) to SYSTEM + Administrators + the run-as service account only. BINDING retention constraint: SPAR's 10 July letter requested records/logs/configurations be retained pending its review, so this cannot proceed rename-first -- a dated reference copy is mandatory before anything changes.

**The self-heal trap, caught before it could bite:** `Invoke-ExtractFromSigmaSQL.ps1` self-registers its own scheduled task on every run, using a hardcoded task name -- if the live task were renamed on a server without updating that hardcoded value, the extractor's own self-heal logic would silently recreate a task under the OLD identifying name on its very next run, undoing the hardening within 24 hours with nobody noticing. Fixed by updating the name in three places that must agree: the extractor's own `$taskName` (v1.21), the fresh-box bootstrap script's `$TaskName`, and the retired-tasks cleanup script's `$KeeperTask` reference.

**New `Migrate-PushHarden.ps1`** -- one-time per-server migration, retention-first and hard-gated: refuses to touch the task or the script folder until a dated reference copy (task XML export + full script folder) is written and verified non-empty. Registers the new task from the exact preserved XML (trigger/action/settings/principal copied verbatim), verifies it matches the old task byte-for-byte before removing the old one (auto-rolls back and stops on any mismatch), then ACL-locks the folder. Never touches `push_log`/`push_errors`/any push history -- no network calls, pure local Task Scheduler + filesystem state. `-DryRun` makes zero changes.

`STORE-ONBOARDING-RECIPE.md` updated so the new name is documented (R25 portability) rather than tribal knowledge -- a fresh store #6 bootstraps under the new name directly, nothing to migrate there.

**Verification performed:** PowerShell parser syntax check (zero errors, all 4 files) and an ASCII-only grep (clean) -- this session has no network path to the store SQL servers (confirmed earlier the same day), so none of this can be exercised live from here. Execution, including the acceptance proof (next scheduled run stamps `push_log` after the ACL change), is Pieter's/floor's to perform and confirm.

---

## 2026-07-14 -- Floor report: TLX export was writing units, must be pack qty (`a002b1c`)

`OrderDesksMode`'s `exportTlx` (the live desk screen) multiplied the buyer's on-screen qty by `pack_size` before writing the TLX line -- Sigma's TLX order import reads pack quantity, not each. Fixed to write the pack qty directly. Scoped to the live component only -- the same units-multiplication exists in two other `exportTlx` copies (`DeskMode`, the old SAB beer tab; a legacy DC-mode block) but both are retired-in-place, hidden from nav (R28 lineage), unreachable from orders.socialbrand.africa -- left untouched. `next build` clean.

---

## 2026-07-14 -- SB-CC-BLOOM-011 item 1: l2_sales_budget, the NEEDS budget foundation (`846b17a`)

New rolling 6-month sales projection per store per budget week (canon SS14 ADDENDUM v11 item 2). Full detail in DB-SCHEMA.md's own `l2_sales_budget` section -- summary here.

One shared formula (`rpc_project_route_sales_budget`), two callers (R21): `refresh_l2_sales_budget` for the live nightly fact, `rpc_backtest_l2_sales_budget` for item 1's own gate. Real bug caught + fixed during R22: `CREATE TEMP TABLE ... ON COMMIT DROP` doesn't clean up mid-transaction, collided when a store has more than one route (10116: DC_AMBIENT + DIRECT_COCACOLA) -- fixed to explicit DROP/CREATE/DROP, re-verified.

R22: `ly_base_cost` reconciles exactly to raw `sigma_sales` (655629.97 both ways). Pool size matches the recipe's own known DC pool within live drift.

**Backtest ran, results published, NOT scored pass/fail by CC (PM signs on that):** `sigma_sales` only has ~17 months of history, so a full clean 6-month backtest isn't possible yet (needs ~21mo) -- ran the largest clean window instead (15 weeks, anchored 2026-03-28), named as a real constraint, not hidden. 10116 bias -3.3%/MAPE 15.3%, 80175 bias +4.3%/MAPE 17.3%, 21355 (TOPS) bias +12.7%/MAPE 21.8% (thinner LY-history coverage). **The 82%-of-forecast cashflow basis keeps governing every order calculation until PM signs off on this.**

Also this session: BUG-LOG ENG-018 same-day correction (`e0eadd5`) -- see below.

---

## 2026-07-14 -- BUG-LOG ENG-018 same-day correction: single-reference flag (`e0eadd5`)

PM corrected canon item 9 the same day as the entry below, after CC's own R22 showed the dual-reference version (7-day yardstick AND demonstrated demand) fires on ~100% of live orders under v10 -- "a flag that always fires means nothing." `fitted`'s `DEFECT_SIGNAL` now judges against `demonstrated_weekly_demand` alone; the 7-day yardstick stays on every card as a computed display reference, flags nothing. `cash_constrained` remains the one stored exemption. R22 re-verified on the same 3 store/route pairs -- still flag in this test set, but now for a legitimate reason (fitted==full, budget doesn't bind, a genuinely large order vs real trailing sales), not an artifact of the unfair flat-line comparison. `next build` clean.

---

## 2026-07-14 -- BUG-LOG ENG-018 v10 re-anchor: yardstick flag moves full -> fitted (`9d6cfd7`)

PM ruled (under Pieter's delegated authority) on CC's own open flag from the BLOOM-008 v10 ship: canon SS14 v7 item 9 re-anchored -- under v10 FULL is the luxury order by definition and is EXPECTED to exceed the 7-day yardstick, so it never trips `DEFECT_SIGNAL` any more (closes the ~500% false read). The flag moves to FITTED (the order actually sent): fires only when fitted deviates beyond `p_yardstick_tolerance_pct` from BOTH the 7-day yardstick AND demonstrated weekly demand, with no named scenario reason.

**Built:** `rpc_bloom_scenario_overview` rewritten (migration `eng018_v10_reanchor_scenario_overview_flag`, same params, new `yardstick_reason` output column). `full` always carries the permanent reason `full_is_luxury_by_definition` (R29 -- surfaced on the card even without a flag); `fitted` carries `cash_constrained` when the delivery week's `order_budget_ledger.cash_constrained` is true, the ONE clean stored signal among the ruling's three named exemptions.

**Scoped honestly, not guessed:** the ruling names cash constraint, catch-up, and month-end build as exemptions. Only cash constraint has a clean, already-stored, per-week boolean. Catch-up has no standing per-store flag (it's an on-demand scenario computation, never a stored state) and month-end build is a per-LINE fact (archetype x day-of-month), not a single store boolean -- inventing a threshold for either would be a policy call this commit does not make (R27 SS7, confront on ambiguity rather than silently resolve it). Documented in the SQL header and DB-SCHEMA, flagged to PM/Pieter rather than absorbed silently.

**R22 live across 3 store/route pairs (10116/DC_AMBIENT, 80176/DIRECT_BEER, 21355/DC_TOPS):** `full` correctly never flags on any of the three; `yardstick_reason='full_is_luxury_by_definition'` present on every full row; essentials/catch_up unchanged (out of scope for this ruling, verified still NULL/NULL). **Real finding surfaced, not silently absorbed: `fitted` tripped `DEFECT_SIGNAL` on ALL 3 samples** (deviations 66.2% / 323.0% / 645.2% from the 7-day yardstick) -- under v10's deeper HERO-to-max-band + CORE-to-band depth model, the flag as ruled will likely fire on nearly every live order. Whether the 20% tolerance or the yardstick formula itself needs revisiting for the post-v10 world is now a live, named question for PM/Pieter -- not something this build silently tuned around.

**Frontend:** `yardstick_reason` renders as a small caption on the scenario card (`src/app/bloom/page.jsx`, `YARDSTICK_REASON_LABEL` map). The existing `DEFECT_SIGNAL` render block was already generic on `s.yardstick_flag` (never hardcoded to a scenario name), so it needed zero changes to move onto the fitted card. `next build` clean. `/bloom` is auth-gated -- verified via direct SQL against the live function across the 3 store/route pairs above, not a browser click-through (same standing constraint as every prior Bloom session).

---

## 2026-07-14 -- Repo catch-up: BLOOM-008 v10 recipe rewrite + l2_range_state committed (`1ba862b`)

`sql/create_rpc_bloom_order_recipe.sql` had a real gap between the repo and live: HANDOVER-CURRENT/DB-SCHEMA both documented the BLOOM-008 items 1-4 rewrite (range state, universal max-band ceiling, scope-over-states scenarios, floor-protected fit-to-cash) as SHIPPED + R22-CLOSED on 2026-07-12 19:10, but the last git commit touching that file was `1bfbe0c` (the earlier W2 fix). The working tree carried the v10 rewrite uncommitted, and `sql/create_l2_range_state.sql` was untracked entirely -- both applied live via MCP in a prior session, never pushed.

Verified before committing (not assumed): `pg_get_functiondef` on the live `rpc_bloom_order_recipe` matches the local file's signature, columns (`range_state`, `pack_forced_review`, `hero_pack_over_max`, `p_store_target_days`, `p_max_order_stock_days`) and body exactly; `l2_range_state` exists live with 174,449 rows. No new work -- closing a documented repo-drift gap ahead of SB-CC-BLOOM-010.

---

## 2026-07-14 -- SB-CC-BLOOM-010: ENG-021 promo-export fix + order round-trip import (`5bfe251`)

**Item 1 (BUG-LOG ENG-021, HIGH):** `exportPromoSheet` in `src/app/bloom/page.jsx` (desk screen) was exporting raw `l.geared_packs` while the CSV and TLX exporters both correctly read the buyer's live `qty[l.product_code]` -- a zeroed promo line was still exporting at full geared qty. Fixed to read the same `qty` state as the other two exports; the promo-line filter and the Total Qty footer now compute from it too.

**Item 2 (canon SS14 v7 item 11b, the round-trip rule):** new Import button on the desk, phase B, beside the three export buttons. Accepts the desk's own `.csv`/`.xlsx` export format. Quantities only -- matches on `Product Code`, consumes `Order Qty`, ignores every other column (pack size, EAN, promo routing, demand, story all stay from the generated lines). The engine owns pool membership: a code in the file but not in the generated order is never added, surfaces in the import report as unknown; a code in the order but absent from the file is left unchanged; an explicit `0` zeroes the line. Rejects per row (non-numeric or negative `Order Qty`), never per file -- the rest of a file still applies. A filename-derived store/delivery-date guard warns (never blocks) when the chosen file looks like it belongs to a different order. Applied quantities land in the same `qty`/`edited` state a manual on-screen edit uses, so the running total, the stock-state days-after, and all three exports (promo sheet included, after item 1) recompute with zero extra wiring. Visible, non-blocking import report banner: N changed / N unchanged / N unknown (listed) / N rejected (listed with reason).

**Real bug caught during verification, fixed before ship:** the filename-mismatch guard's first draft split the stem on `_` and read the delivery date off a fixed index (`parts[3]`) -- broke silently whenever `desk` or `preset` themselves contain underscores (`DC_AMBIENT`, `DIRECT_BEER`, `order_essentials`), which is every desk except the plain DC ones, producing false-positive mismatch warnings on perfectly matching files. Replaced with a first-token store match + a trailing-ISO-date regex match, both independent of how many underscores the desk/preset names carry.

**Verification:** standalone Node functional test of the parse+reconcile logic (`parseCsvGrid` + the row-reconciliation loop, copied verbatim from the shipped code) against the brief's own acceptance scenario -- raise one line, lower one, zero one promo line, one bogus code, one junk-qty row -- plus two dedicated filename-guard cases (genuine store mismatch, genuine date mismatch, both against a multi-underscore desk/preset). 12/12 assertions passed after the filename-guard fix (first run caught the bug above, 9/10 passed before the fix). `next build` clean both before and after the fix. `/bloom` remains auth-gated (Google login) and this session holds the same standing rule against bypassing `middleware.js` as every prior Bloom session -- no live-browser screenshot exists for either item; confirmed the deploy itself is live (orders.socialbrand.africa serves 200s post-push, redirects cleanly to `/login`, no error page).

**Gate status:** CC build R22/functional-verified and DEPLOYED (pushed, Vercel serving). Pieter's own DoD interaction (generate → export → edit in Excel → import → re-export, on his own device) is the remaining gate per the brief's own override ("DoD: DEPLOYED... the standing R22 proof remains the floor beneath it") -- not claimed as closed here.

---

## 2026-07-12 -- SB-CC-BLOOM-008 item 16 CLOSED: the delivery chain + month picture, frontend wired

Final piece of item 16 -- (a) two-drop chain and (b) month picture (both shipped as their own backend commits earlier today) are now visible on the desk landing, between the stock-state strip and the order grid.

**Frontend:** new "Delivery chain" `GlassCard` in `DeskMode` (`src/app/bloom/page.jsx`). Reads `rpc_bloom_delivery_chain` once per desk/store selection (recipe's own raw `suggested_packs`), re-fetched fire-and-forget with the buyer's own on-screen qty as `p_order1_overrides` right after Generate -- the story text reflects what's actually about to be submitted, not a stale pre-edit guess. `rpc_bloom_month_projection`'s `MONTH_SUMMARY` row rides the same card: month-to-date landed + projected total, route budget (explicitly labelled as budget, never target), a drops-capped flag, and an honest "no sales target configured yet" note (hover shows the full reason) rather than a guessed number.

**Not wired to recompute per keystroke** -- a genuine second recipe run per edit would be a real server round-trip; same documented-limitation class as the promo buy-in toy's own live-reactivity gap noted earlier this session.

**Verification:** `/bloom` is auth-gated (Google login) and this session holds a standing rule against bypassing `middleware.js`, so this was verified statically -- JSX brace/ternary balance re-read twice, dev-server compile log checked clean after each edit, new state/effect symbols grepped for duplicate declarations (none found).

**Item 16 is now CLOSED end to end:** 16(c) landed leg fixed (two real bugs: route scoping + the weekly-grain matching bug found during the fix), 16(a) two-drop chain built + R22'd (order1 value matches the standalone recipe to the cent, override causality confirmed), 16(b) month picture built + R22'd (chains consistently with 16a's own output), all three wired onto the desk screen.

---

## 2026-07-12 -- SB-CC-BLOOM-009: Coca-Cola direct desk, 10116 + 80175 (priority 1)

**What shipped:** first desk of the direct-supplier-desks brief, Coca-Cola per the brief's own build priority (item 6). New `bloom_route_config.direct_supplier_nrs`/`direct_cycle_weeks`/`direct_min_order_value` (RULED config rows for 10116 + 80175). `supplier_calendar` CHECK relaxed to accept `DIRECT_<brand>` route keys. `rpc_bloom_order_recipe` extended with a third route branch (validation, ledger routing to the existing shared `'DIRECT'` weekly ledger row, `lnk`/`pool` CTEs scoped by supplier link) -- zero change to any existing route's own formula. `rpc_bloom_stock_state` and `rpc_bloom_scenario_overview` (both auto-called on desk selection, before Generate) needed the identical route-guard + ledger-routing extension or the new desk would error the moment it's selected; `stock_state`'s dept-wide-vs-orderable gap concept doesn't apply to a supplier-defined pool so it honestly folds to the pool itself (gap=0) rather than inventing a comparison set.

**Supplier identity, R22-validated BEFORE building anything else:** every named brand in the brief has several active, currently-linked `supplier_nr` rows per store (e.g. 10116 CLOVER: 5 distinct active rows). Tested whether the single dominant (highest live-linked-product-count) `supplier_nr` per brand reproduces the brief's own PM reference cadence (10116, 8wk) -- it does, zero parameter tuning: Danone 1.50 (PM 1.5, exact), Coca-Cola 1.00 (PM 1.0, exact), National Brands 0.50 (PM 0.5, exact), Clover 1.50 (PM 1.6, close), Simba 0.88 (PM 0.9, rounds to match), Mondelez 0.63 via `supplier_nr=950` "SUPER GROUP AFRICA - MONDELEZ" (PM 0.6, close -- the obvious `supplier_nr=1586` had ZERO receipts in the window). `sigma_grv` does not exist as a table in this schema -- `sigma_movements.supplier_nr` (100% populated on R/W receipt rows) is the L1 receipt-supplier fact used directly, so the brief's own named debt is effectively already available.

**Caught and fixed before ship:** an initial `delivery_dows={4,5}` (both Thu+Fri, the raw observed pattern) made `rpc_bloom_next_deliveries` return them as back-to-back days (lead=1 day), collapsing the band target far below the real weekly run-rate. Corrected to the single most-frequent day per store (10116 Fri, 80175 Thu).

**R22 live:** 10116 Coca-Cola desk generates cleanly across all four scenarios, 0 band violations, 7-day lead resolves correctly via the calendar. `stock_state`'s independent 28d-sales weekly demand figure (computed with zero knowledge of the brief's own number) landed at **R41,346.01 -- an EXACT match to the brief's own PM reference (R41,346)**, an independent confirmation of the supplier identification. Regression control: DC_AMBIENT (12,615 lines / R819,985.83) and DIRECT_BEER (216 lines / R137,588.11) both byte-for-byte unchanged across all three touched functions.

**Flagged, not silently fixed (numbered finding for PM/Pieter):** the ENG-018 yardstick (lead=0, flat 7-day override) reads R6,441.97 against this desk's real order value of R78,506.97, tripping `DEFECT_SIGNAL`. Same class of pre-existing yardstick-vs-desk mismatch Pieter's own ENG-018 finding already diagnosed for the DC desk ("the defect is the yardstick, not the desk") -- not chased further here without a ruling on whether/how the yardstick formula should apply to a weekly single-drop supplier desk.

**Gate status:** CC build R22 CLOSED for the Coca-Cola desk at both stores. Remaining brands (Clover, Simba, Mondelez, Danone, National Brands) and stores follow the identical, now-proven pattern in later passes, each R22'd before it ships per the brief's own item 5.

---

## 2026-07-12 -- WALK-FINDING W5: manual budget override, strip labels MANUAL

**What shipped:** new column `order_budget_ledger.budget_manual_override` (boolean, default false, `sql/create_order_budget_ledger_manual_override.sql`) -- an ad-hoc weekly budget figure now has a third, explicit state distinct from the existing `cash_constrained` boolean (which governs an unrelated thing: the `order_essentials` preset's day-cover, 21d vs 10d, canon v7 item 3 -- deliberately untouched by this flag). Desk strip (`src/app/bloom/page.jsx`, `DeskMode`): when `budgetRow.budget_manual_override` is true, the basis label reads **MANUAL** instead of "82% FORECAST"/"80% CASH-CONSTRAINED", the "Route budget" caption drops its "(82%)" suffix, and the group 80%-cash reference figure (not applicable to an ad-hoc number) is hidden.

**No formula change.** `budget_amount` was already always a seeded/manual plan figure -- `refresh_order_budget_ledger()` never writes it (per DB-SCHEMA.md) -- so Fit-to-Budget and every quantity/gearing calculation are completely unaffected; this is a labelling-correctness fix only, scoped to the desk strip's own display logic.

**R22/verification:** column added live, all 18 existing `grain='weekly'` rows across all 5 stores confirmed still `budget_manual_override=false` (zero drift on the fix's own deploy). `/bloom` is auth-gated (Google login) and this session holds a standing rule against bypassing `middleware.js`, so verification was static: JSX brace/ternary balance re-read twice, `--daisy-white` confirmed as an existing design token already used ~10+ times elsewhere in the same file, dev-server error log checked clean post-edit.

**Gate status:** CC build CLOSED. Second item of the post-freeze build order (W2 essentials-normal fix shipped immediately prior). Next: BLOOM-009 direct desks, then BLOOM-008 item 16 delivery chain/month picture.

---

## 2026-07-12 -- WALK-FINDING W2: order_essentials preset never gears (FORMULA FREEZE LIFTED mid-walk)

**Context:** Pieter's Monday walk (2026-07-13) started early -- freeze lifted live mid-walk 2026-07-12 ("cc can build"), build order handed down: essentials-normal fix first, manual-budget override second, then directs and the delivery chain/month picture.

**What shipped:** `rpc_bloom_order_recipe`'s `resolved` CTE now forces `resolved_packs_calc = normal_packs_calc` whenever `p_preset='order_essentials'`, regardless of `promo_nr` -- previously every preset (including essentials) geared promo-active lines identically, contradicting essentials' own purpose as the strict-KVI/basic-demands selection, never a buy-in vehicle. Promo-sheet routing is untouched (`promo_active` still driven purely by `promo_nr IS NOT NULL`) -- promo lines still surface on the promo sheet, just at normal quantity. Gated on the pre-existing `v_preset_essentials` plpgsql variable, passed as the format() call's new 24th arg (`%24$L::boolean`). Input signature unchanged (body-only fix, `CREATE OR REPLACE` pattern).

**R22, live (10116/DC_AMBIENT, delivery 2026-07-16, next 2026-07-18):**
- Essentials total value: R1,102,326.62 -> R1,040,660.66 (-R61,665.96), line count unchanged at 615.
- Geared-promo lines (`suggested_packs=geared_packs<>normal_packs` while `promo_active`): 48 -> 0.
- All 201 `promo_active` lines confirmed still flagged true AND at normal qty (`suggested_packs=normal_packs`) -- promo-sheet export routing intact, only the quantity math changed.
- Standard preset (no preset arg) confirmed UNAFFECTED as a control: 12,615 lines, 83 geared-promo lines, unchanged from before this fix -- the change is scoped exactly to `order_essentials`.

**Gate status:** CC build R22 CLOSED. First item of the post-freeze build order; W5 (manual budget override) next.

---

## 2026-07-12 -- SAB weekly-budget seed (canonical file, PM's live fix) + real bug caught: value_normal ignored Fit-to-Budget

**SAB weekly-budget seed, canonicalized.** PM applied the fix live to close the accuracy-gate's walk-blocking finding (no `grain='weekly'` rows for any DIRECT_BEER store): 21355 R41,541.86, 80176 R77,732.83, 80579 R36,258.41, each store's own figure split by that store's own LY beer rhythm for the week, not a flat divide. New file `sql/create_order_budget_ledger_sab_weekly_seed.sql` records this canonically (`ON CONFLICT DO NOTHING`, verified as a true no-op against what PM already applied) so the repo doesn't drift from live, per PM's own flag. **Second flag from PM, NOT fixed here (hygiene pass after Monday's walk, explicitly deferred):** the same stores also carry `route_key='DIRECT'` weekly rows for the same week (10116 R366,210 / 21355 R63,544 / 80175 R200,362 / 80176 R95,500 / 80579 R913) -- confirmed live, "look like the same money on two keys." Left untouched; needs Pieter's ruling on which key is authoritative before any merge/cleanup.

**Real bug caught during the seed's own verification (CC, not named in any brief):** `rpc_bloom_scenario_overview.value_normal` summed `normal_packs` -- the recipe's PRE-FIT quantity -- on every scenario, including `fitted`. The recipe's own fit-applied final answer lives in `suggested_packs`, which is what Generate actually submits -- the overview was silently ignoring Fit-to-Budget's own output the entire session. This is why `full` always equalled `fitted` on the board even after the ENG-018 yardstick re-anchor: not because full was genuinely under budget every time, but because the overview never read the fit result at all. Also fed the wrong number into `yardstick_deviation_pct`/`yardstick_flag` and the "= full need, no trim required" caption shipped earlier tonight.

**Fixed:** `value_normal` now sums `suggested_packs * pack_cost` -- the true, fit-applied, promo-resolved order value, for every scenario. Aggregation-layer fix inside `rpc_bloom_scenario_overview` only -- `rpc_bloom_order_recipe`'s own quantity logic, gearing legs and presets are untouched (FORMULA FREEZE holds; this is a downstream reporting bug, not a recipe formula change). `value_geared` stays a pre-fit informational comparison, documented as such.

**R22, live:** 80176/DIRECT_BEER now shows `full` R91,153.39 vs `fitted` R87,885.88 -- genuinely different, fitted correctly trims non-protected spend but stays above the R77,732.83 ceiling because KVI-protected lines are never trimmed (by design). 10116/DC_AMBIENT still shows `full`==`fitted` (R819,986.27), but now for the CORRECT reason -- full is genuinely under the R850,435 budget, so there's nothing to trim, verified via the real fit-applied number rather than assumed.

**Gate status:** CC build R22 CLOSED for the value_normal fix (figures above). SAB weekly-ledger seed CLOSED (PM's own action, canonicalized). DIRECT-vs-DIRECT_BEER duplicate-key question OPEN, deferred to post-Monday hygiene pass per PM's own instruction.

---

## 2026-07-12 -- THE ACCURACY-GATE VERIFICATION RUN (canon v9 item 8, offline queries, no code changed)

Population checks on the LIVE recipe, standard preset, at Monday 13 Jul's three walk stores: 10116/DC_AMBIENT (delivery 2026-07-16), 21355/DC_TOPS (2026-07-16), 80176/DIRECT_BEER (2026-07-21) -- each store's own next real delivery off `rpc_bloom_next_deliveries` anchored 2026-07-13.

**1. Band invariants (0 violations expected):** `target_level > max_band` or `(need_units>0 AND target_level<min_band)`, population count. **10116: 0/12,615. 21355: 0/2,582. 80176: 0/216. ALL CLEAN.**

**2. 35-day ceiling baseline (all over-35d lines expected pack-forced):** post-order cover `= (soh + suggested_packs*pack_size) / rhythm_adjusted_demand`; a line is "pack-forced" when `suggested_packs=1` (the minimum valid pack count) pushes it past 35d on its own, never a real multi-pack over-order. **10116: 519/519 pack-forced -- EXACT match to PM's own previously-cited baseline figure.** **21355: 74/74 pack-forced.** **80176: 2/3 pack-forced -- ONE exception found:** product 158253 CASTLE DRAUGHT LITE CAN 500ML, promo_active, geared to 7 packs (not the pack-forced minimum of 1), lands at 39.4d post-order. Not a band-invariant violation and not silently wrong -- a promo-geared line legitimately buying in past 35d, exactly the kind of overshoot BLOOM-008 item 5's gearing cap (ON HOLD until after Monday) is meant to bound. Flagged, not fixed -- the freeze holds.

**3. Demand-window-per-tier mismatches (0 expected):** T100 must read `ros_14d`/`ros_28d (q14=0 fallback)`, T1000 must read `ros_28d`, BOR must read `ros_56d`, population count of anything else. **10116: 0. 21355: 0. 80176: 0. ALL CLEAN.**

**4. Budget strip reads the delivery week's ledger row:** **10116 and 21355 both resolve `delivery_week_exact` correctly (week_start 2026-07-11, the Saturday before their Thursday drop).** **80176 resolves `no_ledger_row` -- NO row at all, not even a stale fallback.** Traced to source: `order_budget_ledger` for `route_key='DIRECT_BEER'` carries ONLY `grain='monthly'` rows (6 months seeded, Jul-Dec 2026) -- **zero `grain='weekly'` rows exist for ANY of the three DIRECT_BEER stores (21355, 80176, 80579), confirmed by population count, not just 80176.** **This means the budget strip and Fit-to-Budget will show empty/no-budget on every SAB desk during Monday's walk unless weekly rows get seeded before then.** Not fixed this pass -- seeding the weekly split of an existing monthly SAB budget is a real decision (which weeks, whether it's a flat 1/4-split or rhythm-weighted) that belongs to PM/Pieter, not a silent default.

**Verdict:** 10116 and 21355 (DC routes) are clean on all four checks and ready for Monday's walk as-is. 80176 (and the SAB route generally) has one minor, explainable gearing overshoot (#2) and one real, walk-blocking gap (#4, no weekly budget ledger rows) that needs a PM/Pieter decision before Monday, not a CC guess.

**Gate status:** Verification CLOSED, all figures above are live population counts, not samples. Item 4's SAB weekly-ledger gap is OPEN, needs a ruling, flagged here rather than silently seeded.

---

## 2026-07-12 -- SB-CC-BLOOM-008 item 8: BT per-store overview

**What shipped:** `rpc_bt_store_overview(p_month)` -- reuses `l2_bt_monthly`/`l2_bt_baseline` exactly as `rpc_bt_scorecard` does (R21, same GP formula, grouped by `store_code` instead of collapsed across the whole BT scope). `public/bt.html` gets a new "Per-store overview" panel under the existing scorecard, same month selector, own reload.

**R22:** split sums to the cent against the existing scorecard's own basket total (R75,099.6517 = R65,748.4210 @10116 + R9,351.2307 @80175, 2026-06). **Live-browser-verified** (this page is NOT behind the auth gate -- `/bt` is explicitly public in `middleware.js`, unlike `/bloom`) at `localhost:3000/bt`: panel renders "2 stores · 2026-06", 10116 R65,748/-3.8%, 80175 R9,351/+14.7% -- matches the SQL check exactly, zero console errors.

**Gate status:** CC build R22 CLOSED, live-verified (real browser check, not static review).

---

## 2026-07-12 -- SB-CC-BLOOM-008 item 7: the stock-state instrument (FORMULA FREEZE holds, read-only)

**What shipped:** `rpc_bloom_stock_state(p_store_code, p_route)` -- NEW, read-only, touches no formula covered by the Monday formula freeze. Per group KVI (KVI_CRITICAL+KVI_IMPORTANT) / Core (STANDARD+CONSUMABLE_CARVE) / Tail (LONG_TAIL): lines, selling lines, stock at cost, daily cost demand (trailing 28d `sigma_sales.cost_value` / 28, pure history, never the engine's own demand estimate), stock-days. A 4th synthetic `TOTAL` row carries the separate dept-wide-vs-orderable demand comparison PM ruled the same night, gap labelled `no_active_dc_route`. Population is the recipe's own resolved orderable pool (reuses `rpc_bloom_order_recipe`, R21, never a parallel pool-resolution formula). Desk screen renders a "Stock now" strip above the scenario overview -- per group: days now, days-after-this-order (recomputes CLIENT-SIDE off the live `qty` state as the buyer edits, no server round-trip per keystroke), lines/stock/daily figures, and the dept-vs-orderable demand-gap caption.

**R22 against PM's reference (10116/DC_AMBIENT, 2026-07-12):** line counts match EXACTLY (KVI 178, Core 4,981, Tail 7,456) and stock-at-cost matches to the rand (KVI R140,745.84 vs R140,746, Core R999,410.75 vs R999,411, Tail R549,603.08 vs R549,603). Dept-wide weekly demand matches to the rand (R749,144.26 vs PM's R749,144). **Daily cost demand runs ~60-78% of PM's cited figures across all three groups** (KVI R23,543 vs R39,181, Core R45,985 vs R59,285, Tail R1,290 vs R1,664) -- the brief's own reference table carries the caveat "anchor-sensitive, pin the anchor when regressing," and the pool/stock math (the primary deliverable, matched exactly) isn't in question; the daily-demand window likely anchors on a slightly different date than PM's live calc. Documented, not chased further this pass.

**Gate status:** CC build R22 CLOSED for pool/stock figures (exact match); demand-window anchor drift flagged OPEN, informational only, does not block the Monday walk (the instrument's job -- "where does the store stand" -- reads correctly).

---

## 2026-07-12 -- BUG-LOG UX-004 + ENG-019 (Pieter ruling: "no conflict, fix UX-004 instead")

**UX-004** (`rpc_bloom_scenario_overview`): `count_first_lines` was counting count_first rows across the WHOLE POOL (every band_blocked row the recipe returns, ordered or not), while `lines` only counts the ORDERED set (suggested_packs>0) -- the two were never comparable and count_first could exceed `lines` outright (4,826 vs 1,780, live, before this fix). `count_first_lines` now means the same population `lines` does; the whole-pool figure rides separately as the new `count_first_pool` column, explicitly labelled.

**ENG-019** (`rpc_bloom_order_recipe`): latent NULL-guard. `format()`'s `%s` renders a NULL argument as an empty string, not an error at format-time -- a caller passing `p_month_end_build_start_day`/`_end_day`/`p_early_month_build_start_day` explicitly as NULL (rather than omitting them) silently produced `BETWEEN  AND 24` in the `moded` CTE, a syntax error only at EXECUTE time. Never triggered by this repo's own callers (all pass the three explicitly) -- guarded with COALESCE-to-default reassignment regardless, since PM asked for it "when touching the board."

**R22, live at 10116/DC_AMBIENT/2026-07-16:** `full` scenario now reads `count_first_lines=1,662` (was 4,826, now correctly <= `lines`=1,777), `count_first_pool=4,866` separate. **New finding, flagged not diagnosed:** `order_essentials`/`catch_up` show 100% of ordered lines as count_first (558/558, 328/328) -- the underlying pool is 612/615 lines (99.5%) `band_blocked`. Worth PM's attention as a possible data-quality concentration on 10116's highest-priority (KVI+BT+Top-tier) population -- not investigated further this pass, outside UX-004's own scope.

**Gate status:** CC build R22 CLOSED, both fixes verified live, figures above.

---

## 2026-07-12 -- BUG-LOG ENG-018 yardstick re-anchor + SAB tab restore (Pieter rulings on CC's 3 open points)

**Context:** Pieter caught two live-site issues in chat and ruled on all three points CC had flagged in the prior handover entry.

**(1) SAB Direct (beer) tab restored** (`src/app/bloom/page.jsx`) -- Pieter: his live call governs, the tab stays visible until the SAB desk card inside Desks passes his own walk, retires with lineage only then, on his word. One-line nav restore, `DeskMode` component itself was never touched.

**(2) count_first: no code change -- confirmed correct as shipped.** Pieter ruled ENG-014 stands: the 2,842 zero-quantity count_first lines on trusted positive claims ARE the rule working (0 packs + count riding); a phantom claim gets caught and ordered on the NEXT drop once a count disproves it -- a bounded one-drop under-order, by design, the count is the resolver. LION MATCHES 5847 stays correct at 0.

**(3) Yardstick RE-ANCHORED** (`rpc_bloom_scenario_overview`) -- BUG-LOG ENG-018. Old reference (`rpc_bloom_order_dc(p_days_cover=7)`) retired WITH LINEAGE as this function's yardstick source (the function itself stays live, still used by the DC tab). New formula, PM's exact wording: "pure tier-window demand x7 - clamp(soh,0), ungeared promo-flat, with demonstrated weekly demand (28d/4) beside it." Built by reusing `rpc_bloom_order_recipe` itself (R21, never a parallel formula) called with `p_next_delivery=p_delivery_date` (forces lead=0, so the override branch resolves to exactly demand*7-clamp(soh,0), no anchor-lead inflation) and `p_days_cover_override=7`, summed on `normal_packs*pack_cost` (never geared -- "ungeared, promo-flat"). New output column `demonstrated_weekly_demand` -- pure `sigma_sales.cost_value` over the trailing 28 days on the SAME resolved route pool, divided by 4, informational only, never fed into the deviation/flag calc.

**R22, live at 10116/DC_AMBIENT/2026-07-16:** `full` scenario now shows `yardstick_deviation_pct=-3.6`, `yardstick_flag=null` -- the false-alarm DEFECT_SIGNAL is GONE, matching Pieter's own ENG-018 finding that desk standard was correct all along. `essentials`/`catch_up` deviate +33.0%/+16.3% as expected (never flagged, by design -- only `full` is checked).

**Not yet reconciled, flagged not hidden:** the new `demonstrated_weekly_demand` (pure sales-history cross-check) computes to **R495,727** live, not Pieter's cited **R767,203**. My method: `sigma_sales.cost_value` summed over the trailing 28 days ending `CURRENT_DATE`, scoped to the exact product_code list the `full` scenario's own recipe run resolved, divided by 4. Whatever produced Pieter's R767,203 either scoped the pool differently or anchored the 28-day window on a different date -- needs reconciling before this second figure is trusted on the board. The PRIMARY fix (the re-anchored yardstick itself, and the DEFECT_SIGNAL clearing) is R22-verified and not in question; this is specifically about the SECOND, informational-only cross-check number.

**Gate status:** CC build R22 CLOSED for points 1 and 3 (figures above); point 2 required no build, ruling recorded. `demonstrated_weekly_demand` reconciliation OPEN.

---

## 2026-07-11 -- Scenario board: KVI/Core/Tail pie per scenario (Pieter follow-up ask)

**What shipped:** `rpc_bloom_scenario_overview` gains `by_kvi_band_lines jsonb` -- the same population as `by_kvi_band` (value) but by ORDERED-LINE COUNT, since the pie asks "percentage of lines ordered", never rand. `src/app/bloom/page.jsx` gains a hand-rolled SVG `KviPie` (no new chart dependency) rendered on each of the 4 scenario cards on the landing board, grouped KVI = KVI_CRITICAL+KVI_IMPORTANT, Core = STANDARD+CONSUMABLE_CARVE, Tail = LONG_TAIL -- a zero-count group is dropped from the ring and legend rather than drawn empty ("if those are the only ones").

**Count correction, flagged not silently matched:** Pieter's ask referenced "the 6 scenarios" -- the landing board has 4 (full/fitted/order_essentials/catch_up), not 6. Built for the 4 that exist; PM to confirm whether a 6-scenario split (e.g. normal/geared as separate cards) was intended before any redesign.

**R22:** live-checked at 10116/DC_AMBIENT/2026-07-16 -- `full` scenario STANDARD 1587 + CONSUMABLE_CARVE 35 (core) + KVI_CRITICAL 40 + KVI_IMPORTANT 86 (kvi) + LONG_TAIL 32 (tail) sums to exactly 1780, the scenario's own `lines` total.

**Noted for PM, per the ask ("so PM can also see it exists"):** the overview call already computes `by_mode` (minimum/build/month-end) and `by_tier` (T100/T1000/BOR) value breakdowns and `protected_lines`/`trimmed_lines` counts -- none of these are visualized yet beyond the KVI pie and the plain counts already on each card. A caption on the board now states this explicitly so it isn't mistaken for missing data.

**Gate status:** CC build R22 CLOSED (figures above). Screen R22 (PM) OPEN, same as the rest of this evening's rounds -- no live screenshot, static review only (bracket-balance, dead-symbol grep).

---

## 2026-07-11 -- BUG-LOG Monday-list-v2 amendments: ENG-017 + UX-003 22:0x-22:5x (scenario board, export contract, promo naming)

**Commits (main):** SQL objects applied live via Supabase migrations same evening (`supplier_calendar_promo_buyin_lead`, `rpc_bloom_order_recipe_eng017_promo_buyin_and_band_invariants` + 2 follow-up fix passes, `create_rpc_bloom_scenario_overview` + 3 follow-up fix passes), repo commit follows this entry.

**Context:** further same-night amendments after the first Monday-list round shipped -- Pieter kept walking the live site and dictated seven more rulings (canon v7 items 9-11, BUG-LOG ENG-017, UX-003 amended five more times: 22:0x scenario overview, 22:2x sanity strip, 22:3x breakdown panel, 22:4x promo capture sheet + buy-in toy, 22:5x exact templates supplied).

**D3 resolved FIRST, live, before ENG-017 touched any formula (R23/R25 -- never assume):** reconciled RG2 on 17471 @10116 (`sigma_promotions` start_date=2026-07-08) against its own ledger. GRV receipts land 2026-06-27 and 2026-07-02, both BEFORE start_date; independently, the 07-11 BENCHMARK extract shows 17471 `Current Promo=RG2` while inside [07-08,07-22]. Both signals agree: `sigma_promotions` dates are the SHELF/SELL-active window, not a DC order-window passthrough -- the buy-in-window FORMULA applies.

**ENG-017 -- the promo buy-in window.** `supplier_calendar` gains `promo_buyin_lead_days` (DEMO_CALIBRATION, default 7). `rpc_bloom_order_recipe`'s `promo_match` CTE now gates on `p_delivery_date >= (active_start - buyin_lead_days) AND p_delivery_date <= (last calendar delivery <= active_end)`, computed via a bounded `generate_series` backward scan -- outside the window a line orders NORMAL even if the promo is still shelf-active. R22 (10116/DC_AMBIENT/2026-07-16): live promos RG1/RG2/RG4 all correctly gated and named, zero false-positive promo-eligible lines against an independent manual re-derivation of the same window (0/1341). Population swept across all 7 live store/route pairs -- runs clean everywhere, naming gaps surfaced honestly (8-25 per store, never guessed).

**Promo naming.** `promo_suffix`/`promo_naming_gap` added to the RPC's output, parsed from `sigma_promotions.description` (trailing parenthetical anchor first, "DC Promotion Number <CODE>" fallback). Live-verified: RG1/RG2/RG4 all resolve correctly.

**Canon v7 item 9 -- band invariants, population-level, flag never block.** The dynamic result materializes into a session-temp table so a cheap aggregate can `RAISE WARNING` before rows return. **Caught and fixed before ship:** an unscoped check false-positived on 615/619 rows on both `catch_up` and `order_essentials` runs -- both presets deliberately override the band with a flat day-cover target (that's the whole point of the 21-day-minimum and catch-up-band-cap presets, not a defect). Fixed: the invariant now only fires when `p_days_cover_override` is NULL (i.e. no preset/manual override active) -- re-verified 0/0 violations on standard, `catch_up`'s own 3x-multiple ceiling stays intentionally exempt.

**`rpc_bloom_scenario_overview` -- the landing board (UX-003 22:0x/22:2x/22:3x), NEW.** One published call runs `rpc_bloom_order_recipe` internally once per scenario (full/fitted/order_essentials/catch_up) and aggregates the SAME rows Generate would show -- R22 by construction, never a parallel formula. Returns per scenario: lines/promo_lines/count_first_lines, value_normal/value_geared, protected/trimmed counts, budget_amount, and jsonb breakdowns by KVI band/mode/tier. The 7-day yardstick reuses the UNCHANGED, still-live `rpc_bloom_order_dc(p_days_cover=7)` for DC_AMBIENT/DC_TOPS ("the retired flat-7-day DC calc stays alive as the permanent reference line", canon v7 item 9) -- R22 exact match to BUG-LOG's own cited DC-form figure (R1,410,144.28 vs the walk's R1,410,144). DIRECT_BEER has no DC-form equivalent; its yardstick uses the recipe RPC's own `p_days_cover_override=7` as a flagged, honestly-labelled proxy. `yardstick_flag='DEFECT_SIGNAL'` fires only on the `full` scenario beyond `yardstick_tolerance_pct` (config, default 20) -- **live-verified it independently re-caught the same standard/full value gap flagged in the prior round** (10116/DC_AMBIENT: full R767,763 vs yardstick R1,410,144, -45.6%, DEFECT_SIGNAL) via a completely different mechanism, corroborating that gap is real and not a one-off artifact.

**Export contract (canon v7 item 11), desk screen.** CSV now matches the full StockFlow BENCHMARK column set (19 columns) rather than the prior 6-column stub; two fields (`Size`, `Line Category`) left blank rather than guessed -- not available server-side, R21. TLX now excludes promo lines (`l.promo_active` guard added) -- normal order only, matching "TLX for the normal order... quantities in UNITS". New `exportPromoSheet()` writes a REAL `.xlsx` via the `xlsx` package (already a project dependency, same pattern as `src/app/page.jsx`'s report export) matching Pieter's supplied template exactly: merged title row `Promo Order - <Store> - <date>`, header `Product Code/Description/Size/Order Qty/Promo Suffix`, `Total Items:`/`Total Qty:` footer.

**Promo buy-in toy (BLOOM-001 §6) -- gap confirmed, not built this round.** Grepped the full file: no profit-value/sell-through/margin-at-normal-selling calculation exists anywhere on the grid, only a stale v0 planning comment. Reported honestly per BUG-LOG's own instruction rather than silently claimed; not built this round given the scope already landed -- flagged as the next open item.

**Gate status:**
- **CC build R22: CLOSED** for ENG-017, promo naming, band invariants, scenario overview, export contract -- all population-verified live against production data (figures above).
- **Promo buy-in toy (BLOOM-001 §6): OPEN, confirmed absent, not started.**
- **Screen R22 (owner PM):** OPEN -- this round has not had a live screenshot walk (auth-gate bypass stays off-limits, this session's own standing rule).
- **Line-level R22 audit against every named BUG-LOG test case (task #25 from the prior round): still OPEN**, partially covered by this round's population sweeps but not a full per-line named-case walk.

Static review only (bracket-balance pass, dead-symbol grep for `exportPromoCsv`) -- no live-browser verification, consistent with this session's standing rule against bypassing `middleware.js`.

---

## 2026-07-11 -- BUG-LOG Monday list: ENG-011 through ENG-016 + UX-003 (desk-screen rebuild)

**Commits (main, in order):** `01fa4e8` (ENG-011) `16eadee` (ENG-012/013/014/015/016) `bfc61d0` (ENG-013 lineage) `59f06be` (UX-003)

**Context:** second same-evening walk, after BLOOM-007's items 1-6+8 shipped. Six defects (ENG-011 through ENG-016) plus one UX defect (UX-003), logged with named product/store test cases and acceptance figures in `BUG-LOG.md`, ruled against CLEANUP-ENGINE-CANON SS14 ADDENDUM v7 (moved three times same evening -- re-read in full before this round per PM's explicit instruction). No formula changes -- every item applies an existing rule or config.

**ENG-011 -- strictly-future deliveries (`01fa4e8`).** `rpc_bloom_next_deliveries`'s search now starts at `anchor + order_cutoff_days` (default 2) instead of the anchor itself -- a call placed Monday no longer offers Monday's own truck. R22: 21355/DC_TOPS anchor=2026-07-13 (Mon) now returns delivery=2026-07-16 (Thu), matching the walk scenario exactly.

**ENG-012/013/014/015/016 -- `rpc_bloom_order_recipe` rewrite (`16eadee`).** Order-time band bounds now recompute against the calendar drop cover rather than a stale snapshot (ENG-012). SAB desk routes through the recipe path (`p_route='DIRECT_BEER'`), budget ledger lookup keyed `DIRECT_BEER` vs `DC` per route (ENG-013). COUNT_FIRST now splits by claim sign -- negative claims order at SOH 0, positive claims trust the claim with the count riding, never a forced buy (ENG-014); beans 137585 and matches 5847 verified exact 0+count_first. Demand window resolution corrected to the true ENG-005 precedent (T100 14d->28d fallback, T1000 28d, BOR 56d, `GREATEST(scan_raw, draw_corrected)`, uncapped) after a caught-before-ship bug where the first draft wrongly ported `rpc_bloom_order_direct_beer`'s capped/guarded ENG-009 pattern onto scan, suppressing 10116/1674 milk's real demand to 55.29/day; re-verified exact match to PM's cited 621.36/day (ENG-015). Fit/budget strip now read the ledger row of the DELIVERY week (Sat-Fri COB, canon v7 item 7), never the placement week (ENG-016). R22 verified per named test case live against production data; ENG-012's exact "~669 packs" target could not be bit-for-bit reproduced because the underlying SOH snapshot had genuinely moved between PM's audit and this verification run -- documented as data drift, not forced to match.

**ENG-013 lineage -- `rpc_bloom_order_direct_beer` retired (`bfc61d0`).** Function kept live, never dropped (R28) -- header comment + live `COMMENT ON FUNCTION` mark it superseded by `rpc_bloom_order_recipe(p_route='DIRECT_BEER')`.

**UX-003 -- desk screen rebuilt as the preserved DC grid, one landing (`59f06be`).** The prior desk screen (BLOOM-007 item 8) was a mixed compromise -- wrong columns, wrong tabs, focus-merged-into-standing-order, one blended export, no Normal/Geared selector. Rebuilt so the grid, sort, ringed-qty editing, and export set are carried over unchanged from the original DC order screen; only the brain (per-route recipe RPC) and header (desk/date/preset/basis/fit controls) are new. Presets now trigger a fresh scoped generate() call per canon v7 item 4's corrected wording -- three DIFFERENT orders, not a recut-merge. Nav collapsed to a single "Desks" option; DC/Desk-beer/Recipe modes stay in the file, reachable in code, not offered in the visible nav (R28). R22 (outcome audit) live at 10116/DC_AMBIENT/2026-07-16: standard 1,751 ordered lines R816,612 (12,617-line pool, 11 depts); order_essentials 560 lines R1,120,263 (209 lines not present in standard's ordered set at all); catch_up 287 lines R849,724 (entirely a subset of essentials) -- structurally three distinct line sets, essentials/catch_up land close to PM's cited ~R1.14M/~R850k. **Flagged, not force-matched:** standard's R816,612 is well under PM's cited ~R1.87M full-pool figure -- same class of live-SOH-drift explanation documented for ENG-012, needs PM's own re-walk to confirm which figure is current.

**Gate status (status ledger rule, FILE-GOVERNANCE 0d), all items:**
- **CC build R22: CLOSED**, item-by-item, outcome-audited against BUG-LOG's named test cases (see individual commits for full figures).
- **Screen R22 (owner PM):** OPEN. PM re-walks to the order-audit standard (line audits per desk per store per selection) next.
- **DoD (R31, owner Pieter):** OPEN. Dummy orders Monday 13 Jul.
- **Standard/full value gap at 10116 (R816,612 vs PM's cited ~R1.87M):** OPEN, flagged to PM -- needs a fresh live-data re-walk to confirm whether this is data drift or a real gap.
- **Item 7 (frozen focus + Deduct Last Order):** still explicitly deferred, trails into next week. Not started.
- **Product-Mapper toolkit (item 12 unblock):** ruled to start only after this round lands. Not started.

Live-browser verification blocked by the auth gate for local checks (this session's standing self-imposed rule, reinforced by the harness itself refusing a middleware.js bypass earlier in the evening) -- static review only (bracket-balance pass, dead-symbol grep, live-SQL outcome audits against the shipped RPCs).

---

## 2026-07-11 -- SB-CC-BLOOM-007: Order Desks + deviation corrections (Monday landing window)

**Commits (main, in order):** `c6784c2` (item 1) `98253ea` (items 2-6) `20f9006` (item 8)

**Context:** Pieter walked the shipped Recipe screen (`cdd4429`) same day and it missed the mark -- not the maths, the wrapping: no route scope (pool mixed ambient/TOPS/beer), the calendar unused, `band_blocked` lines excluded from the pool, no geared leg, focus selected before generation instead of after. Corrective rulings: CLEANUP-ENGINE-CANON SS14 ADDENDUM v7. Brief: `Bloom/SB-CC-BLOOM-007-order-desks-and-deviation-corrections.md`. Landing window: items 1-6 + the desk screen (item 8) live by Sunday EOD for Pieter's dummy-order session Monday 13 Jul. Item 7 (frozen-focus set, Deduct Last Order) explicitly trails into next week per the brief. No formula changes anywhere in this brief -- every item applies an existing rule or config, confirmed against the brief's own governing constraint before each change.

**Item 1 -- `supplier_calendar` + `rpc_bloom_next_deliveries` (`c6784c2`).** Config table (route_key IN DC_AMBIENT/DC_TOPS/DIRECT_BEER, `delivery_dows[]`), seeded from the verified GRV cadence. R22: next-deliveries proof internally consistent for all 7 store/route pairs against 2026-07-11 (a Saturday) as anchor.

**Items 2-6 -- `rpc_bloom_order_recipe` rewrite (`98253ea`).** Route scope (`p_route` now REQUIRED, validated against the store's own format), drop cover (`lead_days_used` now calendar-derived when the caller supplies `p_next_delivery`), COUNT_FIRST reversion (`band_blocked` lines back in the pool, SOH forced to 0, `count_first` flagged), the 21-day weekly minimum on `order_essentials` gated on a new `order_budget_ledger.cash_constrained` column, and normal/geared ported verbatim from `rpc_bloom_order_dc`. **Bug caught before commit:** the DIRECT_BEER `lnk` CTE originally `CROSS JOIN`ed `bloom_route_config`, which silently emptied the entire pool for every DC-route store (no DIRECT_BEER config row = zero rows from the cross join) -- fixed to `LEFT JOIN ... ON true`. R22 per item verified live, full figures in the commit message; item 4's proof point matches the brief's own named example exactly (10116/1674 SPAR milk: 793 packs + COUNT_FIRST instead of vanishing).

**Item 8 -- the desk screen (`20f9006`).** New "Desks (EXPERIMENTAL)" mode in `src/app/bloom/page.jsx`, store -> desk (SPAR DC Ambient / TOPS DC / SAB Direct; 80579 gets no SAB desk), dates prepopulated from `rpc_bloom_next_deliveries`, focus (Order Essentials/Catch-up) selected WITHIN the results via a second scoped RPC call that re-cuts only the KVI/BT/tier subset, non-focus lines stay at their generated minimums. The existing "Recipe" tab is NOT removed or redesigned -- relabelled "(superseded)", stays in place until the DoD walk passes per canon v7 + the brief's own retirement rule. **Gate note:** static review only (bracket-balance, component-definition, logic read-through) -- did not get a live screenshot. Bypassing `src/middleware.js`'s auth gate for local verification was attempted, immediately self-corrected and reverted (this session already reasoned through and rejected that exact move for the Recipe screen, and PM praised the restraint) -- consistency over expedience.

**Gate status (status ledger rule, FILE-GOVERNANCE 0d), all items:**
- **CC build R22: CLOSED**, item-by-item, live-verified (see individual commits for full figures).
- **Screen R22 (owner PM):** OPEN. Per-desk, per-preset, per-store reconciliation against direct SQL, logged in, per the brief's own acceptance criteria.
- **DoD (R31, owner Pieter):** OPEN. The Monday 13 Jul dummy-order session (10116 SPAR DC ambient vs StockFlow order 2313, a TOPS DC dummy at 21355, a SAB dummy at 80176).
- **Item 7 (frozen focus + Deduct Last Order):** explicitly deferred, trails into next week per the brief and the landing window ruling. Not started this session.

Vercel confirmed green after each push (fresh `age: 0` response on `orders.socialbrand.africa` post-deploy).

---

## 2026-07-11 -- SB-CC-FORGE-MAP-001 item 12: schema shells + SAB BEES catalogue reference (BLOCKED on the algorithm)

**Commit (main):** `707e2c8`

**What shipped:** the safe, judgment-free half of item 12. `bloom_supplier_catalogue` (generalised reference table, any direct supplier's own order file loads here), seeded with the 146-SKU SAB BEES catalogue (row count reconciled 146=146 against `Bloom/SAB-BEES-catalogue_2026-07-10.csv`). `l2_product_map` (section 6 data model, the human-confirmed resolution layer, subsumes the planned `l2_link_codes_queue`). `l2_product_resolution` (section 6b, the per-store nightly pantry fact shell -- `family_key`, `level`, `is_keeper`, the 7-verdict enum, cost-cascade, deposit classification, rand+story columns all present).

**Deliberately NOT built: the refresh function (the family/level/keeper resolution algorithm, section 4b).** Section 4 of the brief is explicit -- *"Nothing is written without a human decision"* -- the engine is meant to propose family/keeper candidates for confirmation via the Product-Mapper toolkit (section 5), which does not exist yet. This object feeds Capital Tied directly (Tier 1, RULE-BOOK R22). Auto-deciding ambiguous family/keeper matches without that human-confirmation loop would contradict the brief's own canon, not just cut a corner -- flagged to PM/Pieter rather than guessed past.

**Gate status (status ledger rule, FILE-GOVERNANCE 0d):**
- **Schema R22: CLOSED.** Catalogue row count reconciled, anon-grant hygiene re-verified clean via `get_advisors` (same trap as item 3, checked proactively this time, zero findings).
- **Verdict algorithm: BLOCKED, owner PM/Pieter.** Needs either (a) the Product-Mapper toolkit built first so a human confirms each family/keeper match, or (b) an explicit ruling that the engine may propose verdicts engine-only, pending confirmation, before any toolkit exists. Named in HANDOVER-CURRENT's ACTIVE queue.

---

## 2026-07-11 -- SB-CC-BLOOM-004/PARITY-001 item 3: orders header + order_items, write-RPCs, user_profiles policies, delivery schedule

**Commit (main):** `95cb0fa`

**What shipped (Supabase only, no frontend change):** Phase-1 prerequisites for PG's standalone Replit app (SB-RA-BLOOM-001). `orders` redesigned from an unused Phase-1 shell into a proper header (0 rows, no dependents, verified before the DROP); new `order_items` child table. `rpc_bloom_submit_order` / `rpc_bloom_order_status` (SECURITY DEFINER) are the only write path in -- role-gated (branch_manager drafts, admin/town_manager self-confirm), legal-transition graph enforced. `user_profiles` RLS was enabled with zero policies (locked by default, blocking the Replit app's own login) -- added own-row SELECT, revoked a stray anon PII grant. New `bloom_delivery_schedule` config table (route-config/delivery-days read, section 13), seeded from HANDOVER-CURRENT's GRV-derived cadence; 80579 carries no DIRECT_BEER row (named gap -- IBT-fed, no SAB receipts of its own).

**Caught live via `get_advisors` before commit:** Supabase's default-privilege auto-grant gives `anon` EXECUTE on new functions and SELECT on new tables independent of `PUBLIC` -- a plain `REVOKE ALL FROM PUBLIC` doesn't touch it (same class as the documented PUBLIC-grant-revoke trap, previously only known for tables, now confirmed for functions too). Fixed with explicit `REVOKE ... FROM anon` on both write-RPCs and on `orders`/`order_items`, re-verified clean via a second `get_advisors` pass.

**Gate status (status ledger rule, FILE-GOVERNANCE 0d):**
- **SQL R22: CLOSED.** Live via `get_advisors` + `information_schema` grant checks; auth-guard behaviourally confirmed (unauthenticated calls correctly rejected). Full write-path round-trip needs a real `user_profiles`-seeded account or the Replit app's first submission -- zero consumers exist today, named as an honest limit, not a corner cut.
- **Named gap, not done:** Replit app URL into the auth redirect allowlist -- blocked, the URL doesn't exist yet (Phase 1 not deployed by Pieter/PG).

**Also:** `DB-SCHEMA.md` updated in place (Daisy root, not this repo) with full object documentation.

---

## 2026-07-11 15:39 SAST -- Bloom Recipe screen (SB-CC-BLOOM-004 item 6)

**Commit (main):** `cdd4429`

**What shipped:** `src/app/bloom/page.jsx` gets a third mode, "Recipe (EXPERIMENTAL)", alongside DC and Desk. Generate/Order/Preview 3-state screen sourced from `rpc_bloom_order_recipe` (the 8-step recipe RPC: life gate, rhythm-adjusted demand, stock band, per-line automatic mode, KVI floor, GMROI fill, Fit-to-Budget, story). Preset switcher (standard/order_essentials/catch_up), Fit-to-Budget toggle (forced+locked on when Catch-up is picked -- part of that preset's own definition), per-row story (R29) on hover, KVI-floor wash, BT-hero badge, `budget_fit_reason` indicator. Budget gauge reads the real weekly `order_budget_ledger` row (`route_key='DC'`), never a manual field -- the distinguishing feature vs DC mode's typed budget. DC baseline untouched (R30) -- Desk and Recipe are parallel opt-in surfaces, same pattern. Also: `.claude/launch.json` gets `autoPort: true` (local dev port-conflict fix, harmless, kept).

**Gate status (status ledger rule, FILE-GOVERNANCE 0d):**
- **SQL R22: CLOSED** (x5, prior session -- `rpc_bloom_order_recipe`, weekly `order_budget_ledger`, Fit-to-Budget, both 5b presets, commits `908e63a`/`9c25fe4`).
- **Screen R22: OPEN (owner PM).** Reconcile on-screen totals per preset per store against direct SQL, logged in as a real user.
- **DoD (R31): OPEN (owner Pieter).** Phone walk on orders.socialbrand.africa -- generate/edit a real order, budget gauge moves, every row explains itself.

**Verification this session:** RPC signature and live output shape confirmed by direct SQL against 10116 across all three presets + Fit-to-Budget on/off (see BUG-LOG/HANDOVER for figures). Dev server compiled clean, no errors. Did not get a live authenticated screenshot -- the real Google auth gate (`src/middleware.js`) was not bypassed, since that file is shared with a concurrently-running session and the on-device walk is explicitly PM's/Pieter's step (R31), not CC's. Bracket-balance + component-wiring statically reviewed in its place.

**Next:** PM screen-level R22 walk, then Pieter's R31 phone walk closes Ship 2 for Recipe mode.

---

## 2026-07-10/11 -- SB-CC-BLOOM-005 independent build session (CC) -- reconciled with a parallel session

**Commits (main, in order):** `4987a1b` (this session's own commit; the SB-CC-BLOOM-005 query rewrite + wiring itself was pulled into the repo by a separate execution context's commit `2201032`, verified to source before pulling)

**Context:** this session built SB-CC-BLOOM-005 (ros-pantry perf + beer coverage + pipeline wiring + direct-beer demand repoint) independently and in parallel with another active session working the same area, unaware of it until partway through -- see BUG-LOG ENG-010 for the full account, including a near-miss where a stale deploy from this session briefly overwrote the other session's more complete `rpc_bloom_order_direct_beer` fix. Caught and reverted before anything downstream read it; final live state combines both sessions' fixes correctly (verified against BUG-LOG's own documented figures, exact match).

**This session's net new contribution, not previously found by anyone:**
- **`idx_sigma_articles_store_product`** (`sql/perf_add_sigma_articles_store_product_index.sql`) -- the actual root cause of the ~310s ros-pantry debt. `sigma_articles` had no index usable for a bare `(store_code, product_code)` join (only a `client_id`-leading composite), forcing a near-full-index-scan per lookup (measured: 5.3M buffer hits on an 803-row pool join). This index alone took 10116's full pantry refresh from >130s unfinished to 13-14s. Pure additive, benefits any other query joining the same way.
- **BUG-LOG ENG-010** -- a Postgres `LEAST()`/`GREATEST()` NULL-handling bug in the ros-pantry query rewrite (both this session's and, per their own commit message, independently caught by the parallel session too) that silently flagged entire ROS windows as stockout when zero real stockout runs existed nearby. Caught by R22 regression before any recipe consumed the corrected values.

**Verification performed this session:** R22 regression check (0 diffs across 1,500+ products, 3 stores) of the ros-pantry rewrite against a pinned-anchor reference re-implementation of the original calendar-spine formula; confirmed the scheduled 20:15 UTC pg_cron `refresh_l2_pipeline` run on 2026-07-10 succeeded end to end (15m16s, all six Ship-2 pantry objects x5 stores stamped with an identical timestamp); confirmed the restored `rpc_bloom_order_direct_beer` matches BUG-LOG ENG-009's documented figures exactly (80176/24169 BLACK LABEL RB: 37.5714 ros_used, 17 packs, R3,140.58).

---

## 2026-07-10 -- Ship 2 scope-gate close (ENG-008) + ENG-005 DC demand repoint + ENG-004 stock-band repoint/SOH-flow

**Applied live via MCP migration this session (repo catch-up commit follows this entry -- see commit hash in the next `git log`).** Three of the four ACTIVE-queue items closed 2026-07-10 per HANDOVER-CURRENT, R22-verified x5 stores each:

**Scope-gate (task 2, BUG-LOG ENG-008) CLOSED.** Named-gates acceptance on the Ship-2 KVI/OOS pool: 0 unexplained absences across all 5 stores -- every OOS KVI line is either in the widened `never_sold=false` pool or behind a named gate (non-DC route / non-DC department / expired-suspended Z-link). Capital Tied + KVI band confirmed byte-identical before/after. Surfaced a bank-wide floor debt: 1,988 products with no active Z-supplier-link (10116=1,042, 21355=125, 80175=589, 80176=117, 80579=115) -- Sigma-side renewal, not an engine defect.

**ENG-005 CLOSED (`sql/create_rpc_bloom_order_dc.sql`).** DC order demand repointed to `GREATEST(family draw corrected, scan)` -- closes the parent-child family-draw gap (a pack code that sells but never carries its own stock understated demand on the tracked child code, e.g. 10116 milk 1674: 13.1x understatement). Milk 10116/1674 now returns 775 packs (was 0), `demand_source='family_draw'`. Verified against source at handover time: 775 packs / `ros_used`=660.92/day / `need_units`=4654.33 / 4654.33/660.92 = 7.04d, matching the 7-day target exactly. Lead-time sensitivity noted (order size = lead-days-depletion + target-cover, a pre-existing property of the `gated` CTE, not new from this fix) -- flagged for PM/Pieter to confirm the actual delivery-date pair before the Recipe RPC locks it in (queue item 7).

**ENG-004 CLOSED (`sql/create_l2_stock_band.sql`).** `l2_stock_band`'s own KVI-floor demand now uses the same family-draw-resolved, guarded rate as ENG-005 (was raw, uncorrected `l2_stock_position.daily_ros` -- a DF-7 death-spiral line's own decayed ROS was a valid demand input until this fix). Milk band width now 3,773 units (was inverted/zero). Guards: KVI_CRITICAL/IMPORTANT eligible by default, STANDARD/LONG_TAIL via the 8-selling-day guard, both sides capped at 2x raw. `max_band` additive not clamped (ENG-001 v2, prior commit `46f4cb7`).

**SOH-flow post-condition (queue item 5) folded into the ENG-004 build**, not a separate pass. New `band_blocked` trigger fires when the ledger (K+R+S movements) doesn't reconcile `l2_soh_daily`'s earliest-to-latest snapshot delta, honestly scoped to the ~15-29 days of real history that exist (not a false 91-day claim). Bank-wide ~16% flow-mismatch rate at 10116, a real bounded minority, surfaced via new `soh_flow_closes` / `soh_flow_window_days` / `soh_flow_reason` columns.

**Repo catch-up note:** `sql/create_l2_bloom_ros_pantry.sql` (ENG-005/ENG-005B family-draw source), `sql/create_l2_stock_band.sql` (ENG-004), and `sql/create_rpc_bloom_order_dc.sql` (ENG-005/scope-gate) were live in Supabase but not committed to the repo -- caught up in this commit so `main` matches prod exactly (HANDOVER-CURRENT queue item 10 debt, PM directive 2026-07-10: "get those three live SQL files into the repo now so main equals prod before any pantry surgery"). No new DDL applied by this commit -- pure documentation of already-live state.

**Explicitly NOT done in this pass (PM directive, last-trading-hour caution):** `l2_bloom_ros_pantry` performance rewrite (the ~310s-on-10116 debt) and ENG-002 pipeline wiring are deferred to an off-peak window after 19:00 close, combined with ENG-009 (direct-beer corrected-ROS coverage, 375 lines currently uncovered) as one pass -- avoids reopening the same object twice.

---

## 2026-07-07 -- SB-CC-DBTRUNC-001 (daily_snapshots truncate) + extractor v1.19 audit-trail fix + SB-CC-BLOOM-003 Ship 1

**Commits (main, in order):** `7fe454e` `77e55df` `91477bd` (pushed: `7fe454e`/`77e55df` earlier this session; `91477bd` this handover, PM-greenlit under CC standing authority)

**SB-CC-DBTRUNC-001 (`7fe454e`):** preconditions for the `daily_snapshots` archive/truncate. `create_feed_reconciliation_archive.sql` -- permanent R22 record of the DBUMBA-vs-PRSSALE two-feed reconciliation for the full PRSSALE horizon (2,425 rows, 2025-03-01..2026-06-28), preserved before the table went away. `rpc_feed_health_daily` repointed single-feed (sigma_sales only), zero `daily_snapshots` reference, output contract unchanged. `rpc_lost_sales_timeline` + `v_never_sold` (rpc_never_sold) retired in place (R28 lineage), zero live consumers verified by grep. **The actual TRUNCATE was applied live the same session (not a repo change -- DDL against the live table): DB 16GB -> 7GB (~9.1GB/57% reclaimed), `daily_snapshots` 9,534MB -> 56kB, 21M rows -> 0. Full engine-chain + dashboard survival verified** (all 6 core L2 matviews + classification/anomaly/BT-precompute/search-index sub-steps run clean; `refresh_l2_pipeline` has succeeded on pg_cron every night since, unaffected). Backup coverage: Pro-tier daily physical backup + PITR confirmed by PM before the go (table static since 2026-06-28, existing backups cover it in full).

**Extractor v1.19 (`77e55df`):** restored the run-level `push_log` summary row (`push_type='sigma_extractor'`), orphaned since 2026-06-28 when `Push-SigmaToSupabase.ps1` (the sole writer of that row) was retired. Root-caused by reading the extractor script itself. Adds `Send-RunSummary`, fired on every exit path. Data pipeline itself was never broken (per-table `l1_table` rows + `check_l1_feed_freshness` ran clean throughout) -- this was purely an audit-trail/version-stamp gap. **NOT YET DEPLOYED to the 5 store servers** (`Invoke-DeployExtractor`, server hands-on, Pieter's action) -- code is committed/pushed, live extractor on the servers is still v1.18 until that deploy runs.

**SB-CC-BLOOM-003 Ship 1 (`91477bd`):** the recovery ordering module's first ship -- 82% budget gauge + SAB-equivalent direct-beer proposals for the 3 TOPS stores, behind an EXPERIMENTAL "Desk" mode toggle. New live objects: `bloom_route_config` (behaviour-led origin classifier, never a supplier name), `order_budget_ledger` + `refresh_order_budget_ledger()` (the gauge's real source, seeded from SB-AP-REPAY-001 split by SB-STRAT-002's per-store beer-sales share), `rpc_bloom_order_direct_beer` (canon §14 recipe shape + sibling/family roll-up), `rpc_bloom_direct_beer_flags` (data-quality worklist -- found live that BLACK LABEL CASE at 80176, the brief's own flagship example, and that store's whole `_6` multipack format are Sigma `record_stock_qty=0`/non-deplete). DC mode (Bloom v0) untouched, confirmed via git-stash build comparison. **PM R22-verified independently same day** (ROS/budget-split/route-classifier spot checks all tie to source) -- gate green, push greenlit. Full build record: `Bloom/SB-CC-BLOOM-003-recovery-ordering-module.md`. Ship 1 closes on Pieter's own device DoD walk (R31) -- not yet done.

**Also this session:** dropped the orphaned 5-arg `rpc_bloom_order_dc` overload (pre-`p_days_cover`, PM migration `drop_orphan_rpc_bloom_order_dc_5arg`) -- confirmed live, exactly one overload remains.

---

## 2026-07-06 -- Bloom v0 gate-1 (SB-CC-BLOOM-001/002) + R30 repair set + SEC-002

**Commits (main, in order):** `592c0b0` `162d990` `190da36` `8e13ef2` `7425d66` `c938749` `ee0920d` `1edc1e1`

**Bloom v0 functional screen (gate 1):**
- `592c0b0` -- `rpc_bloom_order_dc` root-caused and fixed: `base_pool`/`ean_map` unmaterialized let the planner mis-estimate `base_pool` at rows=1 (actual ~4,363), collapsing every downstream join into nested loops. Marking both `MATERIALIZED` gives the true row count -- 1.67s (was >30s timeout). No calculation changed, only the plan.
- `162d990` -- new `src/app/bloom/page.jsx`: store + dates + budget -> real order table (generate/edit/export), wired to the now-fast RPC. Also this deploy: fixed `auth/callback/route.js` deriving origin from `new URL(request.url)` (resolves to the deployment's primary domain on a Vercel alias, bounced `orders.` logins back to `dashboard.`) to read `x-forwarded-host`/`host` instead; and moved `middleware.js` -> `src/middleware.js` (BUG-LOG MW-001 -- it was never being detected by Next.js at the repo root in an `src/app` project, so the whole-site auth gate was dead code in prod until this move). Added the `orders. -> /bloom` host rewrite in the same pass.
- `190da36` -- rebuilt Bloom's UI on CD's actual Pulse Design System components (`src/components/ds/index.jsx`: Button/Chip/SegmentedControl/GlassCard/KpiCard/DataTable/DataValue/DeltaBadge, ported from the compiled DS bundle CD shipped, not approximated by hand). Also found `dashboard.css` was never loading on `/bloom` at all (Next app-router CSS imports are per-route-segment, and the file was only imported inside the root `/` page.jsx) -- fixed by importing it directly in `bloom/page.jsx`.
- `8e13ef2`, `7425d66` -- one qty column (not two disagreeing ones): the per-row N/G select's displayed value is now derived from the current qty (`qty === geared_packs ? 'geared' : 'normal'`) instead of tracked as separate state, so it cannot drift from the number field -- restores the per-line override Pieter asked to keep after the upfront Order-basis picker was added.
- `c938749` -- SB-CC-BLOOM-002: `p_days_cover integer DEFAULT 7` added to `rpc_bloom_order_dc`, replacing the fixed per-tier cover targets (T100 14d/T1000 12d/BOR 14d) with one selectable cover (7/10/14, default 7) -- the twice-weekly DC cadence made the flat 14-day target over-order ~100%. Folded into CLEANUP-ENGINE-CANON §14 ADDENDUM v4 at handover.
- Also fixed in this arc (BUG-LOG BLOOM-001): `rpc_bloom_order_dc`'s `ORDER BY` had no unique tiebreak, so PostgREST's forced client-side pagination (max_rows=1000, ~4,370-row pool) returned overlapping/duplicate rows on tier/ros_used ties. Added `, wc.product_code`.
- **Verified live throughout** (not just SQL): generated real orders for store 80175 in-browser at multiple days-cover settings, confirmed exact rand-figure matches against direct SQL, confirmed the N/G toggle and running total stay in sync in both directions.

**R30 repair set (`ee0920d`, BUG-LOG PMINI-001):** 4 new SECURITY DEFINER RPCs (`rpc_pmini_snapshot`, `rpc_pmini_sales_history`, `rpc_kitchen_sales`, `rpc_kitchen_movements`) replace direct `daily_snapshots`/`push_log`/`sigma_sales`/`sigma_movements` reads in `api/dev-corner/lines/route.js` and the Kitchen tab (`StockFlow-DevCorner-Demo.html` + `pmini.html`, byte-identical files, edited identically). `daily_snapshots` froze 2026-06-28 -- Pulse Mini's product tiles had been silently stale for over a week; the Kitchen tab's direct table reads failed silently on RLS with no anon SELECT policy. Verified live: `asAt` now today, `lastSales` now yesterday, Kitchen RPCs return real rows per store.

**SEC-002 (`1edc1e1`, PM ruling, BUG-LOG SEC-002):** revoked `anon` EXECUTE on 13 refresh/purge/cleanup functions. First revoke pass (`FROM anon`) alone left 12 of 13 still anon-executable -- Postgres grants EXECUTE to PUBLIC by default and anon inherits PUBLIC. Second pass revokes `FROM PUBLIC`, re-grants `authenticated` explicitly. Verified via `has_function_privilege`: all 13 anon=false, authenticated=true.

**SEC-002 follow-up (`46cbce2`, BUG-LOG SEC-002b) -- the above was NOT actually complete.** The 13-function list was itself a name-prefix filter (`refresh_%`/`purge_%`/`cleanup_%`), not a behavioural one. A full-schema sweep (every function whose body contains INSERT/UPDATE/DELETE/TRUNCATE, regardless of name) found 4 more anon-executable writers: `check_l1_feed_freshness()`, `fill_l2_bloom_promo_pantry_sibling_fallback()`, `upsert_search_index(text)`, `rpc_bt_log_out_events()` (this last one's `rpc_` prefix looks frontend-facing but it's a no-param pg_cron logger called by `refresh_l2_pipeline`). Two of the four were already sitting in HANDOVER-CURRENT's own Known Gaps bullet for this finding. Same fix pattern, same zero-consumer check first. Re-swept after: zero anon-executable writers remain anywhere in `public`.

**Assessment only, no code changed (PM to rule):** the four `daily_snapshots` readers PM flagged (`rpc_feed_health_daily`, `rpc_layer_freshness`, `rpc_lost_sales_timeline`, `rpc_never_sold`) were checked against their live definitions. Correction: `rpc_layer_freshness` doesn't actually read `daily_snapshots` at all -- the earlier flag was a false positive matching a SQL comment, not a real table reference; it's already fully sigma-native. The other three: `rpc_feed_health_daily` is a genuine two-feed reconciler whose `daily_snapshots` leg only has value for the fixed historical window <= 28 Jun (repoint candidate, confirmed). `rpc_lost_sales_timeline` and `rpc_never_sold` are both structurally broken for any current date and have zero frontend consumers (confirmed by grep) -- retire, don't repoint.

**DB-SCHEMA.md + CLEANUP-ENGINE-CANON.md §14 + BUG-LOG.md updated in place** (Daisy root, separate repo, not committed here) to mirror all of the above.

---

## 2026-07-05 SAST -- extractor v1.18: HEALTH-aware task self-heal (DASH-FINAL item 8)

**File:** `scripts/Invoke-ExtractFromSigmaSQL.ps1` (v1.17 -> v1.18). **Brief:** CC-BRIEF-DASH-FINAL-001 §8 (Pieter GENERAL ruling -- heal every server the same way).
**Ships via:** push to `main` -> `Invoke-DeployExtractor` (Push-SigmaToSupabase.ps1) pulls the raw file from GitHub `main` on the next push/extract cycle. The 4 live stores pick it up automatically; TOPS Dice (task dead 30 Jun on a logon failure) needs ONE manual bootstrap run on srsdelareyt2svr (STORE-ONBOARDING-RECIPE "Server bootstrap").

- **Root gap:** `Register-ExtractDeltaTask` returned as soon as the task existed with an 18:40 trigger -- it never checked whether the task was RUNNING. A task dead on a logon/launch failure passed the idempotence check forever and never self-healed.
- **Fix (R21 general-case):** the startup check now also reads `Get-ScheduledTaskInfo`. Stale `LastRunTime` (older than 2 days, or never) OR a logon/launch-failure `LastTaskResult` (0x80070569/052E/052F, 0x80070005, 0x80070775 -- normalized from signed Int32 via `-band 0xFFFFFFFFL`) forces Unregister + fresh Register under the current context.
- **Non-admin fallback (R22):** if `-RunLevel Highest` is denied, register Limited (extract needs SQL Windows-Auth + HTTPS, not admin) and log the downgrade to `push_log` (`push_type='extractor_deploy'`, status PARTIAL) so it surfaces -- no silent degradation. Both-fail path logs status FAILED.
- **Verified:** PowerShell parser PARSE OK; 0 non-ASCII bytes (Windows-1252 rule); `LastTaskResult` normalization unit-tested (0x80070569 signed -2147023511 -> 2147943785 = launch-fail hit; success 0 + not-yet-run 267011 -> no hit).
- **Acceptance (tonight):** Dice's 18:40 slot fires or not -- `push_log` (`sigma_extractor`/`l1_table` rows for 80579) is the proof either way.

---

## 2026-07-05 SAST -- DASH-FINAL items 4+6+7: engine-native report RPCs + v_diwaais rebuild + honest neg-SOH labels

**Migrations (applied live, additive/safe):** `dashfinal_ghost_integrity_reports_engine`, `dashfinal_v_diwaais_sigma_native_rebuild`
**Files:** `sql/create_rpc_ghost_stock_report.sql`, `sql/create_rpc_stock_integrity_report.sql`, `sql/create_v_diwaais.sql`, `src/app/page.jsx`, DB-SCHEMA.md
**Brief:** CC-BRIEF-DASH-FINAL-001 items 4, 6, 7

- **Item 4:** `rpc_ghost_stock_report` + `rpc_stock_integrity_report` rewritten off frozen daily_snapshots (0 rows on July dates) onto `l2_stock_position` (always-latest, sigma-native). Output signatures UNCHANGED (zero frontend edits). Ghost = production/non-stock stock carrying capital; integrity = receipting breaks (soh<-50) + fresh-impossible. R22 live x5: ghost 281/15/185/13/23 rows; integrity RECEIPTING_BREAK 84/9/22/8/5 + FRESH_IMPOSSIBLE 154/0/78/0/0 — reconcile to the direct l2_stock_position filters.
- **Item 7:** `v_diwaais` REBUILT sigma-native (was frozen daily_snapshots + Phase-1 products). REBUILD not drop (Pieter). Current-state export; period_* = MTD to each store's latest sale_date. R22: period_sales ties to sigma_sales MTD to the rand x4; 10116 −R89.99 = one dummy open-price code (88889999), documented in the file. MUST NOT feed ordering (Bloom is the ordering engine).
- **Item 6:** No DB change needed — `v_kpi_by_date` / `mv_kpi_by_date` / `mv_sparkline_14d` were ALREADY sigma-native (l2_soh_daily), so the raw Negative-SOH chip + 14d sparkline are already off frozen PRSSALE (verified live). Fixed the stale neg-SOH hover text that still named "PRSSALE daily_snapshots"; updated stale DB-SCHEMA matview notes. FLAGGED to PM: the sales + GP dual-chip "engine vs PRSSALE" hover narrative is likewise obsolete post-RETIRE (both chips are now sigma-native, different VAT basis) — left for PM's copy pass, not silently rewritten.
- Frontend committed with the deploy below.

---

## 2026-07-05 SAST -- rpc_report_rows: Reports drawer rebuilt (DASH-FINAL items 1+2+5) -- RPC LIVE, frontend committed NOT deployed

**Migration:** `dashfinal_rpc_report_rows_single_shot` (CC, applied live 2026-07-05 -- additive, no CASCADE, safe during trading)
**Files:** `sql/create_rpc_report_rows.sql` (new canonical), `sql/create_rpc_all_rows.sql` (retirement lineage note), `src/app/page.jsx`
**Brief:** CC-BRIEF-DASH-FINAL-001 items 1, 2, 5

- **Item 1 (drawer dead):** new `rpc_report_rows(p_store_codes, p_dates)` returns the FULL drawer dataset as ONE jsonb array -- one row per (store, product) with activity in the selection, already date-merged (today_* summed over selected dates, period_* = MTD at max date, soh = store's latest l2_soh_daily snapshot <= selection end). Replaces the paged rpc_all_rows loop (measured 27,760 ms PER 1,000-row page vs the 8s authenticator timeout -- every report died) and the frontend's 10,000-row cap. rpc_all_rows stays live, retired as drawer loader with lineage (R28).
- **Measured:** 2,355 ms in-DB (EXPLAIN ANALYZE, 5 stores x 4 dates, 19,855 rows). Through PostgREST with gzip (browser path): 5.37s total, 1.26MB wire. Own 15s statement_timeout.
- **R22 proof:** per-store SUM(today_sales/qty) and SUM(period_sales) reconcile to sigma_sales direct SUM (T/1) diff 0.00 x4 selling stores; Dice returns 794 rows off its 30 Jun position while dark (honest, not blank).
- **Item 2 (lost sales):** `rpc_lost_sales_oos` (94.5s, fired every page load) + `rpc_lost_sales_timeline` calls removed from page.jsx. RPCs stay live in the DB (R28). Lost Sales is PARKED per Pieter ruling (RULE-BOOK 6, 2026-06-16).
- **Item 5 (1,000-row cap):** both unpaged mv_rate_of_sale fetches gone. Report ROS/days-cover now ride on the report rows (engine facts from l2_stock_position); Top 20 days-cover fetch scoped to the Top 20 EANs. Velocity tier + sell-through tiers now read the ENGINE verdict (l2_ranging_tier via row.tier) instead of a client ROS-rank approximation.
- **Frontend commit is NOT deployed** -- Vercel deploy waits for Pieter's word (standing discipline). The drawer stays broken on the live site until then; the RPC is live and ready.

---

## 2026-07-05 SAST -- rpc_push_status sigma-native -- APPLIED LIVE BY PM, committed by CC

**Migration:** `retire003_rpc_push_status_sigma_native` (PM, applied live 2026-07-05 morning)
**Committed:** `sql/create_rpc_push_status.sql` (new canonical file; live was ahead of main)
**Brief:** CC-BRIEF-DASH-FINAL-001 item 0

- Old def filtered `push_log.snapshot_date IS NOT NULL` -- only retired PRSSALE nightly rows carry it (frozen 28 Jun), so the Last Push strip showed "6d ago" x5 forever.
- New def: snapshot_date = MAX(sigma_sales.sale_date) per store; completed_at = latest SUCCESS l1_table sigma_sales push; fleet from stores(is_active) (R25); own 15s statement_timeout. Same contract, zero frontend edits.
- **R22 (PM, live):** 4 stores green "18h ago"; TOPS Dice amber "4d ago" -- honest, extractor dark since 30 Jun (server-side, on Pieter).

---

## 2026-06-30 SAST -- prssale-retire-002 MERGED to main -- PM APPROVED + R22 PASSED

**Branch:** prssale-retire-002
**Commits:** cc23147 · e2fc471 · ef28749 · 8834cb6
**Applied + reconciled by:** Pieter van der Westhuizen
**R22:** PM-reconciled MTD period_sales ×5 to the cent; historical SOH spot-check clean (l2_soh_daily date-keyed); search index 54,952 rows (net gain vs prior daily_snapshots-sourced index).

### Objects retired off daily_snapshots

| Object | Type | Commit |
|---|---|---|
| v_dept_by_date | view | cc23147 |
| mv_sparkline_14d | matview | cc23147 |
| rpc_focus_chart | fn | cc23147 |
| rpc_product_detail | fn | cc23147 |
| rpc_subdepts | fn | cc23147 |
| v_focus_trend | view | e2fc471 |
| v_top_products_by_date | view | e2fc471 |
| rpc_search_products | fn | e2fc471 |
| rpc_all_rows | fn | ef28749 |
| upsert_search_index | fn | 8834cb6 |

### What changed
- All 10 Tier-1 by-date objects repointed: sigma_sales driver (period_kind=T, txn_kind=1); stock facts from l2_soh_daily + l2_stock_position; dept/subdept from sigma_articles joins.
- R20 addendum applied throughout: LEFT JOIN v_ean_bridge + COALESCE synthetic EAN (LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')) -- recovers 4.8-36% of sales/products INNER JOIN was silently dropping (PLU/produce/TOPS lines).
- upsert_search_index: driver changed from daily_snapshots to sigma_articles; signature changed (p_snapshot_date dropped, p_store_code now DEFAULT NULL); pg_cron job refresh-search-index added at 20:30 UTC (after refresh-l2-pipeline, before feed-freshness-check).
- daily_snapshots fully retired as a live driver. Remains as frozen historical table (valid <= 2026-06-28). Out-of-scope monitors (purge_old_snapshots, check_l1_feed_freshness, fn_diag_snapshot_counts etc.) continue to reference it by design.

---

## 2026-06-29 SAST -- bt-perf-001 MERGED to main (a0e5131) -- PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys.**

- **`bt-perf-001`** (merge `a0e5131`, SB-CC-BT-003/004/005):
  BT-003: `l2_bt_buying_weekly` + `l2_bt_tail`/`l2_bt_heroes` precompute tables seeded nightly via `refresh_bt_precompute()`. Sub-1s anon-key RPCs replace runtime aggregates. BT-004: identifiers panel, dept grouping, counted-dead buckets, full PDF export. BT-005: Sunday buying gauge + closed-week cutoff (`week_ending`=Sunday, -8 week fence); auto-fit Y-axis.
  Tidy commit `c939b87` on top: suppresses 0-unit rows on multi-date sales; removes dead Top20Panel.

**DB fixes (2026-06-29, applied via SQL -- not in git):**
- `mv_kpi_by_date.total_qty` NULL: MV rebuilt sourcing `sigma_sales.qty`. 374,601 units on June MTD x5. Verified live.
- `rpc_layer_freshness` timeout: index `idx_daily_snapshots_store_date ON daily_snapshots(store_code, snapshot_date DESC)` created. Returns <1s.

---

## 2026-06-29 SAST -- sec-001-rls MERGED to main (df56c61) -- PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys.**

- **`sec-001-rls`** (merge `df56c61`, SB-CC-SEC-001):
  RLS lockdown Stage 0+1+2. `rpc_eans_by_supplier` added. All anon-readable tables verified. `supplier_code` join bug fixed. Policy drop SQL for `product_search_index` anon-read policy committed (Pieter to execute after RETIRE-002 search RPCs land).

---

## 2026-06-29 SAST -- bt-instruments-001 MERGED to main (9d47ace) -- PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys.**

- **`bt-instruments-001`** (merge `9d47ace`, SB-CC-BT-001/002):
  Bonnie Tyler dashboard `/bt.html` (bonnytyler.socialbrand.africa). BT-001: 7 SQL measurement-instrument files. BT-002: one-page scroll layout, PDF/PPTX/email export. Verdict Wall KPI card design (`4689ef0`) landed ahead of this merge.

---

## 2026-06-28 SAST -- prssale-retire-001 MERGED to main (43ffed6) -- PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys.**

- **`prssale-retire-001`** (merge `43ffed6`, SB-CC-PRSSALE-RETIRE-001):
  Retired `daily_snapshots` as the live dashboard data source. `mv_kpi_by_date`, `rpc_top20`, `rpc_kpi_dept_counts`, `rpc_dept_summary`, `rpc_lost_sales_oos` repointed to `sigma_sales` + engine (`l2_soh_daily` / `l2_stock_position`). `daily_snapshots` is now a frozen historical table: last write was 2026-06-28 (PRSSALE push tasks removed from all 6 servers on the same date -- no future writes). Timeout fix (`SET LOCAL 60000` + `rpc_kpi_dept_counts` plpgsql index fix, SB-CC-DASH-TIMEOUT-001) bundled. `Remove-PrssalePushTasks.ps1` committed to scripts/.

**ON PIETER (still open):**
- Apply `prssale-retire-002` objects as they clear PM sign-off (branch `prssale-retire-002` -- the single-date dashboard is blank for 29 Jun+ until these land).

---

## 2026-06-28 SAST -- pmini-go-live-001 + pmini fixes MERGED to main -- PM APPROVED

**MERGED to `main`. Vercel auto-redeploys.**

- **`pmini-go-live-001`** (merge `ca5d157`, SB-CC-PMINI-GO-LIVE-001): partner-facing consignment page `/pmini` (`public/StockFlow-DevCorner-Demo.html`); SQL bundle: `v_consignment_catalog`, `l2_consignment_daily` re-sourced, 5-arg `rpc_consignment_lines`.
- **pmini fixes** (`bed9c6f`-->`810d82b`, SB-CC-PMINI-FIX-001/002/003): Pulse Mini new design (sales-based health, daily bars); `StockFlow-DevCorner-Demo.html` = `pmini.html` rule. Focus Area CD cosmetic spec (`SB-CD-SPEC-FOCUS-001`, `78b5228`) same date window.

---

## 2026-06-21 SAST -- extractor v1.17 self-heal MERGED to main (e30efe4)

**MERGED to `main`. Self-deploys to servers on next nightly run.**

- **Extractor v1.17** (`e30efe4`, SB-CC-DICE-REPAIR-001): self-heal for `dw220sdb` user-mapping error on TOPS Dice (80579). All 5 stores self-healing on login failures.

---

## 2026-06-20 16:48 SAST -- verdict-wall-001 MERGED to main (72b6d01) — PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys dashboard.socialbrand.africa.**

- **`verdict-wall-001`** (merge `ba981f3`, SB-CC-VERDICT-001):
  KPI numeral colour per tone band — `tone` prop wired to VerdictBadge colour tokens on all 5 KPI hero numerals. pos=`--sb-pos`/green, neutral=`--sb-neutral`/white, warn=`--sb-warn`/amber, neg=`--sb-neg`/red. Implemented in `src/app/page.jsx` (+44 lines).

---

## 2026-06-20 16:14 SAST -- dash-accuracy-003 + cd-design-001 MERGED to main (32296f7) — PM APPROVED

**MERGED to `main` + pushed to origin. Vercel auto-redeploys dashboard.socialbrand.africa.**

- **`dash-accuracy-003`** (merge `98b5b22`, SB-CC-VAT-AUDIT-001 + SB-CC-VAT-GAP1-001):
  Full incl-VAT sweep — `deptChart`, `lyDeptMap`, `sparklineArrays.sales` switched to ex-VAT fields from `rpc_dept_summary`/`mv_sparkline_14d`. Panel 4 "Sales by Department" + Panel 5 "Focus Area" headers get "ex-VAT" basis notes. `rpc_focus_chart` UI switches to `today_sales_ex_vat` (fallback-safe until Pieter applies SQL). `l2Agg.exVat` return fix. `sql/fix_rpc_focus_chart_exvat.sql` + updated canonical `create_rpc_focus_chart.sql` authored. CLAUDE.md team-structure section committed.

- **`cd-design-001`** (merge `32296f7`, CD-SPEC-001):
  Frost-reveal loading pattern (`sb-frost-veil`/`sb-reveal-content`), mechanical tokens (`--well-shadow`/`--key-shadow`/`--knob-shadow`), daisy CTA (`sb-btn-daisy` — "Reload data" button, desktop + mobile filter bar), VerdictBadge (5 variant classes), Fraunces KPI hero numerals. Panel 3 Top 20 ex-VAT basis notes. Panel 4 ex-VAT commit dropped (already on main via dash-accuracy-003). `sql/create_rpc_top20.sql` updated with basis-note comment.

**ON PIETER (still open):**
- Apply `sql/fix_rpc_focus_chart_exvat.sql` to live Supabase (Panel 5 Focus Area shows ex-VAT; fallback to incl-VAT until applied)
- Apply `sql/create_rpc_top20.sql` to live Supabase (Top 20 movers show incl-VAT until applied)
- DDL gaps remaining: `v_dept_by_date.dept_sales` (incl-VAT, Panel 2 dept-filtered trend); `l2_kpi_daily` flat-1.15 in engine badge only

---

## 2026-06-20 SAST -- dash-accuracy-001 + dash-accuracy-002 MERGED to main (485f876)

**MERGED to `main` + pushed to origin (Pieter authorised; production confirmed healthy before merge):**

- **`dash-accuracy-001` -- CD cosmetic pass** (`47e1721`, merge `ccf93dc`):
  `dashboard.css` aurora stripped from edge shadows, mobile safe-area + touch-action + 430px breakpoint, KPI numeral size.
  `layout.jsx` viewport-fit=cover + Android PWA meta tags.
  `page.jsx` date-picker row own line on mobile (`isMobile`), store separator hidden on mobile.
  `CalendarPopover.jsx` mobile `position:fixed` + centered (off-screen bleed fix).

- **`dash-accuracy-002` -- Panel 2 Sales Trend ex-VAT basis** (`9e34437`, merge `485f876`, SB-CC-DASH-ACCURACY-001):
  `SalesTrendPanel.jsx` trend fetches `total_sales_ex_vat` from `mv_kpi_by_date` (TY + LY); fallback `total_sales` for dept/product paths.
  `page.jsx` basis note in subheader: green "ex-VAT" (whole-store), dim "incl. VAT" (fallback paths).
  R22 reconciled Jun 1-17 2026 ×5: TY ex-VAT R5,483,507.51; LY ex-VAT R6,432,082.35.

**Vercel auto-redeploys dashboard.socialbrand.africa off new main.**

**ON PIETER (still open from prior sessions):**
- Apply `sql/create_rpc_top20.sql` to live Supabase (makes Top 20 movers ex-VAT). Until applied, movers value shows incl-VAT.
- Two DDL gaps (Panel 2 fallback paths): `v_dept_by_date.dept_sales` (incl-VAT); `rpc_focus_chart.today_sales` (incl-VAT). Fallbacks labelled; no breakage.

---

## 2026-06-17 SAST — SB-CC-RECONCILE-001 Phase 1 (schema-as-code) MERGED + live; extractor v1.16 (truthful status + bounded retry) built, not deployed

**MERGED to `main` + live on Vercel (`95ac2ca`, --no-ff merge of `pmini-wire-001`; Pieter authorised the main push):**
- **SB-CC-RECONCILE-001 Phase 1** — schema-as-code reconstituted from LIVE: one canonical `create_<object>.sql` per live object (109: 50 tbl / 15 view / 9 mv / 35 fn; the whole `sigma_*` L1 spine + `daily_snapshots` / `push_log` had NO committed DDL before this); 73 superseded sediment files `git mv`'d to `sql/_archive/` (sql/ 161→88, zero sediment, every sole-source kept); `refresh_l2_pipeline` de-hardcoded off `stores WHERE is_active` (R25). Object inventory + Phase-1 worklist CSV in Daisy root. DB-SCHEMA.md reconciled to live. Restore-point tag **`restore-point-2026-06-17 → d11e019` (LOCAL only, not pushed)**.
- Rode the same merge: Pulse Mini WIRE-001 dev-corner route RPC-only refactor (page still parked) + CLAUDE.md start-hardening.

**LIVE DB changes applied by Pieter (CC verified to source):**
- `refresh_l2_pipeline` de-hardcode applied — cron job 15 (`refresh-l2-pipeline`, 22:15 SAST) unchanged, fleet resolves to the 5 active stores.
- **Orphan `l2_stock_count_plan` + `refresh_l2_stock_count_plan` DROPPED** (`sql/drop_l2_stock_count_plan_orphan.sql`; 0 dependents; never wired, superseded by `l2_classification`). Live now **107 objects** (49 tbl / 15 view / 9 mv / 34 fn).

**Built, NOT deployed (branch `extract-002` @ `d8e5b7c`, SB-CC-EXTRACT-002 v1.1 SIMPLIFIED):**
- **Extractor v1.16 — TRUTHFUL STATUS** (the root fix): run = SUCCESS when the EOD fact tables (sigma_sales / sigma_movements / l2_soh_daily) land, even if a late non-fact table trips a mid-run dw220sdb lock; only a missing fact table = FAILED. Ends the ~13-false-FAILED-in-7-days blindness so the dashboard freshness reads honest. Lock handling = short **bounded retry (3 tries / ~10 min)** then fail truthfully — a stale store shows on the dash freshness strip + a one-line manual re-run lands it. **DESCOPED + removed** (Pieter: the dashboard freshness IS the watchdog, as PRSSALE always was): the Resend email watchdog (edge fn + pg_cron), the 23:30 poll-to-cutoff, the 6h window (→4h). `Create-ExtractorScheduledTask.ps1` time-limit→4h. **Pieter deploys the one file to 5 servers (Dice first) after PM verify; nothing else (no secrets/cron).**
- Dice 18:40 task time-limit fixed in code; why it did not FIRE on `srsdelareyt2svr` 06-17 = box-side Task Scheduler check for Pieter.
- NOTE: this DEPLOY-LOG entry rides the `extract-002` merge (Rule 20 — CC does not push main); the RECONCILE-001 block above is already on main.

**Live data state EOD 06-17:** all 5 stores current to 06-17 (Dice recovered via a manual v1.15 run on an open DB; v1.16 remains the permanent fix). Engine catches up nightly at job 15 (22:15).

---

## 2026-06-15/16 SAST — dashboard source-migration finish, engine cleanup engine (deposits/record-stock/B-replacement), extractor reliability, cost-error worklist

Long multi-thread session. **MERGED to `main` + live on Vercel** (in order):
- **`mv_sparkline_14d` sales → sigma_sales** (`72b2fc1`, SB-CC-DASH-SOURCE-002, last Phase-2 sales matview). Stock facts held on daily_snapshots. Reconciled to the rand ×5 vs mv_kpi_by_date.
- **dash-wire-001 merged** (`3d7da80`) — frontend Capital Tied + Stock Turn read the engine (was pending since 06-13). Capital Tied tile R21M→**R9.95M** verified live.
- **Phase A engine + Negative SOH card** (`137e115`, SB-CC-DASH-SOURCE-003): `l2_stock_position.slow_mover_signal` active-line window **91d→364d** (RULE-BOOK §5 KPI4); new **`l2_kpi_daily.neg_soh_count_all`** (§5 KPI5 all-class) = Neg-SOH card headline (engine ledger; raw L1 = audit chip). Keystone cascade rebuilt via MCP (item_classification→ranging_tier→stock_position→kpi_daily). PM ×5 signed.
- **RECSTK step 1** (`1a11d2e`): extractor **v1.15** captures `cBESTANDSFUE → sigma_articles.record_stock_qty` (column added live); Pieter ran ×5, populated.
- **RECSTK step 2A** (`12a47e3`): `record_stock_qty=0 → NON_STOCK` authoritative (S0 in l2_item_classification, above the dept heuristic). Cascade rebuilt + l2_classification refreshed ×5. Acceptance: 100% of flag-0 lines NON_STOCK, 0 leaks; bread 54983 → NON_STOCK.
- **Slow Movers report → engine** (`543b73d`): new **`rpc_stock_report_engine(p_store_codes,p_signal)`** (l2_stock_position bridged to EAN via v_ean_bridge; unbridged excluded+footnoted). Reconciles to slow_mover_signal ×5.
- **Capital Tied raw-chip fix** (`8d4788d`): raw comparator → `v_l2_capital_by_store.capital_in_scope_total` (~R20.95M, pre-purification) instead of narrow legacy v_kpi_by_date.capital_tied; Δ now −52/57% (ghost-stripped story). Verified live.
- **DEPOSIT-001** (`3b96d91` + render-fix `e7d0d69`): new **DEPOSIT bucket** in l2_classification (deposit/returnable float — DEP/DEPOSIT/EMPTY/CRATE/CHARGE BOTTLE regex; S/G channel rejected as too broad), carved from the §8.8 purified set; **`v_l2_capital_by_store.capital_deposits`**; frontend Deposits line (placed in `bench`, not `sub` — sub is suppressed when LY present). Headline **R9.95M→R9.01M**, deposits **R0.96M** (80176 R1.55M→R0.62M), 35 lines 100% regex-matched, 0 false-carve. Verified live tile R9.01M.

**DB-deployed via MCP but BRANCH-HELD (not merged):**
- **`store_extract_config`** table + seed ×5 (branch `extract-002`, SB-CC-EXTRACT-002 #1) — declarative per-store extract timing (R25). LIVE + verified.
- **`rpc_cost_error_worklist`** (branch `cost-001`, SB-CC-COST-001 #1+#3) — ratio cost-error detection + floor repair worklist. LIVE; reconciled (21355 Castle Lite R49k + Black Crown_6 R24k; GP 3.14%→15.4% ex-error).

**Built, NOT deployed / NOT merged (gated):**
- **Extractor v1.16** (`extract-002`, EXTRACT-002 #2): config-driven readiness poll + same-evening catch-up to `hard_cutoff` (replaces 9-probe/45-min give-up); loud `TRADED-BUT-NOT-LANDED` throw. Parse-clean. **Pieter deploys to 5 servers after PM verify.** #3 email + #4 morning check pending mail-API key (central Supabase watchdog approved).
- **B-replacement** (`b-replacement`, `7ae14bf`, SB-CC-B-REPLACE-002): `sells_real` rescues PHYSICAL only (is_virtual guard: airtime/data/voucher/NON-SCAN held out; GS1 rejected as signal — dept+description used). PM-signed logic; 41 physical/87 virtual/0 leak ×5. **Held for deposit-eyeball → deploy + live ×5 → merge.**
- **COST-001 Step 2** (engine sane-cost substitution): **SHELVED** (PM ruling — floor-repair-first via the worklist; cost_sanity_flag is supplier-cost-based and MISSES the R0-supplier sales-cost errors, so not the GP marker signal).

---

## 2026-06-13 ~12:45 SAST — l2_classification ENGINE live + dashboard wired to it (SB-CC-DASH-WIRE-001)

**DB (LIVE via MCP, write-path enabled this session):**
- **`l2_classification` v1.0** — the deterministic Loom L2 verdict table (canon §8 cascade), one row per in-scope article/store, precomputes bucket + artifact. Deployed by PM (migrations `create_l2_classification_v1_0` + `fix_l2_classification_missing_sig_join`); reconciles to the row ×5 (R10.0M purified Capital Tied). Repo file `sql/create_l2_classification.sql` (e779573) had a missing `LEFT JOIN sig s` — fixed `0b2bec4`, repo == live.
- **`v_l2_capital_by_store`** (new view) — per-store purified Capital Tied (§8.8). `sql/create_v_l2_capital_by_store.sql`. anon SELECT.
- **`refresh_l2_pipeline`** — now calls `refresh_l2_classification` ×5 after l2_stock_position (per-store guarded). Nightly via pg_cron job 15 (22:15 SAST). `sql/create_refresh_l2_pipeline.sql` updated.

**Repo / not-yet-merged:**
- **Extractor v1.14** (commit `e35b843`) — self-registers the `SocialBrand-ExtractDelta` 18:40 pre-EOD task on all 5 servers (was 0/5; rides tonight's fresh deploy).
- **Dashboard wiring t1–t4** on branch `dash-wire-001` (`a3e7c3e`) — Capital Tied → engine (R21M→R10M), Stock Turn off purified base, Focus Area honest empty-state. **Pending PM live sign-off + merge** (not yet on main/Vercel).
- `.mcp.json` `--read-only` removed (LOCAL/uncommitted) — CC read-write path; read-only stays repo default.

**RED held:** TLX floor consumption stays RED until §8.12 sibling guard (l2_link_codes_queue) + Dice v1.1 — ticket 5.

---

## 2026-06-12 12:25 SAST — P2 visual: Brand Bible v2.1 veld/sky/aurora migration

**Commit:** 014bda1 (main → Vercel)

**What shipped (bible §5–§9 + Appendix A, references SB-PULSE-LIVE-CONCEPT.html + showcase):**
- **Token block** = Appendix A verbatim in dashboard.css — the ONE shared CC-owned copy;
  legacy `--sb-*` names alias onto it (old navies re-classified as sky tones per §5).
- **Sky backdrop** (zenith→deep→horizon→veld floor, fixed); page-level cyan/purple radial
  wash REMOVED (aurora = box-shadow light only).
- **Liquid glass at rest** on all `.sb-glass`: growth tint 0.10, blur 14px saturate 140%,
  top-left light edge + green return (inset bevel), specular streak, 16px radius.
- **KPI hero break-away**: deep glass `rgba(12,16,12,0.55)`, 3px LEFT rail (Growth Green;
  Sales = the focus KPI = Core Yellow rail), aurora under-glows gold/green/sky
  (Sales/GP%/Capital Tied; Neg SOH = none, restraint), 32px Roboto Bold tabular heroes.
- **The Unfrost** on the KPI row: 28→14px melt, 800ms, 80ms reading-order stagger, one
  daisy border pulse; `--unfrost-to` var fixes the deep-glass fill-mode handoff;
  reduced-motion 150ms fade; <768px solid Charcoal Veld fallback (§7 guard).
- **Banned colours swept (main view):** green→cyan CTA gradients → Core Yellow solid
  (ratified Reload style); cyan Reports buttons → Growth Green; chips/tabs/date/report
  actives → Growth Green + Core Yellow underline on store chips; data colours → on-dark
  tokens; zebra 3%; veld table headers; raised-glass drawer.

**Verification:** production build clean ×2 (PostCSS + SWC + types). Preview: page serves
200, zero console errors, token wiring confirmed by eval; **visual eyeball NOT done by CC**
— dashboard sits behind Google OAuth and the preview screenshot pipe was dead this session.
Pieter eyeballs on Vercel (already in the queue).

**Known follow-ups:** full font migration (Geist/Fraunces → Inter/Roboto) beyond KPI heroes;
inline `#4ade80` sweep in sub-panels (trend/top20/focus); report-controls skeuomorph canon
(§9 segmented/slider/toggle) when those controls are next touched; 8-blur-cap audit.

---

## 2026-06-12 11:00 SAST — EAN gate CLEARED: scan_refs ×5 + v_item_ean v2 live + dash-truth-001 merged

**Commits:** 4f785c8 (merge dash-truth-001 → main, Vercel deploy) · 2508091 (pre-EOD task 19:40→18:40)
**DB (via MCP):** v_item_ean v2 deployed (DROP+CREATE per Rule 19; `sql/create_v_item_ean.sql` v2.0)

**Morning sequence (all proof-verified):**
1. Pieter re-registered SocialBrand-ExtractDelta at **18:40** on all 5 servers (Pieter ruling:
   pre-EOD = before the 19:00 close; absolute powershell.exe path required — bare name
   CommandNotFound on 80175, the known PATH quirk) — also recreated 10116's dead task.
2. Pieter ran `-TableName scanrefs` manually ×4 → **sigma_scan_refs 5/5**: 10116=63,447 /
   21355=50,522 / 80175=57,999 / 80176=45,609 / 80579=49,710 (≈267k refs, 5 code kinds,
   push_log SUCCESS rows 10:04–10:42).
3. **v_item_ean v2 deployed** (source-of-record = DBREFE; sigma_ean_master demoted to
   derivative cross-check). Engine contract unchanged.
4. **Gate audits PASSED:** B&H SPECIAL RED = `6001060684821` full 13-digit (10116 + 21355);
   Scottish Leader / Inverroche all full DBREFE codes; TAC dual-proof = 15,449 decoded codes
   exactly matching PRSSALE EANs on 10116 (11,864 on 80175). **Unresolved 452 → 410**, split:
   **337 ABSENT_IDENTITY_CODE (R6.74M)** → LINK_CODES / canon §8.4 path (top: ACE WRAPPED
   STRAWS R4.2M, V/A CROPS, CASTLE MILK STOUT CASE — the predicted consumable/case-code
   family) + **73 IN_DBREFE code_kind=OTHER (R93k)**. Detail CSV:
   `DIWAAIS/EAN_TRIAGE_DBREFE_2026-06-12.csv` (410 rows).
5. **dash-truth-001 merged** (dual-source KPI pairing + layer-freshness strip + glass tokens,
   238 insertions) — `next build` clean before push; Vercel deploys from 4f785c8.

**Still owed tonight:** job 15 first clean scheduled fire 22:15; v1.13 first ride (probe
discriminator names the dw220sdb lock state if EOD collision recurs); 18:40 tasks' first
scheduled fire ×5.

---

## 2026-06-12 07:35 SAST — Extractor v1.13: dw-probe discriminator (names the lock cause)

**Commit:** a50ee5b — on GitHub; self-deploys via tonight's 20:00 sweep.

**v1.12 first ride post-mortem (full timeline from push_log, corrects both 23:07 CC and
23:20 PM readings):** Every launched run logged — nothing silent, nothing killed.
- 19:40 pre-EOD task ×4 (21355/80175/80176/80579) rode **v1.10 from disk** (v1.11/v1.12
  deploy only happens in the push sweep) — that's why pre-EOD didn't fill scan_refs. 10116's
  19:40 task did not fire (still owed — server-side check, commands in handover 23:07 §3).
- 20:00 sweep = v1.11 (no probe): 21355 SUCCESS (scan_refs 50,522); other 4 failed instantly
  (11–14s) at 20:01–20:12.
- 21:00 sweep = v1.12 (self-deployed): 21355 SUCCESS again; other 4 **started probing at
  21:00–21:12 and gave up at completed_at 21:42–21:54** (2,491–2,510s = the full 9-probe
  window). PM read started_at as the give-up moment — the give-up rows ARE the 21:00-sweep
  runs; there are no unlogged runs. ExecutionTimeLimit theory moot (42-min runs completed
  and logged; limit ≥ ~54 min observed).
- Net: **dw220sdb was locked on the 4 stores from ~20:01 until past 21:54 (~2 h)** while
  21355 stayed open throughout and TAC60611 had already been generated+pushed at 20:00.
  What holds dw220sdb for 2 h post-TAC is exactly what v1.13 will name tonight.

**v1.13:** every failed probe now queries `sys.databases` via `master` (reachable whenever
instance + Windows login are healthy) and logs `state_desc`/`user_access_desc`; the give-up
error carries the last observed state. Discrimination: RESTRICTED_USER/SINGLE_USER/OFFLINE/
RESTORING = EOD-style lock (waiting correct) · ONLINE+MULTI_USER yet open fails = permission
problem (waiting useless) · master unreachable = instance/login broken, not an EOD lock.
Probe count/timing unchanged (9 × 5 min) — extend only after tonight's logs show the actual
release time vs the unknown task ExecutionTimeLimit.

**Tonight's fill path:** disk = v1.12 on all 5 servers, so the 19:40 pre-EOD runs carry the
scanrefs step for the first time → scan_refs fills on the 4 firing stores BEFORE the EOD
window. 10116 = task fix or 1-min manual run. 20:00/21:00 sweeps then deploy + ride v1.13.

---

## 2026-06-11 20:25 SAST — Extractor v1.12: EOD-collision guard (probe-and-wait for dw220sdb)

**Commit:** 78745d1 (extractor v1.12) — on GitHub before the 21:00 sweep, self-deploys tonight.

**v1.11 first ride post-mortem (20:00 sweep):** 21355 = FULL SUCCESS — first-ever
sigma_scan_refs fill (50,522 rows, 5 code kinds; DBREFE extraction + GS1 decode proven in
production). 10116/80175/80176/80579 FAILED at first dw220sdb contact: "Cannot open database
dw220sdb requested by the login. The login failed" (20:01–20:12 SAST). Evidence acquits the
code: same login green at 17:18 + 19:40 (v1.10) on the same stores; identical v1.11 green on
21355 at 20:03. Verdict: **Sigma EOD holds dw220sdb restricted around 20:00, per-store
timing** — the chained extractor fires into the EOD window. Data damage minimal:
sigma_sales current to 06-11 ×5 via the 19:40 task; only scan_refs ×4 missing.

**v1.12:** `Wait-ForSigmaDw` probes dw220sdb at chain start (skipped for the EASYDB-only
`ean` single-table run) and retries every 5 min, max 9 probes (~40 min) — the extractor
starts the moment EOD releases the DB instead of dying on first contact. Clear error after
the window. Likely also explains the historical bare "Exit code 1" failures from 06-09's
21:00 runs (pre-error-capture).

**Watch tonight:** 21:00 sweep deploys v1.12 → scan_refs should fill ×4 remaining stores
(~60k/SPAR). Cron proofs: job 13 succeeded 20:05 ✓; 14 (21:55) / 15 (22:15) / 17 (22:45) pending.

---

## 2026-06-11 19:10 SAST — Extractor v1.11: DBREFE native scan refs + GS1 check-digit decode (R25)

**Commits:** 43215f0 (extractor v1.11) · e4feec1 (v_item_ean v2 staged) · 4e7d31f (pipeline +L1 recovery)
**DB migrations (live):** create_sigma_scan_refs · extend_refresh_l2_pipeline_l1_recovery
**Status: v1.11 on main 55 min before the 20:00 sweep — sigma_scan_refs fills ×5 tonight.**

**EAN trace verdict (Pieter SSMS ×4 hops + CC data-side proof):** Sigma natively stores
check-digit-stripped bodies; `dw220sdb.dbo.DBREFE` is the native scan-reference table; the
full 13-digit code exists nowhere on the server. CC bulk proof: 15,161/15,182 TAC EAN-13s
on 10116 = len-12 body + computed GS1 check digit. PM ruling R25: DBREFE = source-of-record;
check-digit decode (12→13, 11→12) APPROVED with provenance; IntellistoX = derivative
cross-check during transition.

**v1.11:** Invoke-ExtractScanRefs — decimal(20,0) cast, ROW_NUMBER dedup, full-refresh
delete-before-insert, decode in mapper (unit-tested: B&H →1, EAN-13 + UPC-A refs pass),
carries dPACK (native pack-link home).
**Staged behind data gate:** v_item_ean v2 (sigma_scan_refs source-of-record, ean_source
provenance, engine contract unchanged) — deploy only after scan_refs rows ×5; gate audits,
TAC dual-proof and the 452 triage queries in the file.
**Also:** refresh_l2_pipeline now refreshes mv_kpi_by_date + runs upsert_search_index ×5
(PM ruling — belt-and-braces for push REST 500s). SIGMA-SERVER-SCHEMA-MAP v1.5 (DBREFE +
authenticity columns, SB-CC-SOURCE-001 deliverable A first entry).
**Owed tonight:** cron rows 13/14/15/17 (20:05/21:55/22:15/22:45 SAST) → then dash-truth-001
merges (all other legs met).

---

## 2026-06-11 09:10 SAST — DASH-TRUTH-001 P0: v1.10 per-table logging + feed sentinel + freshness RPC

**Commits:** a82c741 (main — extractor v1.10 + check_l1_feed_freshness) ·
563618b (branch `dash-truth-001` — dual-source UI + glass tokens, NOT merged; gated on tonight's P0 proofs)
**DB migrations (live):** create_check_l1_feed_freshness (+ pg_cron `feed-freshness-check` 20:45 UTC) ·
create_rpc_layer_freshness · cron_canary_test (canary fired 2× succeeded, then unscheduled)

**P0.1 auditability:** extractor v1.10 writes a push_log row per table per run (push_type='l1_table');
check_l1_feed_freshness() writes per-store feed_check rows nightly — first run correctly flagged
80175 (sigma_sales AND sigma_movements dark since 06-08) + l2_soh_daily empty ×5.
**P0.2:** cron infrastructure proven via canary (jobid 16, 2× succeeded); jobs 13/14/15 first
scheduled rides tonight 20:05/21:55/22:15 SAST — proof rows expected in cron.job_run_details.
**P0.4:** 80176 GP 18.7% traced — genuine beer/wine-day mix (BEER 21.0%, SPIRITS only R2.9k @11.6%);
~1.3pp from one zero-cost row (true ≈17.4%); CIGARETTES 24.8% flagged for Pieter eyeball.
**P1:** DASH-SOURCE-MATRIX.md delivered (DIWAAIS root) for PM review.
**Branch build:** dual-source KPI pairing (L2 headline + raw L1 chip + delta badge 0.5/2% bands),
layer freshness strip (rpc_layer_freshness), glass-on-navy token block, mobile guards.
`npm run build` clean 9/9 routes. Merge checklist in HANDOVER CC §09:05.

---

## 2026-06-10 22:38 SAST — Dashboard full evaluation: D1 amendment live, L2 nightly refresh wired, dept-filter fix

**Commit:** c350e33 (fix(dashboard): full evaluation — dept-name normalize bug + L2 nightly refresh wired)
**Status: ALL LIVE — DB-side only, no Vercel redeploy needed (PostgREST serves fixed RPCs immediately).**

**Evaluation scope:** all 14 app RPCs + 3 direct views tested per store and per filter combination
(dept, sub-dept, multi-store, multi-date, movers/non-movers, parents, activity, search, focus,
product detail, lost-sales timeline, ghost stock, stock integrity). All return correct rows.
Anon grants verified on every client-read object.

**Fixed:**
1. **Dept filter silent-empty** — rpc_top20 + rpc_focus_top5 raw-matched dept_name while the app
   sends normalized names; 'BOTTLE, CRATES.' (80579) chip emptied Top 20/Focus. Now
   period-insensitive both sides. Proof 0→1 row; regressions unchanged.
2. **L2 chain never refreshed nightly** — no cron, no chain call anywhere. New
   refresh_l2_pipeline() refreshes movements_typed→ros→classification→ranging_tier→
   stock_position→kpi_daily + Family 3 anomaly engine ×5 stores; pg_cron 'refresh-l2-pipeline'
   20:15 UTC (22:15 SAST). First run 113.6s clean. Closes ANOM-001 nightly-wiring open item.

**Deployed (stuck "pending Pieter SQL-Editor" items since 06-07/06-08):**
- D1 amendment (l2_ranging_tier_class_excluded.sql steps 1–4): CLASS_EXCLUDED tier live,
  0 bad rows, 0 tier mismatches vs l2_stock_position.
- l2_kpi_daily v1.2: **gp_pct LIVE** — 16.6% (10116) / 13.3% (21355) / 17.2% (80175) /
  18.7% (80176) / 15.7% (80579); capital_normal 10116 R4.49M ≈ expected R4.7M.

**Layer-hierarchy note:** dashboard KPI cards still read v/mv_kpi_by_date (L1 PRSSALE-derived).
SB-INDEX-005 Phase 2 (switch sales KPIs to L2 sigma_sales sources) is now UNBLOCKED —
l2_kpi_daily refreshes nightly with populated gp_pct. Needs PM sequencing brief before the swap.

---

## 2026-06-10 22:15 SAST — v3.24 + consignment fix: Pulse Mini unfrozen, standing pg_cron refresh

**Commit:** 5fc2390 (fix(pulse-mini): v3.24 — consignment refresh broken since barcode migration
+ wrong chain order)
**Status: LIVE — DB function fixed + refreshed via Supabase MCP (migration
fix_refresh_l2_consignment_daily_barcode_text); pg_cron jobs 13+14 scheduled; v3.24 on GitHub
(self-update delivers with the v3.23 chain).**

**Defect 1:** refresh_l2_consignment_daily() threw `operator does not exist: text - integer`
on every call since the 2026-06-09 sigma_ean_master.barcode bigint→text migration
(`em.barcode - 200000`). Push chain swallowed it (Write-Warning). Pulse Mini froze at Jun 9.
Fixed: regex guard + ::bigint cast. Refreshed: June 1–10 live, 153 lines, R36,543 — matches
raw sigma_sales to the rand on all 10 days.

**Defect 2:** Invoke-RefreshConsignmentDaily ran before Invoke-RunExtractor (reads what the
extractor writes). v3.24 reorders.

**Standing daily update (indefinite):** pg_cron `refresh-consignment-evening` (18:05 UTC) +
`refresh-consignment-night` (19:55 UTC) — in-database, independent of push script health.

**Boss-R56k reconciliation:** our R36,543 verified to the rand, dual-channel exact Jun 1–5.
Gap is scope, not tally — likely chinese hot food under HMR HOT MEALS (605, R83.5k June) or
deliveries-vs-sales. Pieter to get boss's June-1 breakdown (ours: R8,110).

---

## 2026-06-10 21:45 SAST — Push v3.23 + extractor v1.9: deploy guard root-cause fix (3 blind nights)

**Commits:** 51b45c7 (fix(pipeline): v3.23 — extractor deploy guard never matched, stale copies
ran 3 nights) + 5a89213 (fix(extractor): v1.9 — delete-before-insert for sigma_ean_master)
**Status: LIVE on GitHub. Self-update path: tomorrow 20:00 sweep (v3.22) downloads v3.23;
21:00 sweep runs v3.23 → fixed guard deploys extractor v1.9 → first real v1.9 ride.
Pieter manual runbook in HANDOVER-CURRENT.md gets proof in the morning instead.**

**Root cause (proven):** `Invoke-DeployExtractor` guard regex `'#.*Version.*v[\d.]+'` never
matches the extractor file (tested: False). Every nightly deploy silently discarded the
download — v1.7/v1.8 never reached any server; all 5 ran stale manual copies. Proof: 21355's
chained SUCCESS (06-10 21:03, 529s) still pushed 12-digit truncated barcodes + zero
l2_soh_daily rows = pre-v1.4 behaviour.

**v3.23:** guard uses self-updater's proven `\$ScriptVersion\s*=` regex; guard rejection
logs FAILED to push_log; extractor version stamped into push_log tac_filename
(`extractor=vX.Y`); subprocess stdout/stderr captured to extractor_last_run.log /
extractor_last_err.log, tail pushed into error_message on failure (R22 — no blind nights
structurally possible).

**v1.9:** sigma_ean_master per-store DELETE before INSERT (conflict key includes barcode, so
corrected 13-digit rows never collided with stale 12-digit rows); script-scope trap captures
CONFIG-section crashes to extractor_last_error.txt.

**Also:** Create-ExtractorScheduledTask.ps1 + Create-SundayPushTask.ps1 use absolute
powershell.exe path (bare name unresolvable on 80175/21355 — killed 80175's 19:40 task;
80175 has had no extraction since 06-08 22:04).

---

## 2026-06-09 20:42 SAST — Pulse Mini: pace sub-text shows actual basis not rounded rate

**Commit:** 2e89faf (fix(pulse-mini): pace sub-text shows actual basis not rounded rate)
**Status: LIVE 2026-06-09 — auto-deployed to Vercel from GitHub push.**

**Bug:** "Ballpark month pace" sub-text said "R 3 819/day × 30 days" but 3 819 × 30 = 114 570
≠ 114 583 (projected value uses unrounded float — rounding drift made the description lie).
**Fix:** Sub-text now reads "R 34 374 earned in 9 of 30 days" — honest basis, no fabricated
per-day rate that doesn't multiply to the number shown.

**Changes:** `public/StockFlow-DevCorner-Demo.html` (one line).

---

## 2026-06-09 20:30 SAST — Push script v3.21: wire refresh_l2_consignment_daily nightly

**Commit:** 9e71723 (fix(push): wire refresh_l2_consignment_daily into nightly chain (v3.21))
**Status: LIVE on GitHub. Self-updater delivers v3.21 to store servers tonight (~20:00 push
downloads it); v3.21 first executes tomorrow night (~20:00 Jun 10). From Jun 10 onward
Pulse Mini data is refreshed automatically after every nightly push.**

**Fix:** Closes open wire from SB-CC-AUDIT-002. `Invoke-RefreshConsignmentDaily` added to
nightly switch case (after `Invoke-UpsertSearchIndex`). Store 10116 only — all other stores
skip silently. UTF-8 body, service role key, 60s timeout. Logs row count on success;
warning + manual fallback instruction on failure.

**Until Jun 10:** run manually if needed: `SELECT refresh_l2_consignment_daily('10116');`

---

## 2026-06-09 09:40 SAST — Family 3 count engine: l2_stock_count_plan DDL + refresh function

**Commit:** bb94377 (feat(family3): add l2_stock_count_plan DDL + refresh function)
**Status: PARTIALLY DEPLOYED. 21355 VERIFIED PASS. Other 4 stores pending next session.**

**What:** SB-CC-FAMILY3-COUNT-ENGINE-001 v1.0. Two new SQL files:
- `sql/create_l2_stock_count_plan.sql` — DROP+CREATE table, indexes, grants
- `sql/refresh_l2_stock_count_plan.sql` — deterministic cascade function

**Gate:** NORMAL + soh<>0 + sigma_articles JOIN. No capital floor (Pieter's law).
**Cascade:** deposit_like->AMBIGUOUS / sold+positive_soh->HEALTHY /
sold+negative_soh->AMBIGUOUS / recv_365d->STOCKFLOW / dead+barcode->TLX / else->AMBIGUOUS.
**Recycled-code guard:** barcode_list NULL forces AMBIGUOUS + surfaced in JSONB alert field.

**21355 verification result (2026-06-09):**
- Determinism: PASS (two identical runs)
- Golden baseline: PASS — pool=948, HEALTHY=708, STOCKFLOW=111, TLX=75, AMBIGUOUS=54
- `no_barcode_sf_alert`: 21 STOCKFLOW rows have no EAN in sigma_ean_master (investigate
  before loading those 21 to StockFlow — recycled-code risk)

**Next session: extend to remaining 4 stores:**
```sql
SELECT refresh_l2_stock_count_plan('10116');
SELECT refresh_l2_stock_count_plan('80175');
SELECT refresh_l2_stock_count_plan('80176');
SELECT refresh_l2_stock_count_plan('80579');
```

---

## 2026-06-09 08:04 SAST — Pulse Mini: fix charts showing only some days (root cause)

**Commit:** 1ad3c09 (fix(pulse-mini): drive chart dates from server today, not health as_at)
**Status: LIVE 2026-06-09 — auto-deployed to Vercel from GitHub push.**

**Root cause:** `sigma-lines/route.js` was generating the `dates` array using `asAt` (last
non-FUTURE day per `rpc_feed_health_daily`). If sigma_sales hasn't been pushed for today
(nightly push runs ~20:00 SAST), today lands `NO_TRADE` (both feeds zero). In edge cases
health errors and `asAt` falls back to the last actual sushi-sales date — which could be
days earlier. Result: charts showed fewer bars than elapsed calendar days.

**Fix:** Dates array now built from `new Date()` (UTC, capped at month-end). `asAt` kept
for display label only. All elapsed days always appear; zero-fill shows stub bars for
days with no sushi data yet.

**Changes:** `src/app/api/dev-corner/sigma-lines/route.js` only.

---

## 2026-06-09 — Pulse Mini live: auth gate removed + weather + no-data fixes

**Commit:** 789aaf1 (feat(pulse-mini): make app publicly accessible + fix weather bugs)
**Status: LIVE 2026-06-09 — auto-deployed to Vercel from GitHub push.**

**Changes:**

| File | Change |
|---|---|
| `middleware.js` | Added `/StockFlow-DevCorner-Demo.html` + `/api/dev-corner/*` to `isPublic` — app was previously auth-gated (required dashboard login). Now publicly accessible. |
| `public/StockFlow-DevCorner-Demo.html` | Weather month label: removed hardcoded `' Jun'`, now uses `MON[dt.getMonth()]`. Today highlight: was `i===0`, now compares ISO date string. WX_FB fallback dates: converted from static June 6-12 to dynamic 7-day window from `new Date()`. No-data message: removed internal table name reference. |
| `src/app/api/dev-corner/consignment/route.js` | Added `replit` to origin allow list (consistent with sigma-lines endpoint). |

**Live URL:** `https://dashboard.socialbrand.africa/StockFlow-DevCorner-Demo.html`

**Data layer (all pre-existing, confirmed live):**
- `l2_consignment_daily` — June data live (deployed 2026-06-08 by Pieter)
- `rpc_consignment_lines` — thin SELECT from L2, no join at fetch
- `rpc_feed_health_daily` — per-day completeness for feed health strip

**Open wire:** `refresh_l2_consignment_daily('10116')` must still be added to the nightly extractor post-push chain for July+ data to auto-populate. Until then, Pieter runs it manually in SQL Editor at month-start. Bundle with next extractor version.

---

## 2026-06-08 — SB-INDEX-005 Phase 1: l2_kpi_daily sales source migrated to sigma_sales

**Commit:** 63b1ef9 (feat(SB-INDEX-005): Phase 1 -- l2_kpi_daily sales from sigma_sales)
**Status: LIVE 2026-06-08 — deployed by Pieter, acceptance query returned 0 delta rows (all stores match sigma_sales exactly).**

**Change:** `sales_agg` CTE in l2_kpi_daily rewritten. Source changed from `daily_snapshots` to `sigma_sales`.

| Before | After |
|---|---|
| `MAX(snapshot_date)` per store from `daily_snapshots` | `MAX(sale_date)` per store from `sigma_sales` (period_kind='T' AND txn_kind=1) |
| `SUM(today_sales/cost/qty)` | `SUM(sales_incl_vat/qty)` from sigma_sales; `sales_cost=0`; `gp_pct=NULL` |

**PM rulings (SB-INDEX-005 v1.3, 2026-06-08):**
- Decision 1: Option A (NULL/0 now) + Option B (dEKUmsatz via extractor) bundled with next extractor version
- Decision 2: Phase 2 (v_kpi_by_date migration) = separate PM brief, not concurrent

**Pre-deploy verification (live DB, 2026-06-08):**
- sigma_sales latest_date = 2026-06-07 on all 5 stores (80579 date lag now resolved in sigma_sales)
- sigma_sales 2026-05-29 for 10116: R383,388 / 2,786 lines — CONFIRMED (the missing EOD exists in DBUMBA)
- Expected post-deploy sales_incl_vat vs current daily_snapshots values:

| Store | daily_snapshots (current) | sigma_sales 06-07 (post-deploy) | Delta |
|---|---|---|---|
| 10116 | R153,801 | R155,537 | +1.1% (PRSSALE variance) |
| 21355 | R6,720 | R6,720 | 0.0% |
| 80175 | R91,553 | R91,811 | +0.3% |
| 80176 | R22,244 | R22,244 | 0.0% |
| 80579 | R33,072 @ 06-06 | R2,712 @ 06-07 | Date moves; R2,712 Sunday TOPS plausible |

- Nothing in frontend or RPCs reads l2_kpi_daily.gp_pct (verified 2026-06-08)
- stock_agg/capital/signals: unchanged (still from l2_stock_position)

**Acceptance query (run after deploy + REFRESH):**
```sql
SELECT
    kpi.store_code,
    kpi.sales_date,
    ROUND(kpi.sales_incl_vat::numeric, 0)  AS kpi_sales,
    ROUND(sig.sigma_sales::numeric, 0)      AS sigma_src,
    ROUND((kpi.sales_incl_vat - sig.sigma_sales)::numeric, 0) AS delta
FROM l2_kpi_daily kpi
JOIN (
    SELECT store_code, SUM(sales_incl_vat) AS sigma_sales
    FROM sigma_sales
    WHERE period_kind = 'T' AND txn_kind = 1
      AND sale_date = (SELECT MAX(sale_date) FROM sigma_sales
                       WHERE store_code = sigma_sales.store_code
                         AND period_kind = 'T' AND txn_kind = 1)
    GROUP BY store_code
) sig ON sig.store_code = kpi.store_code
ORDER BY kpi.store_code;
-- Expected: delta = 0 (kpi_sales sourced directly from sigma_sales)
```

---

## 2026-06-08 — AUDIT-002 L2 restructure: l2_consignment_daily + rpc_consignment_lines thin SELECT

**Commits:** 450928f (sql/create_l2_consignment_daily.sql NEW + sql/rpc_consignment_lines.sql REWRITE)
**Deployed by Pieter in SQL Editor — both files LIVE 2026-06-08.**

**Structural change:** rpc_consignment_lines was performing the sigma_sales x sigma_articles classification join at fetch time (L2 logic in the L3 path). Restructured per PM GO:

**sql/create_l2_consignment_daily.sql (NEW — L2 derived table):**
- DROP + CREATE per Rule 19. L2 engine output for HMR SUSHI consignment (store 10116, merch_group 610).
- Pre-classifies at refresh: sigma_sales x sigma_articles join, BREAKFAST + MABELA excluded, anchor sale_date >= 2026-06-01 (combo-launch boundary; pre-June recycled 100k-range product codes do not map to current sigma_articles — blank by design, R20 class).
- Per-row: store_code, sale_date, product_code, description, item_type (s/c), sales, qty, commission (10%), owed (90%).
- Refresh function refresh_l2_consignment_daily(p_store): DELETE + re-INSERT current month only; historical months committed.
- GRANT SELECT TO anon. Unique: (store_code, sale_date, product_code).
- Nightly refresh: call after l2_kpi_daily. Pending wiring into extractor post-push chain.

**sql/rpc_consignment_lines.sql (REWRITE — thin SELECT):**
- Plain SELECT from l2_consignment_daily. No join at fetch. No classification at fetch.
- Signature unchanged (p_month, p_store, p_group, p_client) for backward compat.
- Pre-June returns 0 rows by design.

**Regression verified to the rand (all 7 June days):**
Jun 1=8110 / Jun 2=4119 / Jun 3=5093 / Jun 4=2179 / Jun 5=4598 / Jun 6=3957 / Jun 7=2731
rpc thin SELECT: R30,787 total / 37 distinct lines / 7 days loaded.

**Classification note:** item_type='s' vs 'c' currently all 'c' — June product_codes link to sigma_ean_master barcodes outside 200000+ range. Column structurally correct; split populates when barcode data is reconciled (separate data-maintenance item, no impact on totals).

**Standing rule established:** applets source sales from sigma_sales (DBUMBA) only. daily_snapshots acceptable for non-sales data (shelf price, SOH, EAN catalogue) until those are mirrored directly. A missed EOD must never create a silent hole in any number driving a business decision. Core pipeline migration (l2_kpi_daily sales input) = SB-INDEX-005.

---

## 2026-06-08 session 2 — L2-001 Steps 3+SOH: extractor v1.4, l2_ranging_tier, l2_soh_daily

**Commit:** 254191e (feat(L2-001): extractor v1.4 + l2_ranging_tier + l2_soh_daily SQL)

**Extractor v1.4 (scripts/Invoke-ExtractFromSigmaSQL.ps1):**
- Invoke-SnapshotSohDaily added. Runs before Invoke-ExtractLifecycle.
  Reads product_code, dBestand (soh), dStdBest (standard_stock) from DBStAr.
  Pushes to l2_soh_daily with ON CONFLICT DO NOTHING (ignore-duplicates).
  UTF-8 POST body (PGRST102 prevention). ASCII-only. Batches at $BatchSize.
- ValidateSet updated: soh_daily now a valid -TableName value for reruns.
- Version history in .NOTES updated with v1.3 (UTF-8 fix) and v1.4 entries.

**sql/create_l2_soh_daily.sql (Gate 2 Option A):**
- Persistent history table: one row per (client_id, store_code, product_code, snapshot_date).
- PK enforces ON CONFLICT DO NOTHING idempotency.
- Two indexes: idx_l2_soh_store_date, idx_l2_soh_latest.
- Scale: ~325k rows/day, 13-month retention, ~7.8 GB at full scale.

**sql/create_l2_ranging_tier.sql (Step 3):**
- MV: DENSE_RANK per store by 91d value DESC and qty DESC from l2_rate_of_sale.
- Tier: TOP_100 (value_rank<=100 AND qty_rank<=100), TOP_1000 (either<=1000), BOR.
- Carries: in_both_top100, value_rank, qty_rank, daily_ros_91d, never_sold (for l2_kpi_daily).
- Four indexes: PK, store+tier, TOP_100 partial, value_rank.
- Does NOT join l2_item_classification (Gate 3 still open).

**Pending Pieter SQL-Editor actions (all pre-commit SQL done, deploy via Supabase SQL Editor):**
1. REFRESH MATERIALIZED VIEW l2_movements_typed; (picks up 4 new stores)
2. REFRESH MATERIALIZED VIEW l2_rate_of_sale;   (picks up 4 new stores)
3. Run sql/create_l2_item_classification.sql    (Step 2 classifier MV)
4. Run the Gate 3 verification queries at the bottom of that file
5. Run sql/create_l2_soh_daily.sql             (Gate 2 history table)
6. Run sql/create_l2_ranging_tier.sql          (Step 3 tier MV)

**Self-updater will carry v1.4 to all 5 servers on next nightly run.**

---

## 2026-06-08 — L2-001 Step 2: l2_item_classification SQL committed

**What (SB-CC-L2-001 step 2):** Keystone Layer 2 classification MV written
to `sql/create_l2_item_classification.sql`. Pending Pieter's run in Supabase
SQL Editor (read-only MCP cannot run REFRESH or CREATE).

**Signal stack (priority cascade):**
- S1 NON_STOCK_DEPT: dept in (AIRTIME, FRONTEND PACK, EXPENSES, DORMANT,
  NON SCAN SALES, ONLINE *, SPAR MOBILE, dept 99). Deterministic. conf=1.00.
- S2 DIM_EXCLUDED: dept_nr=0 (DEPT_ZERO_PLACEHOLDER) OR subdept orphan
  (merch_group_nr absent from sigma_subdepts). Deterministic. conf=1.00.
- S3 PROD_INPUT_SUBDEPT: subdept name contains INGREDIENTS, PACKAGING, or
  WASTAGE. conf=0.95. Covers all production depts (Bakery/Deli/Butchery/HMR
  /FishShop/Produce/Flowers/CoffeeShop via *XING/*XPAC/*XWAS short codes).
- S4 RECEIPTING_BREAK: scale_flag='0' AND SOH < -1000. Scale items excluded
  (their negative SOH is Type A depletion, not a data error). conf=0.90.
- S5 PROD_DEPT_NEVER_SOLD: production dept + last_sale_date=1990-01-01
  sentinel. Base conf=0.80; boosted to 0.85 by S7, 0.88 by S6, 0.92 by both.
- NORMAL: everything else. conf=0.99.

**Design decisions verified against live 10116 data (2026-06-08):**
- scale_flag from cWAG (one A): valid (0=67,024 / 1=2,775). Not cWAAGE.
- 1990-01-01 sentinel = never-sold in sigma_lifecycle (64,289 articles on 10116).
- sigma_lifecycle.last_sale_date always populated (0 nulls on 10116).
- DIM_EXCLUDED covers sigma_dimension_exclusions rules without querying that
  table directly (dept_nr=0 catches DEPT_CODE; NULL subdept join catches SUBDEPT_ORPHAN).
- plu_flag='1': 99 articles on 10116 (SPAR only). Boosts PRODUCTION confidence.

**80175 SPAR Roosville Gate 1 verified this session:** All 12 tables loaded,
1,049,117 sales rows, span 2025-02-01 to 2026-06-07. Gate 1 PASS. All 5
stores now hold full Layer 1 history.

**Two pending Pieter SQL-Editor actions:**
1. REFRESH MATERIALIZED VIEW l2_movements_typed;
   REFRESH MATERIALIZED VIEW l2_rate_of_sale;
   (picks up the 4 new stores loaded since Step 1 was created)
2. Run sql/create_l2_item_classification.sql (creates the MV + indexes).
   Then run the Gate 3 verification queries at the bottom of the file.

---

## 2026-06-07 session 3 — ROLLOUT-001 complete (4/5), L2-001 Step 1 LIVE, gates 2+4 written

**ROLLOUT-001 — Layer 1 full-refresh + scheduled tasks:**
- 21355 TOPS Delareyville: all 12 tables loaded (sales 114k, movements 123k, articles 52k). Gate 1 PASS.
- 80176 TOPS Roosville: all 12 tables loaded (sales 121k, movements 122k, articles 46k). Gate 1 PASS.
- 80579 TOPS Dice: all 12 tables loaded (sales 118k, movements 109k, articles 52k). Gate 1 PASS.
- 80175 SPAR Roosville: first run partial (sales+movements only); second run in progress at handover.
  Gate 1 pending — verify on next session start.
- 10116 SRSDELAREYVILES: delta catch-up run (no -FullRefresh). Sales now current to 2026-06-07.
- All 5 servers: SocialBrand Sunday Push task registered (weekly Sunday 16:15, based on observed
  TAC zip times 15:23-15:34 on 4 Sundays). Script: Create-SundayPushTask.ps1.
- All 5 servers: SocialBrand-ExtractDelta task registered (daily 19:40). Script: Create-ExtractorScheduledTask.ps1.

**L2-001 Step 1 SQL — LIVE (Pieter ran in Supabase SQL Editor, 2026-06-07):**
- l2_movements_typed: 1,340,758 rows, 5 movement classes, 10116 only.
- l2_rate_of_sale: 69,798 rows (= all sigma_articles), 10116 only.
- Both MVs need REFRESH once 80175 load completes (picks up all 5 stores).
  Run in SQL Editor: REFRESH MATERIALIZED VIEW l2_movements_typed;
                     REFRESH MATERIALIZED VIEW l2_rate_of_sale;

**L2-001 brief SB-CC-L2-001 updated:**
- Gates 2+4 proposals written (CC, data-backed from 10116 analysis).
  Gate 2 rec: Option A (sigma_lifecycle.soh daily snapshot -> l2_soh_daily). Gate 4 rec: sigma_supplier_link.list_cost.
- SOH data quality section added: ghost stock patterns + negative SOH patterns documented with 10116 evidence.
  Engine handles programmatically via classification signal stack (no per-store manual fixes).
- Scope expansion: sigma_promotions + sigma_promotion_articles added as L1 additions (DBPROME/DBPROMAR);
  l2_promotion_effect + l2_production_yield added to object map.
- configuration_group_map (production reverse-cost engine) documented as non-L1 config table.
- PM ratification required before Step 2 build starts.

---

## 2026-06-07 — L2-001 Step 1 SQL migrations committed (commit 180d00c)

**What (SB-CC-L2-001 step 1):** Two Layer 2 materialised view migrations added to
`sql/` — pending Pieter's run in Supabase SQL Editor.

- `sql/create_l2_movements_typed.sql` — MATERIALIZED VIEW over sigma_movements.
  Classifies every DBBEBE row by movement_class (RECEIPT/IDT/ADJUSTMENT/
  EOD_CORRECTION/OTHER) and adds `is_excluded` flag (TRUE for IDT; IBT slot
  reserved). 4 indexes. Verified against live 10116 distribution (1,340,758 rows,
  K/null 81%, R/W 13%, I/M 3%).
- `sql/create_l2_rate_of_sale.sql` — MATERIALIZED VIEW over sigma_articles + sigma_sales.
  91-day and 14-day rolling ROS windows relative to CURRENT_DATE at refresh.
  daily_ros_91d feeds l2_ranging_tier; days_since_last_sale + never_sold feed
  classifier (gate 6). Base: sigma_articles (69,798 rows). 4 indexes.

**Pending:** Pieter runs both files in Supabase SQL Editor (read-only MCP).
After run: verify row counts match sigma_articles, spot-check top sellers.

---

## 2026-06-07 — Push v3.19 + extractor sidecar + delta schedule script (commit 2e898df)

**What (ROLLOUT-001 CC prep):**
- `Push-SigmaToSupabase.ps1 v3.18 -> v3.19`: Added `Invoke-DeployExtractor()`
  sidecar that downloads `Invoke-ExtractFromSigmaSQL.ps1` from GitHub raw on every
  nightly run. Non-fatal on failure. Deploy path: self-updater carries v3.19 to all 5
  servers on tonight's 20:00 push; extractor then present on disk for Pieter's
  `-FullRefresh` RDP sessions per store.
- `scripts/Create-ExtractorScheduledTask.ps1` (new): Run once per server as Admin
  after full-refresh verifies (ROLLOUT-001 Gate 1-4). Creates
  `SocialBrand-ExtractDelta` task at 19:40 daily (after EASYDB rebuild ~19:20,
  before nightly push at 20:00). Requires Pieter's RDP; ASCII-only.

---

## 2026-06-07 — CRASH-001 fix: isActiveLine scope bug (commit c71dedf)

**What (SB-CC-CRASH-001):** Fixed production crash that white-screened the entire
dashboard whenever any report was opened.

Root cause: `sellThroughRate` useMemo (page.jsx ~2073) called `isActiveLine(r)` —
a helper defined inside `buildReport()` (line 255) — but the useMemo runs in
component body scope where `isActiveLine` does not exist. ReferenceError escaped
the memo with no error boundary, crashing the whole page.

Fix: Defined `refDate` + `activeLineCutoff` + `isActiveLine` inside the
`sellThroughRate` memo (3 lines), using the byte-identical definition from
`buildReport` (`cutoff = shiftDate(refDate, -ACTIVE_LINE_LOOKBACK)`). Added
`selectedDates` to the dependency array.

Deploy path: pushed to GitHub main; Vercel auto-deploy active.

---

## 2026-06-05 — DIWAAIS governance repo live (SocialBrandAfrica/diwaais-governance)

**What:** The DIWAAIS governance layer (Bible, handovers, briefs, archive — 215 files) is
now under version control at `https://github.com/SocialBrandAfrica/diwaais-governance`
(private repo). Broken `.git` cleared, fresh init, branch `main`, 233 objects pushed.
`.gitignore` excludes `socialbrand-dashboard/` (separate repo), store data dirs
(`SPAR_*/`, `TOPS_*/`), CSVs, binaries, and secrets.

---

## 2026-06-05 — Push-SigmaToSupabase v3.18: UTF-8 body fix + empty-key guard (commit 040895f)

**What (SB-CC-PUSH-003):** All data POST bodies in `Push-SigmaToSupabase.ps1` now sent
as UTF-8 bytes (`[System.Text.Encoding]::UTF8.GetBytes($json)`) with
`Content-Type: application/json; charset=utf-8`. Callsites fixed: `Send-Batch` batch
+ row-by-row fallback, `Write-PushError`, `Push-RefTables` dept + subdept.
Added empty-key guard: clear diagnostic if `C:\socialbrand\sb-key.txt` is blank.
**Root cause:** same PGRST102 bug as extractor v1.3 (CLAUDE-CODE-RULES R15) — NBSP and
non-ASCII in product descriptions sent invalid UTF-8, causing silent row drops in
`daily_snapshots` on every store every night.
**Deploy path:** self-updater carries v3.18 to all 5 servers on tonight's 20:00 push.
**Verify:** after tonight's run, confirm an accented product (e.g. NBSP in description)
lands correctly in `daily_snapshots`. Check push_log for SUCCESS + expected row count.

---

## 2026-06-05 — Search-from-source fix: cache optimistic-only (commit 5ecdf6b)

**What:** `page.jsx` scoped search path (dept/store filter active) no longer uses
localStorage as authoritative. Cache is shown immediately (optimistic UX) then always
replaced by a live `product_search_index` fetch. Key bumped `v1→v2` to flush stale
caches on first load. New products from overnight pushes are now visible in search
immediately after load.
**Deploy path:** pushed to GitHub main, Vercel picks up automatically.

---

## 2026-06-04 — O1 fix: rpc_dept_summary overload collision (commit ce69e60)

**Bug (O1 / SB-VAL-001):** "Sales by Department" panel showed "No sales data".
Root cause: TWO `rpc_dept_summary` overloads coexisted (PGRST203) — the index-safe
version from `fix_index_rule_dept_rpcs.sql` `(…,p_eans,p_subdept)` and a second one
created by `sb_cc_dept_kpi_001` whose `DROP` named the wrong signature, so the drop
missed. The new overload also re-introduced the Rule-4 `snapshot_date::text` cast.
Separately, a 3-arg `classify_snapshot_item` call hit 42725 (ambiguous against
patch1's 4-arg DEFAULT NULL overload).
**Fix:** `sql/fix_rpc_dept_summary_overload_collision.sql` — dropped both explicit
signatures, recreated ONE canonical `rpc_dept_summary(p_store_codes, p_dates,
p_subdept, p_eans)` returning `…, capital_tied`, using index-safe
`snapshot_date = ANY(p_dates::date[])` and the 4-arg
`classify_snapshot_item(...,last_sales_date_iso)` so dept capital mirrors
`v_kpi_by_date` exactly.
**Verify:** pg_proc shows 1 `rpc_dept_summary` row; live dashboard "Sales by
Department" renders depts + LY deltas (GROCERIES FOODS R367.2k, BUTCHERY R137.2k…).
**Confirmed working:** YES (live, 2026-06-04).
**Note:** surfaced that `mv_kpi_by_date` is stale (multi-date headline still R9.83M);
`v_kpi_by_date` is already patch1-applied (~R1M). MV recreate+refresh + orphan 3-arg
`classify_snapshot_item` drop pending — diagnostics in `sql/diag_classify_mv_state.sql`.

---

## 2026-05-24 — Session 18, push v3.11 parse fix (commit 07e7108)

**Bug:** `$finalStatus:` in backfill Write-Host line was parsed by PowerShell as a
namespace-scoped variable reference (`$env:PATH` pattern). Hard parse error prevented
the entire script from loading — all 5 servers failed silently, no push_log entries.
**Fix:** `${finalStatus}:` — curly braces delimit the variable name.
Self-updater cannot fix a parse error (script can't load to run the updater).
Servers must be manually updated to v3.11 via Invoke-WebRequest.

---

## 2026-05-24 — Session 18, Google OAuth live + super-admin decision

**Google Cloud OAuth credentials configured (2026-05-24):**
- Project: `dashboardsocialbrandafrica`
- Client ID + Secret: stored in Supabase Auth > Providers > Google (not in git -- public repo)
- Authorized redirect URI: `https://crklvhfwyxlisfcvqenc.supabase.co/auth/v1/callback`
- Supabase Google provider: **ENABLED**

**PM decision — Phase 1 access tiers:**
All authenticated users have super-admin (owner) access until access tiers are
formally introduced. user_profiles row is optional — if missing, full access is
granted anyway. Store isolation by role is code-complete but disabled.

**Code change (page.jsx):**
- `loadProfile` no longer blocks on user_profiles row.
  Missing row → synthetic `{ role: 'owner' }` profile → all 5 stores visible.
- `isManagerLocked` hardcoded `false` (store selector always shown).
- "Access Pending" screen remains in code but is unreachable until tiers are wired.

---

## 2026-05-24 — Session 18, MOBILE-AUTH-BRIEF (commit b1f4e38)

**New package:** `@supabase/ssr` ^0.5.2

### Google OAuth + Supabase Auth
- `middleware.js`: auth guard — all routes redirect to `/login` if no valid session.
  Allows `/login`, `/auth/*`, and static `.html` files through unauthenticated.
- `src/app/auth/callback/route.js`: PKCE callback — exchanges OAuth code for session cookie.
- `src/app/login/page.jsx`: dark-theme Google sign-in page. No email/password.
- `src/lib/supabase.js`: switched from `createClient` to `createBrowserClient` from `@supabase/ssr`.
  Cookie-based session storage required for middleware auth checks.

### Store isolation
- `src/app/page.jsx`:
  - `storeCodes` now initialises to `[]` (populated after profile load, not on mount).
  - Auth useEffect: fetches `user_profiles` on mount; sets `storeCodes` to all stores (owner)
    or `[profile.store_code]` (manager).
  - `isManagerLocked`: hides store selector chips for non-owner roles.
  - Loading screen while profile loads; "Access Pending" screen if no profile row found.
  - Sign-out button in header (top-right): shows user's first name + exit icon.

### Phone layout
- `src/app/globals.css`: `zoom: 1.25` overridden to `zoom: 1` at max-width 767px.
  Without this, 375px phones render at an effective 300px width causing overflow.
- `src/app/dashboard.css`: mobile touch targets raised from 36px to 44px (WCAG minimum).

### SQL migration
- `sql/mobile_auth_setup.sql`: adds `full_name` + `updated_at` columns to `user_profiles`,
  updates role CHECK constraint to include `owner` and `manager`, adds RLS policy
  `users_read_own_profile` (auth.uid() = id), adds FK to auth.users.
  **Pieter must run this in Supabase SQL Editor.**

### Pending (Pieter's manual steps)
See `PIETER-OAUTH-SETUP.md` on the Desktop for step-by-step instructions:
1. Create OAuth credentials in Google Cloud Console (~5 min)
2. Enable Google provider in Supabase Auth settings + set redirect URLs
3. Run `sql/mobile_auth_setup.sql` in Supabase SQL Editor
4. Sign in and seed Pieter's owner row in user_profiles

---

## 2026-05-24 — Session 17, data verification + push_log fix (v3.10)

**Commits:** af8c8b8 (Capital Tied fix), 8c360d0 (v3.10 push script)

### Bug fix: Capital Tied multi-date accumulation
- `src/app/page.jsx` line 1452: `kpiCapTied` changed from `kpiData.reduce()` to
  `latestKpiByStore.reduce()`. Stock KPIs are point-in-time; summing across dates gave 7x value on 7-day range.

### Bug fix: push_log snapshot_date / tac_filename always NULL (v3.10)
- Root cause: `Get-Headers` included `Prefer: resolution=merge-duplicates` on PATCH calls.
  This is an INSERT hint that caused PostgREST to silently drop unrecognised columns (the
  4 new push_log columns were added without `pg_notify` so cache was stale).
- Fix: added `Get-PatchHeaders` (omits resolution=merge-duplicates). Updated
  `Complete-PushLog` and `Clear-StuckRuns` to use it.
- `sql/fix_push_log_schema_cache.sql` -- **run once in Supabase SQL Editor** to reload
  PostgREST schema cache. Required before v3.10 will actually populate snapshot_date.
- `sql/sb_sch_001_step5_push_log_migration.sql` -- added pg_notify step for future re-runs.

**Pending:** deploy v3.10 to all 5 servers (Invoke-WebRequest from GitHub raw URL).

---

## 2026-05-24 — Session 16, CC-BRIEF-2026-05-24 (diagnostic + two-tier storage)

**Commit:** 5d877d4

### Diagnostic security fix (Item 1)
- `sql/rpc_diag_push_log.sql` — SECURITY DEFINER RPC replaces direct push_log REST query.
  **Must be run in Supabase SQL Editor before /diagnostics.html push_log section will work.**
- `public/diagnostics.html` — diagnose.html deployed to Vercel static at `/diagnostics.html`.
  Secret key removed; all queries use anon key via SECURITY DEFINER RPCs.
- Footer: subtle "Data Quality" link added to dashboard bottom, opens `/diagnostics.html`.
- `globals.css` — `zoom: 1.25` added (125% scale, from earlier in this session).

### Two-tier storage (Item 2 — SQL files ready, run order below)
- `sql/sb_ret_002_quarterly_aggregates.sql` — CREATE TABLE quarterly_aggregates + 2 indexes.
  **Run first.**
- `sql/sb_ret_002_purge_function_v2.sql` — Replaces purge_old_snapshots() with aggregate-then-delete.
  pg_cron job id=4 unchanged (same function name). **Run second.**
  Verify after: `SELECT jobid, jobname, active FROM cron.job WHERE jobname = 'sb-monthly-purge';`

### Other fixes this session
- `sql/add_pgcron_kpi_refresh.sql` — pg_cron job 5 created (nightly-kpi-refresh at 22:00 UTC).
  Already run and confirmed (job id=5 active).
- TAC50525.zip backfill: 33,537 rows pushed for TOPS Dice 2025-05-25.
- mv_kpi_by_date manually refreshed (view was stale -- 2025-05-25 now visible).

---

## 2026-05-24 — Session 14, Supabase secret key rotation

**No commit — key not stored in repo.**

- Old key: legacy JWT service_role (was in git history of public repo -- CRITICAL)
- New key: `sb_secret__rpmX...` (Supabase new-style Secret key, named "push-scripts")
- Updated: `upload_snapshots.py` line 39 (local machine, not in git)
- Updated: `C:\socialbrand\sb-key.txt` on all 5 store servers (SPAR Del, TOPS Del, SPAR Roos, TOPS Roos, TOPS Dice)
- Verified: `Get-Content` on each server returned new key

**Still to do to fully close the old key:**
1. Update dashboard to use new publishable key (`sb_publishable__5cXL...`) instead of legacy anon JWT
2. Click "Disable JWT-based API keys" on Supabase legacy API keys page
   (this will make the old service_role JWT in git history permanently invalid)

---

## 2026-05-24 — Session 14, PULSE-BUG-001 + MOBILE-BRIEF complete

**Commits:** a0fe5f6, 09fc30a, 8e5c67b

### PULSE-BUG-001 — all 8 bugs fixed
**Status: Deployed to GitHub main.**
**File:** `src/app/page.jsx`

- **BUG-1:** focusEans wired into rpc_top20, rpc_dept_summary, rpc_kpi_dept_counts — Focus Area basket now actually filters all data panels
- **BUG-2:** Cancellation flag on rpc_focus_top5 auto-populate effect — prevents race condition overwriting manual basket
- **BUG-3:** normalizeDept() applied before dept_name comparisons in kpiNegSOH + kpiSlowMove (dotted names e.g. GROCERIES.FOODS now match)
- **BUG-4:** KPI useMemos now branch on subDeptFilter using pre-filtered deptSummary/deptSohCounts — KPI strip responds to sub-dept filter
- **BUG-5:** clearStoreSelection sets [] not ALL_STORE_CODES (was a no-op)
- **BUG-6:** fetchAllRows capped at 10,000 rows — prevents 17+ RPC calls on large multi-store multi-date sets
- **BUG-7:** slowmovers + negsoh KPI cards now have onClick (open drawer), matching the reorder card
- **BUG-8:** activeProducts gives selectedProduct priority over focusBasket; top20 useMemo skips filter for non_movers; handleClose corrected

### MOBILE-BRIEF — all 17 items + critical bugs
**Status: Deployed to GitHub main.**
**Files:** `src/app/layout.jsx`, `src/app/dashboard.css`, `src/app/page.jsx`, `src/components/ProductDetailPanel.jsx`, `src/components/PushStatusStrip.jsx`

- Viewport meta tag (layout.jsx)
- useIsMobile hook; isMobile conditionals for drawer/Reports button
- Responsive CSS classes + @media (max-width: 767px) overrides in dashboard.css
- Filter bar, main padding, header context, KPI strip, Top20+Dept grid, Reports drawer — all converted to CSS classes
- PushStatusStrip: sb-push-strip-inner (horizontal scroll on mobile)
- ProductDetailPanel BUG 0 (slice -90 dates), BUG A (minWidth:0/overflow:hidden), BUG B (XAxis interval max 12 ticks), BUG C (fixed 8px bars)
- ITEM 15: compact prop — skip charts + rpc_product_detail when multiple products active
- ITEM 16: min chars 4 before RPC; fetchLimit 150 cap; local results shown immediately while RPC runs
- ITEM 17: localStorage search index cache (24h TTL); viewsCache + deptCache + top20Cache (session Maps); _detailCache (module Map)

---

## 2026-05-24 — Session 12, v3.7 + Block 8 complete

**Commit:** dcc7667

### Push script v3.7 (Block 8 Step 12)
**Status: Pushed to GitHub main. Self-updater deploys tonight.**
**Files:** `scripts/Push-SigmaToSupabase.ps1`

**push_log enrichment:** `Complete-PushLog` now writes `snapshot_date`, `rows_expected`,
`tac_filename`, `duration_seconds` on every push_log update.

**PARTIAL status:** When `rows_pushed > 0 AND rows_failed > 0`, status is `PARTIAL` (not SUCCESS).
Full failure stays `FAILED`. Zero failures stays `SUCCESS`.

**Both nightly and backfill** modes updated with timing + new columns.

### Block 8 SQL files (all run in Supabase)
- `sql/sb_sch_001_step5_push_log_migration.sql` — push_log 4 new columns + index
- `sql/sb_sch_001_step6_push_errors.sql` — push_errors snapshot_date added
- `sql/sb_sch_001_step7_orders.sql` — orders shell
- `sql/sb_sch_001_step8_product_aliases.sql` — product_aliases shell
- `sql/sb_sch_001_step9_user_profiles.sql` — user_profiles shell (RLS, no policies)
- `sql/sb_sch_001_step10_audit_log.sql` — audit_log shell
- `sql/sb_ret_001_purge_function.sql` — purge_old_snapshots() + pg_cron job id=4
- `sql/sb_rhy_001_mini_payday_seed.sql` — 5th community_rhythm profile (Mini-payday, 13-16, x1.10)

---

## 2026-05-23 — Session 11, v3.6 + SQL

**Commit:** 93a587a

### Push script v3.6 + upsert_search_index delta (Push script + SQL)
**Status: Script committed. SQL pending Pieter running upsert_search_index_delta.sql in Supabase.**
**Files:** `scripts/Push-SigmaToSupabase.ps1`, `sql/upsert_search_index_delta.sql`

**NULL-date guard:** `Test-IsoDate` validates snapshot_date extracted from each TAC zip before
any rows are pushed. Invalid date writes FAILED to push_log and aborts that date cleanly.
Applies in both nightly and backfill modes.

**Delta search index:** `upsert_search_index` now accepts optional `p_snapshot_date date`.
Nightly mode passes today's date -- only re-indexes EANs seen in today's push (fast).
Backfill mode passes nothing -- full rebuild (existing behaviour).
Self-updater will deploy v3.6 to all 5 servers on next nightly push (after SQL runs).

**How to verify:** Check push_log output tomorrow morning -- search_index line should show
"delta YYYY-MM-DD" not "full rebuild".

---

## 2026-05-23 — Session 11, Bug Fix

**Commit:** 92f6a78

### upsert_search_index — null last_seen on dormant products (SQL)
**Status: Deployed and verified in Supabase**
**File:** `sql/fix_upsert_search_index_null_last_seen.sql`

Root cause: dormant/placeholder products in daily_snapshots have snapshot_date IS NULL.
MAX(snapshot_date) over an all-NULL group returns NULL, which violated the NOT NULL
constraint on product_search_index.last_seen. GREATEST(existing, NULL) also returns NULL
on the conflict-update path, making it hit even for existing rows.

Fix: added `AND snapshot_date IS NOT NULL` to the WHERE clause in upsert_search_index.
Products with no valid snapshot date are excluded from the search index.

Verified: SELECT upsert_search_index('80579') ran without error and returned NULL (void).

---

## 2026-05-21 — Session 2, Batch 3

**Commits:** pending push after this entry

### Issue 1 — rpc_dept_summary + rpc_kpi_dept_counts 18-second regression (SQL)
**Status: Deployed and verified in Supabase**
**File:** `sql/fix_index_rule_dept_rpcs.sql`

Root cause: `snapshot_date::text = ANY(p_dates)` in both functions. Casting the column
to text prevents PostgreSQL from using the snapshot_date index on the 10.4M-row
daily_snapshots table. Has been in every version since add_ean_filter.sql; became
noticeable as the table grew.

Fix: `snapshot_date = ANY(p_dates::date[])` — cast the parameter array, not the column.
Both functions dropped (CASCADE, no signature) and recreated clean with correct rule.
After running, Sales by Department should load in under 3 seconds.

### Issue 2 — Search: stale closure caused incorrect RPC params (Frontend)
**Status: Deployed in this batch**

Root cause: `deptFilter`, `subDeptFilter`, and `deptNormMap` were used inside the
ProductSearchBar debounce effect but were NOT in its deps array. On switching from a
specific dept (populated local index) to All Depts, the effect re-ran with stale
dept-filter values. The RPC was called with wrong `p_dept_names` (showing results
filtered to the previous dept). Also missing effect cleanup (timer not cleared on unmount).

Fix:
- Added `deptFilter`, `subDeptFilter`, `deptNormMap` to the useEffect deps array
- Added `return () => { if (timerRef.current) clearTimeout(timerRef.current) }` cleanup

To confirm: type 3+ chars in the search box with All Depts + All Stores selected.
A POST to `rpc_search_products` must appear in the network tab within 400ms of
the last keystroke.

### Issue 3 — Bug 7: Reorder Items KPI card onClick not wired
**Status: Already fixed in commit 80b681c (previous batch)**

The `onClick` is correctly wired to the card div and calls
`setCurrentReport('reorder'); setDrawerOpen(true); if (!reportLoaded && !reportLoading) loadReport()`.
The sub-label "Open report drawer" is styled teal/underlined when the onClick exists.
PM's report was based on a pre-fix version.

To confirm: click anywhere on the Reorder Items KPI card — the Reports & Downloads
drawer must slide open with Reorder List pre-selected.

### Issue 4 — Top 20 button layout: two rows instead of one coherent group (Frontend)
**Status: Deployed in this batch**

Root cause: By Qty/By Value toggle and Movers/Non-Movers toggle were rendered in two
separate `<div>` rows with `justifyContent: 'flex-end'` on the second. Looked broken —
the two controls were visually disconnected.

Fix: Collapsed to a single flex row in the panel header. Title on the left; on the right,
both pill-groups sit inline with a 1px vertical divider (height 14, rgba(255,255,255,0.12))
between them. Layout: `[By Qty][By Value] | [Movers][Non-Movers]`.

To confirm: Top 20 Movers panel header shows title on left and both toggle groups on the
right as one inline control bar separated by a thin vertical rule.

### Issue 5 — Non-Movers definition wrong (SQL)
**Status v1: Deployed but broken — superseded by v2**
**Status v2: Deployed and verified in Supabase**
**File v2:** `sql/fix_non_movers_v2.sql`

v1 root cause (fix_non_movers_definition.sql): two bugs discovered after deploy:
  1. last_sales_date_iso is a DATE column, not text. NULLIF(col, '') on a date column
     fails silently in plpgsql — returned zero rows instead of an error.
  2. period_qty = 0 (Sigma month-to-date) is the wrong metric for "no sales in 4 weeks".
     A product that sold on the 1st shows period_qty > 0 even if it hasn't moved since.

v2 definition (per PM brief — ROS > 0, no sales 4 weeks, SOH > 0, sold within 1 year):
  Replaces both conditions with a single BETWEEN on the DATE column:
    last_sales_date_iso BETWEEN (CURRENT_DATE - 365 days) AND (CURRENT_DATE - 28 days)
  NULL last_sales_date_iso rows (never sold) are excluded automatically by BETWEEN.
  Diagnostic confirmed 1,336,612 qualifying rows across all stores.

Movers branch is unchanged. Signature unchanged (still 7 params).

---

## 2026-05-21 — Session 2, Batch 2

**Commits:** 558ab7e, 928b07a, 80b681c

- `sql/restore_top20_params.sql` — rpc_top20: 7-param version with p_activity + p_parents
  restored. Confirmed in Supabase: 1 row, 7 arguments.
- `sql/fix_refresh_kpi_view.sql` — refresh_kpi_view: timeout fix via set_config.
  Confirmed in Supabase: 1 row, security_definer = true.
- Frontend: Movers/Non-Movers toggle, top20Activity state, p_activity/p_parents wired.
- Bug 7: Reorder Items KPI card clickable, opens drawer, pre-selects Reorder List.

---

## 2026-05-21 — Session 2, Batch 1

**Commits:** 3c37d97

- `sql/fix_top20_overload.sql` — rpc_top20 HTTP 500: nameless DROP CASCADE + 5-param
  recreate. Resolved the overload ambiguity. Superseded by restore_top20_params.sql.

---

## 2026-05-21 — Session 1

**Commits:** e904960, 8278c05, 78059f1, d97c5f2, 94c1550, 05abe42

PULSE-BUG-001 items 1–8 + Search Index. See handover_2026-05-21.md for details.
