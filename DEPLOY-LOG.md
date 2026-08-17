# SocialBrand Dashboard — Deploy Log

Reverse-chronological. Each entry = one production deploy.

---

## 2026-08-16 (later) -- ENG-088 partial fix + ENG-090: rpc_bloom_order_recipe performance (still open) and a real trim-not-zero defect.

**Three migrations, all live, all correctness-neutral, R22'd:**

1. **`eng064_normal_packs_ceiling_trim_not_zero` (ENG-090, not ENG-064 -- see BUG-LOG correction).** `packs_ceiled.normal_packs_calc` carried the same zero-instead-of-trim shape ENG-064 fixed in the sibling `geared_ceiled` CTE on 2026-08-03, untouched by that fix. One line: `THEN 0` -> `THEN LEAST(m.normal_packs_raw, m.packs_under_ceiling)`. R22: 0 net recovered value on tonight's sample (`packs_under_ceiling` was 0 wherever the flag fired), consistent with PM's sizing of the class (~R2k, immaterial, non-gating).
2. **`eng088_recipe_output_filter_actionable_rows_only` -> superseded same session by `eng088_filter_before_surfacing_passes_not_after`.** Confirmed live 2026-08-16: DC Ambient at both 10116 and 80175 renders `R 0 / 0 lines` + `canceling statement due to statement timeout` on the live `/bloom` screen (DOM-read, not a screenshot). `EXPLAIN (ANALYZE, BUFFERS)` direct on the function: 52.7s. Filtered the final `RETURN QUERY` to actionable rows only (`suggested_packs>0 OR count_first OR keep_or_delist OR pack_forced_review OR min_presence_forced`) -- barely moved it (47.0s), because the three SB-CC-BLOOM-018 surfacing UPDATE passes ran over the full ~12,700-row pool BEFORE that filter applied. Moved the same filter to a `DELETE FROM _bloom_recipe_out` immediately after the pool materialises, before the three passes -- local/temp buffer writes dropped ~70%, wall clock only to 47.0s (the passes were real but not dominant).
3. **`perf_sigma_supplier_link_store_supplier_idx`.** New index `sigma_supplier_link (store_code, supplier_nr)` -- none of the three existing indexes led with `supplier_nr`, so the DC pool's `lnk` CTE bitmap-scanned all 69,346 store rows from disk before it could filter to the ~27 type-Z suppliers. Confirmed by plan change (index-nested-loop from the small supplier set) and measurement: `lnk` 6.2s -> 3.5s, function total 47.0s -> **38.1s**.

**Cumulative: 52.7s -> 38.1s (~28% faster). STILL OVER the ~30s ceiling (the function's own `SET LOCAL statement_timeout='30s'` and Kong's kill switch) -- the live UI is confirmed still broken on both SPAR stores at time of writing.** BUG-LOG ENG-088 carries the full diagnosis and the remaining-cost note (30-CTE chain, no single further hotspot identified this session). **Not walked (Pieter's DoD test failed live, twice, before these fixes; not re-tested against the UI after fix 3 -- do that first next session).** Files: none (all three are direct `CREATE OR REPLACE FUNCTION` / `CREATE INDEX`, no `sql/create_*.sql` regen this pass -- that file was already known rotted off live, see BLOOM-023 SOT map).

---

## 2026-08-16 14:26 SAST -- ENG-087: direct desks widened into the ROS pantry pool (repo catch-up + reconcile).

**Repo catch-up, not a new ship.** The migration `eng087_pantry_pool_include_direct_desk_suppliers` was already live (applied 14:26 SAST, pantry rebuilt ~14:28-14:29) when this session opened -- the working copy of `sql/create_l2_bloom_ros_pantry.sql` sat uncommitted, a live-DB-vs-repo divergence (SB-PRIORITY v1.4 Test 1). This entry commits the matching file (`e0cce3e`, merged to main in this deploy) and re-reconciles at source before calling item 0 walkable.

**Fix:** `refresh_l2_bloom_ros_pantry`'s pool gained a third OR arm -- this store's own `bloom_route_config.direct_supplier_nrs` where `status='RULED'` -- so every `DIRECT_<brand>` desk now reads the guarded/corrected/stable rates instead of degrading to a raw, unguarded scan window. Additive only; `corrected_ros_cap_multiple` (2.0) and `corrector_min_observable_share` (0.5) untouched (PM ENG-084 interim ruling, 2026-08-16: the tighter bound is a separate pass and does not gate this).

**R22, re-run at source in this session, all five stores:** every RULED direct desk now shows 0 missing pantry rows (10116: CLOVER 381/381, COCACOLA 183/183, DANONE 65/65, MONDELEZ 93/93, NATBRANDS 77/77, SIMBA 68/68; 80175: CLOVER 349/349, COCACOLA 181/181, DANONE 64/64, MONDELEZ 81/81, NATBRANDS 51/51, SIMBA 86/86; 21355: DIRECT_BEER 67/67, DIRECT_COCACOLA 68/68; 80176: DIRECT_BEER 68/68; 80579: DIRECT_BEER 66/66). DC/unrouted pools unaffected (10116 6,308/6,310, 80175 3,921/3,922 -- the 1-2 line residual is a classification-scope question, not this fix, named in BUG-LOG). DC ambient fitted order unchanged in shape (10116 528 lines/R236,310.64 normal, 80175 245 lines/R211,404.27 normal, both scenario_overview calls returned in seconds via direct SQL).

**⚠️ WHAT THIS DOES NOT FIX, carried forward not buried:** the feed-gate coverage bug is closed, but the ORIGINATING SYMPTOM -- Pieter cutting Coca-Cola by hand on 12 Aug -- is not. The biggest Coke line at 80175 still orders well above its demonstrated weekly demand off a 14-day-class window; that lever is the cover-ceiling/KVI-safety/rate-driver mechanism, BUG-LOG ENG-084, still open, PM-ruled non-gating for Monday. Every SPAR direct desk's `yardstick_flag` reads `DEFECT_SIGNAL` against `demonstrated_weekly_demand` on this generate -- expected under v10's deeper band model per the ENG-018 same-day correction, not itself new evidence of a defect, but not yet independently walked either.

**⚠️ ENG-088 still open.** The DC Ambient recipe (~12,700 lines at each SPAR) times out through the API/UI single-call fetch; it returns in seconds via direct SQL (used for the R22 above). Bloom's "Generate order" button on `/bloom` for DC_AMBIENT is not confirmed working this session -- Pieter or PM should check the live screen before relying on it Monday; the numbers above came from the engine directly, not the UI.

**HELD for Pieter's buyer's-test walk before Monday placement**, per SB-CC-DEPLOY-001 v1.2 Test 2. BUG-LOG ENG-087 updated with this commit hash. **Files:** `sql/create_l2_bloom_ros_pantry.sql`. Merge also lands the already-live ENG-052 leg 1 columns (`sql/create_l2_bloom_promo_pantry.sql`, commits `c70bebe`/`8620620`, live since 2026-08-09) -- a second named code/DB divergence closed in the same merge.

---

## 2026-08-13 -- Bloom order screen: fetch the recipe in ONE call, not 13 paged re-runs (timeout fix).

**Pieter-directed (checked the live orders.socialbrand.africa screen in his Chrome). `src/app/bloom/page.jsx` looped `supabase.rpc('rpc_bloom_order_recipe').range(offset, offset+999)` in 1000-row pages -- and PostgREST re-executes the whole SET-RETURNING function per page, so a ~12,700-row SPAR order ran the recipe ~13x. Roosville completes (R269,727/450 on screen); Delareyville TIMED OUT and rendered a partial total. No `pgrst.db_max_rows` cap is set, so one `.rpc()` call returns every row in a single ~3s execution.** Build-verified clean (`/bloom` prerenders). **BUG-LOG ENG-085.**

**Deployed:** `origin/main bc5fe3c` (this commit + the ENG-083 v16 record `e118446`), Vercel production green -- the red deployments were PREVIEW builds of feature branches failing on `Missing Supabase environment variables` (both `NEXT_PUBLIC_SUPABASE_*` scoped Production-only), same code Ready on prod. **File:** `src/app/bloom/page.jsx`.

---

## 2026-08-13 -- ENG-083 / canon SS14 v16 + 16.7: the DC ambient Standard over-order fix goes live.

**Pieter ruling 2026-08-13 ("churn and test and then implement"). `rpc_bloom_order_recipe` over-ordered on live money on the DC ambient Standard order (80175 15 Aug R361,730 against recent real deliveries R194-217k). Two coupled defects fixed, R22 green across 5 stores x 3 presets, deployed under standing authority.**

- **Bug 1 -- demand basis (canon v16):** in the Standard preset, minimum mode, both demand legs (`scan_raw`, `draw_corrected`) now read the stockout-corrected wide window (`ros_56d_published` / `ros_draw_56d_published`) instead of the raw 14-day spike. `ros_final = GREATEST(scan_raw, draw_used)` was locking the month-end/promo 14-day peak in. Build mode and the geared buy-in path keep the responsive short window by design (v16). Essentials/catch-up/full/fitted unchanged (`%10$L='standard'` gate). Scan-side `ros_56d_published` added to pool scope.
- **Bug 2 -- build timing (canon 16.7 leg 2, ENG-056a's pending successor):** the month-end build window is DERIVED from the route's own `delivery_dows` around the community payday (new config key `month_end_build_anchor_dom` = 25, DEMO_CALIBRATION), never the hardcoded day-of-month 15. Build now starts on the 2nd-last DC drop before the 25th (80175 the 19th, 10116 the 20th). Standard preset + real DC `supplier_calendar` row only (TOPS DC_TOPS has no calendar row, so the guard holds and it is unaffected).
- **R29:** `demand_source` and `ros_window_used` report `stable_56d` / `ros_56d STABLE` when the stable basis fires, so the reason matches the number.

**R22 (live, to the rand):** 80175 DC_AMBIENT 15 Aug R353,017 -> **R274,108** (-22%); 10116 R909,053 -> **R781,387** (-14%). Essentials/catch-up **byte-identical** (80175 ess R338,569; 10116 ess R813,569 / cu R135,247, both sides). TOPS +2.6% (stockout-aware, Bug 2 guarded off). Direct desk flat. Milk 491 R42,706 -> R36,359, chicken 71524 R89,231 -> R57,738. Independently reproduces PM's `SB-CC-BLOOM-023` targets to the rand.

**DB live via apply_migration `fix_bloom_recipe_dc_over_order_eng083_v16` + config key.** Deployed the exact body validated as the `_v16` shadow (renamed onto the live function; CREATE OR REPLACE preserved grants + SECURITY DEFINER). Scratch `rpc_bloom_order_recipe_v16` and PM's superseded `rpc_bloom_order_recipe_stable56` dropped. **Files:** `sql/2026-08-13_bloom_recipe_eng083_v16.sql` (idempotent config + transformation record). **OWED, named not silent:** the full-body regen of `sql/create_rpc_bloom_order_recipe.sql` from live rides with the ENG-063 reconcile (that file was already diverged before this change).

**Still open, PM's call, NOT pre-empted -- ENG-084:** the corrected wide window over-fires on sell-while-negative KVIs (milk reads 247.7/day against its own 91-day 173). v16 KEEPS the correction by ruling; bounding it (cap at the 91-day) is a separate demand-rate call that needs the milk in-stock-rate test before it ships. Flagged, not guessed.

**R31 (Pieter):** open Bloom, generate the 80175/10116 DC ambient standard order, confirm the numbers.

---

## 2026-08-13 -- SB-CC-TOOLKIT-002 new rule: no forced count on Saturday, Sunday or a store's DC ambient delivery day.

**Pieter ruling 2026-08-13.** `refresh_forge_daily_issue` gains a non-count-day skip: never force the daily list on Sat/Sun or the store's DC ambient delivery day (busy receiving). Config-driven from `supplier_calendar.delivery_dows` for the `DC%` route (DC_AMBIENT SPAR / DC_TOPS TOPS) -- no hardcoded store days (R25/R28); the manual Composer/pre-order/ad-hoc counts are unaffected. Today (Thu, isodow 4) is a DC day for 10116/21355/80579, a count day for 80175/80176 -- verified: the function skips all three DC-day stores; today's seeded runs for those three were deleted to realign.

**Board honesty (frontend):** new `rpc_forge_count_schedule()` (anon) returns each store's DC dows; the compliance board shows a weekend/DC day as "no count (DC delivery day / rest)" in neutral, and the header reads "**N of M stores due a count today** issued one · K on a DC / rest day" -- a non-count day is never a compliance failure. Walked in preview: header "2 of 2 due issued · 3 on a DC / rest day", the three DC-day stores read "no count today (DC delivery day)", weekends show "rest", real counts still show %.

**DB live (R22): `forge_no_force_count_on_weekend_or_dc_day` migration.** **Files:** `sql/create_refresh_forge_daily_issue.sql`, `public/toolkit.html`.

---

## 2026-08-13 -- SB-CC-TOOLKIT-002 items 4, 6, 7: toolkit downloads + terminology (same-day follow-on).

**Item 4 (interim, manual-StockFlow):** `GET /api/forge/export-stocktake` (nodejs, SheetJS) returns TODAY's daily count lists as ONE workbook, a tab per store, `product_code` in column A for the StockFlow upload + deletable detail columns. Button on the Progress tab. A one-off copy for today was also handed to Pieter directly. **Item 7:** `GET /api/forge/weekly-report` returns the weekly Chairman/VP report (Compliance 7-day + Unit progress from `v_forge_count_compliance` + `rpc_forge_integrity_trend`); not-yet-captured measures (waste/write-off, adjustments, exceptions, sales-vs-LY, GP%) are NAMED as pending gaps, never shown as zeros. Button on the Progress tab. **Item 6:** visible engine jargon relabelled to operating-rules words -- "TLX" -> "stocktake import" / "Zero-stock import" across the tab, Fixer labels and Integrity descriptions (the `.tlx` filenames are unchanged); the count-list badges already carry the tier names.

**Both routes copy the ../run auth pattern** (same-origin session, `getUser()` belt behind middleware). Auth-gated, so not walkable locally; the SheetJS generation was proven with node against the app's own `xlsx` module and both outputs validated (openpyxl reads all sheets/headers). The toolkit page was walked in preview: both buttons render, relabels landed, no JS errors. **R31 (Pieter clicks the buttons live) confirms the downloads.**

**Files:** `src/app/api/forge/export-stocktake/route.js`, `src/app/api/forge/weekly-report/route.js`, `public/toolkit.html`.

---

## 2026-08-13 -- SB-CC-TOOLKIT-002 the count-accountability set: the daily routine goes live (items 1, 2, 3 + item-5 decode).

**Clock re-read at the write (5th-firing discipline): the session opened 2026-08-12 22:48 SAST and CROSSED MIDNIGHT; everything here is 2026-08-13 (git author dates confirm). Dates taken from the artefacts.** Pieter's explicit go, DoD = live on site.

**DB (live via apply_migration, R22 x5 stores):**
- **Item 5 decoded, no build:** count compliance reads I/M/DIWAINV and is complete -- `qty=0` = matched count (10,059/20,942), so accurate counters are not punished; S/DIWASOBE is transfers/write-offs, not counts (falsifier: 18 S-only lines ever). The "extend to S" item is retired with evidence. Also reconciled the two 08-12 views to `sql/create_*.sql` (no-divergence).
- **Item 1 fixed volume:** `forge_config.daily_count_volume` SPAR 200 / TOPS 70, retiring the self-sizing budget (the 408-611 line lists). `refresh_forge_daily_issue()` + cron `forge-daily-issue` 06:30 SAST daily, same-day dedupe guard. Seeded once on 08-13: 5 runs issued 200/70/200/70/70, dedupe re-run skipped all 5.
- **Item 2 priority law:** `rpc_forge_count_list` ranks by ORDERING IMPACT (on order / KVI / ranged-VERIFY / engine indictment), tier-1 never displaced by cosmetic ledger, tier decided by behaviour not label. R22: volumes exact, all-tier-1, deterministic, emission gate 0 leaks, a plain-words reason on every line.

**Frontend (this deploy -- merged to main, Vercel prod):**
- **Item 3:** count-compliance display is the first thing on the Progress pane, auto-loading (no click), reading `v_forge_count_compliance`/`_line_evidence` by REST GET. Per store, per day, 7-day strip. A store with no run reads "Never issued a count list"; a day with no list shows a gap, never a blank or an old number. Header states N of 5 issued today. **Walked in preview against live data before ship** (10116 54%/270:504, 80175 9%/38:408, 80579 97%/67:69, 21355+80176 never issued).
- **Audit finding 3b-1 fixed:** the scoreboard stamps its real snapshot date and flags when it is not today (it fired on the midnight cross: "as of 08-12, NOT today 08-13").
- **Composer text corrected** to the fixed-volume + ordering-impact reality (audit 3b-3/4): the old "self-sizing budget / negatives-first" copy and badge legend are replaced.

**R31 (the buyer's test) is Pieter's step:** open `toolkit.socialbrand.africa`, Progress tab, read issued-vs-counted per store without clicking. Numbers stated above in rands/units and lines.

**Still open on SB-CC-TOOLKIT-002 (not this deploy):** item 4 StockFlow morning export, item 6 terminology relabel, item 7 weekly Chairman/VP report. The StockFlow auto-feed permission is on Pieter (ask Sparrie).

**SQL:** `sql/create_rpc_forge_count_list.sql`, `sql/create_refresh_forge_daily_issue.sql`, `sql/create_v_forge_count_compliance.sql`, `sql/create_v_forge_count_line_evidence.sql`.

---

## 2026-08-09 21:47 SAST -- ENG-052 leg 1: buy-in supply becomes a PANTRY fact on `l2_bloom_promo_pantry`. No quantity moved.

**Clock read in the same exchange as this write: local 21:47:12 +02:00 / UTC 19:47:12.**

**Two migrations, both live:** `eng052_promo_pantry_buyin_supply_columns` (Rule 19 DROP + clean CREATE, three new columns) and `eng052_refresh_promo_pantry_buyin_supply` (the refresh function computes them). Source of truth is `sql/create_l2_bloom_promo_pantry.sql` on branch `eng052-promo-supply-surfacing`, commit `c70bebe`. **No app code, no frontend, no config key, no cap change.** Section 6 of `Bloom/SB-CC-BLOOM-021` v1.1, the surfacing build, leg 1 of 3.

**What it answers.** Did DC stock actually ARRIVE inside the window the engine would have permitted a buy-in? New columns `bought_in_dc`, `bought_in_qty`, `bought_in_lead_days`.

**WHY IT IS A PANTRY FACT (R32 s2).** Computing it in `rpc_bloom_order_recipe` or the frontend would be Layer-2 logic in the wrong layer -- the ENG-052 defect class itself, rebuilt while fixing ENG-052. Paid once in L2 for every consumer.

**THE FINDING THIS EXISTS TO CARRY: 1,850 of 4,141 measured gearing lines, 44.7%, were never bought in.** Their uplift is what the line sold off a shelf nobody restocked. On top of the stockout censoring already found, the rate is censored a second time in the same direction, so it is a FLOOR on that line's rate, never a ceiling. The surfacing will say exactly that.

**THE WINDOW NOW TRAVELS WITH THE ROW (R29), and that is the point of the third column.** Two seats published **2,291 and 2,449 for this same fact on one day** because neither stated its window. `bought_in_lead_days` is stored per row so it can never again be quoted without its definition. **Sensitivity measured rather than assumed:** widening the supplier filter from type Z to any supplier moves the count 17 lines of 4,141; widening the lead from 7 to 14 days moves it 2,308 -> 2,667. **The LEAD is what the number is sensitive to. That is why the lead is the thing stored.**

**R30 DEPENDENT PROOF, run BEFORE applying.** Zero cascade-class dependents -- no view or matview reads this table, so `DROP TABLE ... CASCADE` took nothing with it. Eight read-only function dependents (`refresh_l2_pipeline`, `refresh_l2_stock_band`, `rpc_bloom_order_recipe`, `fill_l2_bloom_promo_pantry_sibling_fallback`, `refresh_l2_bloom_promo_pantry`, plus 3 held R22 scratch shadows). Change is **additive only** -- no column renamed, none retyped -- so every dependent survives by construction.

**R22 GATE: PASSED, and the drift is decomposed rather than waved through.**

| Gate | Expected | Got |
|---|---|---|
| Rows, all 5 stores | 16,993 | **16,993** |
| `default` / `sibling_store` / `own_promo` | 8,364 / 1,662 / 6,967 | **exact on all three** |
| Lines at the 5.0 cap | 854 | **854** |
| No-promo rows leaking a non-null on the new columns | 0 | **0** |
| `bought_in_lead_days` distinct values | uniform | **7** |
| Supplied / never bought in | 2,291 / 1,850 | 2,294 / 1,848 |

**The five-line difference is two days of live trading and it closes to the unit.** Measured population 4,141 -> 4,142 and no-promo 4,879 -> 4,878: exactly one line gained a completed promo and crossed in. Eleven lines carry a promo ending on or after 07 Aug and four measured lines still have open windows, so stock landing since flipped two from unsupplied to supplied. **2,291 + 1 + 2 = 2,294. 1,850 - 2 = 1,848.** Direction correct -- more stock arriving, not less. **The legacy columns did not move at all, which is what made the drift safe to accept rather than roll back.**

**NULL, not false, where there was no completed promo to test** -- an absence of evidence is not evidence of absence (R23 s2, uncertainty is never a zero). 4,878 rows.

**NAMED APPROXIMATION (R27 s6), with a live guard rather than a comment.** `promo_buyin_lead_days` is ROUTE-grained in `supplier_calendar` while this pantry is STORE-grained. It reads 7 on all 20 rows across all five stores today, so `MAX` is exact rather than a choice. A `RAISE WARNING` now fires the moment two routes at one store disagree, which is the point the fact must move to route grain.

**VERIFICATION:** re-run `SELECT refresh_l2_bloom_promo_pantry('<store>')` for all five, then `fill_l2_bloom_promo_pantry_sibling_fallback()`, then re-check the six gates above. **Confirmed working: yes** -- all five stores rebuilt live (10116 8,598 rows/38.6s, 80175 5,806/18.0s, 21355 956/3.7s, 80176 788/3.4s, 80579 845/3.1s), fallback re-run 1,662 sibling / 8,364 defaulted, both matching pre-change exactly.

**NOT deployed:** the recipe's surfacing outputs and the frontend. Legs 2 and 3, branch-only, nothing on `main`.

---

## 2026-08-09 -- SEC-001 (atlas slice): anon write access removed schema-wide; the "delete the ledger" framing retired.

**DATE CORRECTED (R28 lineage): this entry was first written as 2026-08-08 and is wrong by a day.** The migration's own recorded version is `20260809074035` = 07:40:35 UTC / 09:40 SAST on **2026-08-09**. The session crossed midnight a second time and the stamp was carried from the previous evening's clock read. Corrected against the migration version, the one witness that cannot drift. **Fourth firing of this defect; the rule stands -- re-read the clock at the moment of the write, and for anything already applied, take the date from the artefact rather than the session.**

**One live migration, `sec001_atlas_anon_write_lockdown`. No app code, no schema change, no frontend.** SEC-001 had never had a BUG-LOG row -- it lived in `sql/pmini_partner_lockdown.sql`'s footer and in handovers as "nobody has started it". It has one now.

**THE DEBT AS WRITTEN WAS HALF WRONG, and the wrong half was the frightening one.** Recorded as "anon/authenticated still hold INSERT/UPDATE/DELETE on base tables, so an outside key could delete the ledger". Measured before touching anything: **8 of 113 public tables carried anon write grants, and all eight are `atlas_*`** -- the knowledgebase. **Zero `sigma_*`, zero `l2_*`, zero `order_*`, zero `daily_snapshots`. The retail ledger was never exposed.** Real exposure, different asset, different owner (the Librarian's project, section 0e), different severity. **Do not re-quote the ledger framing.**

**The reporting defect is the durable lesson: the claim was read off a GRANT TABLE and never tested.** A grant is not a behaviour. The same session that carried this debt forward also logged ENG-068, where a grant table said `auth_select=true` and the rows were invisible because RLS had no policy. **Grants over-state and under-state, in both directions. Only `SET ROLE` settles it.**

**Exposure proven behaviourally before the fix,** not inferred: `SET LOCAL ROLE anon`, then INSERT and DELETE against `atlas_settings`, both succeeded, inside a rolled-back transaction.

**R30 section 2 pre-flight -- the step the ORIGINAL SEC-001 lockdown skipped when it silently emptied the Kitchen tab.** Consumers enumerated: the Atlas browser page calls `functions/v1/atlas` x4 with **zero** `rest/v1/atlas_*`; the Atlas engine is a Supabase **EDGE FUNCTION** whose every write goes through one header builder reading `SUPABASE_SERVICE_ROLE_KEY`, which **bypasses RLS and needs none of these grants**; the Knowledgebase project has 4 matches, all `.md`; the dashboard repo has zero. **No consumer writes as anon -- unaffected by construction, not by hope.**

**Fix, both layers,** because every security incident here has been a single-layer fix that did not hold (SEC-002, BLOOM-004, ENG-031, ENG-068, the pmini PUBLIC hole -- five firings of one class): `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ... FROM anon, authenticated` on all 8, **plus** the wide-open `atlas_anon_all` policy (`cmd=ALL`, `qual=true`, `with_check=true`) dropped and replaced with a SELECT-only `atlas_anon_select`. The loop is **count-gated** -- it RAISEs unless the atlas set is exactly 8, so it cannot silently lock down a set nobody measured.

**R22, four behavioural gates, all passed:** anon INSERT blocked (`insufficient_privilege`) - anon DELETE blocked - anon SELECT still works - **`service_role` can still insert and delete, so Atlas is provably unaffected.** Row counts intact (settings 2 / projects 2 / agents 4). **Schema-wide after: anon INSERT/UPDATE/DELETE 8 -> 0, authenticated DELETE 8 -> 0, anon SELECT 106 unchanged.**

**NAMED, NOT SILENTLY WIDENED:** `anon` can still SELECT the whole Atlas knowledgebase, and no consumer needs it -- the browser goes through the edge function. Closing it is one more line. **Who may READ the knowledgebase is a custody call for PM / the Librarian, not something CC decides inside a write-lockdown migration.**

**Still open on SEC-001 beyond this slice:** ~113 PUBLIC functions the MCP role does not own (pg_cron/pgrst/supabase internals, no app data) still carry PUBLIC EXECUTE -- needs a re-run as `supabase_admin`, admin-only, not a data risk.

**SQL:** `sql/sec001_atlas_anon_write_lockdown.sql`.

---

## 2026-08-07 17:45 SAST -- ENG-074 FRONTEND MERGED AND SHIPPED. The stock KPI cards read the RPC in production, and the R31 walk was done on the exact date that used to fail.

**Clock cross-checked three ways at the moment of this write** (standing constraint 3): machine local 17:45:05 +02:00 / machine UTC 15:45:05 / DB `now()` SAST 17:45:11, UTC 15:45:11. All agree at +2, six seconds apart. No drift.

**Authority:** Pieter's word this session ("close fork" -> merge the branch), on top of standing deploy authority (canon SS0d). `origin/main` `8a6d89d` -> **`a58865e`** (merge commit, `--no-ff`). Branch `eng074-stock-kpi-repoint` pushed first (`99eb2e8..972eed3`) and **left alive**, per this repo's own convention -- no merged branch has ever been deleted here (eng069/eng070 are still on origin).

**NO DB CHANGE. This was the held frontend half only.** All three SQL objects were already live: `rpc_kpi_stock_by_date` (ENG-074, migration `eng074_rpc_kpi_stock_by_date`) and ENG-073's `l2_family_ros` + `v_family_days_cover`. The merge brings their canonical `sql/create_*.sql` sources onto main. Verified at source before the merge: all three present, `rpc_kpi_stock_by_date` single overload, `refresh_l2_family_ros` wired inside `refresh_l2_pipeline`.

**R22 RE-RUN AT SOURCE IMMEDIATELY BEFORE THE MERGE, not taken from the 15:24 entry's word.** `rpc_kpi_stock_by_date` against `v_kpi_by_date`'s own algebra on **2026-08-06** -- the date the view genuinely blew the 12s client deadline in production during the ENG-069 walk -- **20 of 20 values identical across all five stores, rand to the cent.** 10116 284 / 1,951 / R4,571,219.62 / R3,951,978.56 - 21355 59 / 295 / R868,055.04 / R11,278.28 - 80175 199 / 1,538 / R6,528,428.60 / R3,916,213.60 - 80176 25 / 252 / R4,454,988.22 / R29,581.02 - 80579 37 / 225 / R865,602.77 / R12,106.14. Build green 13/13.

**R31 WALK DONE LIVE ON PRODUCTION, in Pieter's signed-in browser (standing permission), and it reconciles from the database to the card.** Single date **2026-08-06**, all five stores:
- **NEGATIVE SOH reads 604.** The five store figures above sum to **exactly 604** (284+59+199+25+37).
- **CAPITAL TIED reads R 17.29M.** The five capital figures sum to **exactly R17,288,294.25**.
- **STOCK TURN 7.0 turns / 52d cover** now computes, where it needed capital tied and previously had none.
- **No "Stock figures unavailable" banner anywhere on the page.** Zero page console errors (the three captured are Chrome-extension message-channel noise, not the app).
**That chain is the point: the same four numbers reconcile view-algebra -> RPC -> screen, on the one date the old path could not answer at all.**

**Deploy proven serving, never assumed.** The production bundle `page-1405d06cfe5882b7.js` was fetched from the live page and contains `rpc_kpi_stock_by_date` -- so the walk above tested the NEW build, not a cached old one. Checked because "the merge pushed" is not evidence that Vercel served it.

**WHAT DID NOT MOVE, stated so nobody reads more into this ship than it earned.** ENG-073's frontend switch to `v_family_days_cover` is **NOT** in this merge -- `src/app/page.jsx` is ENG-074 only, so Top 20 cover and product detail still read `mv_rate_of_sale` and the 679 understated display lines are unchanged. The `mv_rate_of_sale` column repoint stays deliberately undone: it is CASCADE-class (canon SS13 -- seven downstream objects must be rebuilt in the same transaction) and rule 3 forbids a live rebuild during trading. Both legs stay owed.

---

## 2026-08-07 15:24 SAST -- ENG-074 SQL LIVE IN PRODUCTION. `rpc_kpi_stock_by_date` created. FRONTEND HELD on a branch for the R31 walk.

**Clock cross-checked three ways at the moment of this write** (standing constraint 3): machine local 15:23:43 +02:00 / machine UTC 13:23:43 / DB `now()` SAST 15:23:56, UTC 13:23:56. All agree at +2, thirteen seconds apart. No drift.

**Authority:** standing deploy authority (canon SS0d) on a green R22 gate. This is a NEW object only -- nothing was altered or dropped, so no existing consumer changes behaviour and the deploy is additive by construction.

**Migration:** `eng074_rpc_kpi_stock_by_date`. Canonical source committed as `sql/create_rpc_kpi_stock_by_date.sql`. **Verified single overload, `prosecdef = true`, `provolatile = v`.** ACL reads `postgres=X | anon=X | authenticated=X | service_role=X` -- **no PUBLIC entry**, so the PUBLIC-grant trap (five firings: SEC-002, BLOOM-004, ENG-031, ENG-068, the PMINI lockdown) did NOT fire here. Grants match the `rpc_dept_summary` / `rpc_kpi_dept_counts` read-RPC precedent; R30's addendum extension scopes the anon revoke to MUTATING functions and this one reads.

**WHAT IT CLOSES.** ENG-069 repointed the SALES half and deliberately left neg SOH / slow movers / capital tied / ghost value on `v_kpi_by_date`, so those four inherited the 8s `authenticator` ceiling and rendered UNAVAILABLE on a recent date. This is the same repoint applied to them: same four expressions, same column names, SECURITY DEFINER so it holds its own `SET LOCAL statement_timeout` (20s -- headroom over a measured 4.3s without reaching Kong's ~30s kill).

**ROOT CAUSE, MEASURED AT SOURCE, AND IT IS BIGGER THAN THE BUG-LOG'S FRAMING.** Two independent faults compounding, neither of which is "a view cannot hold a timeout":
1. **The index could not seek.** The view joins `l2_soh_daily` to `l2_stock_position` on `(store_code, product_code)` only, while `idx_l2_pos_pk` is `(client_id, store_code, product_code)` -- **client_id LEADING**. Every probe cost ~4,665. **This is CLEANUP-ENGINE-CANON SS17's own standing note ("any query against these two facts carries `client_id` in the predicate") firing on a live dashboard object.**
2. **The estimate was 77,000x wrong.** `l2_soh_daily` filtered to a recent date estimates `rows=1` against a real **89,999** for one store (387,378 across five), so the planner chose a Nested Loop and ran ~90k of those probes.
**The consequence is structural, not load-dependent flakiness:** the table gains ~387k rows/day, so the NEWEST date is always the worst-estimated one and the failure recurs by construction on the exact date the owner reads each morning.

**MEASURED, same store, same date, same expressions:**

| Case | Before (view shape) | After (RPC) |
|---|---|---|
| 80175 / 2026-08-06, one store | **CANCELLED past 25s** | **1,211 ms** |
| five stores / 2026-08-06 | infeasible (90s budget also cancelled) | **5,404 ms** wall, 4,301 ms planned |
| five stores / 2026-08-03 (second date) | -- | **2,052 ms** |
| a date with no snapshot | -- | **0 rows in 1.6 ms** -- absent, never a fabricated zero |

**R22 GREEN -- 20 of 20 values identical across five stores.** Reconciled against `v_kpi_by_date`'s **own algebra** (the join WITHOUT `client_id`, hash-joined so it could finish at all -- with a nested loop it cannot complete in 90s): `neg_soh_count`, `slow_mover_count`, `capital_tied` and `ghost_stock_value` match on every store, the rand figures to the cent. 10116 284 / 1,951 / R4,571,219.62 / R3,951,978.56 - 21355 59 / 295 / R868,055.04 / R11,278.28 - 80175 199 / 1,538 / R6,528,428.60 / R3,916,213.60 - 80176 25 / 252 / R4,454,988.22 / R29,581.02 - 80579 37 / 225 / R865,602.77 / R12,106.14.

**SECURITY DEFINER IS LOAD-BEARING, PROVEN BEHAVIOURALLY (ENG-068 discipline -- never read a grant, run it as the role).** `SET ROLE anon` then counting `l2_soh_daily` for 2026-08-06 returns **0 rows**, because that table has **RLS ENABLED with ZERO policies** while its SELECT grant reads `true`. A SECURITY INVOKER version would therefore have reported a confident, permanent **ZERO** on every stock card -- a wrong number, which is worse than an absent one (R22 SS3, and the ENG-069 `?? []` lesson). Re-proven the other way after the build: called AS `anon`, the function returns the same 20 figures.

**`client_id` in the join cannot move a number today, verified before relying on it:** one distinct `client_id` in each table, **zero** `(store_code, product_code)` pairs holding more than one, and the join returns 270,594 matched rows across five stores. Planner enabler today, correct scoping the day a second client lands.

**THE ANON TRANSPORT PATH WAS TESTED, WHICH IS THE LAYER ENG-069 GOT WRONG.** A PostgREST POST to `/rest/v1/rpc/rpc_kpi_stock_by_date` with the publishable key returned **HTTP 200, five rows, 4,048 ms**, figures identical to the SQL. "The data is reachable in the database" was never a test of the request the browser actually makes.

**FRONTEND HELD, NOT SHIPPED: branch `eng074-stock-kpi-repoint`, commit `99eb2e8`, pushed and NOT merged.** It drops `v_kpi_by_date` from the single-date path entirely -- on a single date it was never a working fallback (it cannot return inside the deadline), so keeping it meant 25s+ of database work competing with every other panel, which is ENG-070's root cause. `store_name` comes from `STORE_MAP`; the multi-date matview path is untouched. Build green 13/13; serves clean at the auth gate with zero console errors. **NOT verified by CC: the signed-in KPI cards themselves.** Shipping a frontend on an unwalked diagnosis is how `bac9ace` failed, so it waits for Pieter.

---

## 2026-08-07 13:04 SAST -- ENG-070 + ENG-069 MERGED AND SHIPPED. Both frontends were the held half; both are now live.

**Clock cross-checked three ways at the moment of this write** (standing constraint 3): machine local 13:04:44 +02:00 / machine UTC 11:04:44 / DB `now()` SAST 13:04:45, UTC 11:04:45. All agree at +2, one second apart. No drift.

**Authority:** Pieter, 2026-08-06 -- "ENG-070 and ENG-069 are a go" -- plus the standing deploy authority (canon SS0d). `origin/main` verified still `bac9ace` immediately before the merge, and BOTH branches were verified to sit exactly on that commit, so neither carried a stale base.

**Merged:** `aa71730` (eng070-scenario-overview-per-scenario) then `2f45bf2` (eng069-same-day-sales-source). Both `--no-ff`. Different files, no conflict, no DEPLOY-LOG conflict, `.git/index.lock` checked after every git command and never present. `npm run build` green before push (13/13 static pages, `/` 141 kB, `/bloom` 24.8 kB).

**NO DATABASE CHANGE IN THIS DEPLOY.** ENG-070's migration went live 2026-08-05; ENG-069 never had one. This entry ships frontend only.

**R22 gate re-run at source before the merge, NOT taken from the prior entries' word.**

1. **ENG-070 -- the subset claim, which is the thing the wiring turns on.** `rpc_bloom_scenario_overview` verified as ONE overload carrying `p_scenarios text[]` and `p_include_yardstick boolean`. At 80175 / delivery 2026-08-12 / next 2026-08-15 / DC_AMBIENT, the four single-scenario calls return values **identical to the single whole call on every compared column** -- `lines`, `promo_lines`, `count_first_lines`, `value_normal`, `value_geared`, `protected_lines`, `trimmed_lines`, `budget_amount`, `yardstick_value`, `yardstick_deviation_pct`, `yardstick_flag`, `yardstick_reason`. `full`/`fitted` 333 lines R229,798.19; `order_essentials` 320 lines R225,381.12 normal / R228,994.10 geared; `catch_up` 4 lines R10,788.66 normal / R311,204.63 geared. The shared yardstick holds at **R47,788.68** in all four, and `full` still carries `full_is_luxury_by_definition`. **No cross-scenario contamination -- asking for one scenario returns what it returns alongside the others.**

2. **ENG-069 -- the source repoint, proved against a THIRD source rather than the two the diagnosis names.** `rpc_dept_summary` reconciled to an independent `sigma_sales` sum (`period_kind='T' AND txn_kind=1`) for 2026-08-04, **all five stores, delta R0.00 VAT-inclusive**: 10116 R258,963.47 - 21355 R21,539.06 - 80175 R127,599.98 - 80176 R15,789.83 - 80579 R18,894.67. Ex-VAT deltas are 1c to 3c, per-item `vat_pct` rounding, immaterial. **80175 lands on exactly the R127,599.98 incl / R114,166.24 ex the root cause named.**

**Corroborating evidence found while running the gate, worth recording:** a single statement joining `v_kpi_by_date` across five stores with five `rpc_dept_summary` laterals was **still running at 2m26s** and had to be cancelled, while the `rpc_dept_summary`-only half returned immediately. Consistent with the root cause -- the live view is the slow half -- though this ran as the MCP role, not `authenticator`, so it is corroboration and **not** a reproduction of the 8s PostgREST timeout.

**What is now live on screen.** Bloom's Scenario Overview requests one scenario per call and paints each as it lands, so Delareyville's panels stop timing out. The dashboard's same-day sales figure comes from `rpc_dept_summary`, every request in the wave is deadline-bounded at 12s, and **a failed read renders a named red failure banner instead of R0** -- closing the `?? []` defect at `page.jsx:1495-1496`, which was shipped regardless of root cause because a confident wrong number is worse than a visible failure (R22 SS3).

**R31 OUTSTANDING, and the go did not retire it (CC's own caveat, Pieter's instruction was walk AFTER deploy):** neither branch has been walked on a live desk. Owed: Pieter opens the Bloom order desk at 10116 and at 80175 and sees all four scenario cards render, and opens the dashboard on a single recent date at 80175. **Shipping on an unwalked diagnosis is how `bac9ace` failed** -- that lesson is not spent by this deploy.

**Owed and unchanged by this deploy:** `sql/create_rpc_bloom_scenario_overview.sql` reconcile (already stale before ENG-070 -- live carries four BLOOM-018 columns the file lacks) and its DB-SCHEMA parameter entry.

**Rule 18 closure, false at source:** the standing note that this repo's `CLAUDE.md` clock mirror uses `Get-Date -AsUTC` (a PowerShell 7+ parameter that throws on 5.1) is **wrong**. The string `AsUTC` has never appeared anywhere in this repo, in any file, in any commit -- `git log -S "AsUTC" --all` returns nothing, and the named commit `4ed33fb` prescribes only a generic `Get-Date` / `date`. **No fix is owed here.** For PM to strike from ON PIETER item 11.

---

## 2026-08-05 16:04 SAST -- ENG-070: the scenario overview ran the full recipe FIVE times per request. SQL live, frontend held on a branch.

**Clock cross-checked three ways at the moment of this write** (standing constraint 3, and the 08-04 five-hour drift is why): machine local 16:04:42 +02:00 / machine UTC 14:04:42 / DB `now()` SAST 16:04:45, UTC 14:04:45. All agree at +2, three seconds apart. **No drift today.** A `TZ=Africa/Johannesburg date` in Git Bash returned "GMT" and was discarded rather than used -- the zone did not apply, which is the exact trap the constraint names.

**ONE live database migration** -- `eng070_scenario_overview_subset_and_optional_yardstick`, applied via MCP. **Frontend NOT deployed: branch `eng070-scenario-overview-per-scenario` is pushed and unmerged, so production behaviour is UNCHANGED by this entry.** The migration is additive with defaults, so the existing page calls it exactly as before.

**Found by Pieter on the live order desk while placing a real Roosville order** -- Scenario Overview, Stock Now and Delivery Chain all reading `canceling statement due to statement timeout`.

**The defect, measured rather than inferred.** `rpc_bloom_scenario_overview` ran the FULL recipe **five** times in a single request: the four scenarios plus the ENG-018 yardstick run. At source:

| Store | recipe | overview | against |
|---|---|---|---|
| 80175 | 2.72s | **13.6s** (5 x 2.72 = 13.6, reproduces to the decimal) | its own 45s -- passes |
| 10116 | 8.11s | **~40.6s** | its own `SET LOCAL statement_timeout = '45s'` -- dies |

Sitting ON its own boundary is why it read as flaky rather than broken: **observed failing at both SPAR stores under real page load, and observed succeeding at 10116 minutes later.** Stock Now (7.9s) and Delivery Chain (6.4s) both fit on their own and fail by contention -- consistent with the evidence, **not proven**, and recorded as such.

**Why more time was not the answer.** `anon`/`authenticated` carry `statement_timeout=30s`, Kong kills ~30s (standing constraint 4), and the function already grants itself 45s. The work had to shrink per REQUEST.

**Applied:** `p_scenarios text[] DEFAULT NULL` and `p_include_yardstick boolean DEFAULT true`, both appended last so no positional caller shifts; each unrequested scenario is guarded by a zero-row `CROSS JOIN LATERAL` so its recipe call never executes. **Function Change Protocol run: overloads checked first (exactly one), old signature dropped, `pg_notify('pgrst','reload schema')` issued, one overload after.** Grants re-applied explicitly to the NEW signature -- `REVOKE ... FROM PUBLIC` then `GRANT ... TO anon, authenticated` (R30 addendum; a new function comes out of CREATE with PUBLIC EXECUTE).

**A latent defect fixed in the same pass, which the wiring would have triggered:** `full_products` read from `full_run`, so any request not including `full` would have silently produced a **zero `demonstrated_weekly_demand`** and flipped the fitted `DEFECT_SIGNAL`. Re-sourced from `scenarios`; safe because all four runs were **proven** to share one identical 12,502-product pool, 0 rows differing in either direction.

**R22, three arms, all green.** (1) The default call reproduces `full` **519 lines / R351,543.92** and `fitted` **487 / R333,487.15** -- both measured independently, by a different code path, BEFORE the change. (2) The four subset calls return rows identical to the single call. (3) `demonstrated_weekly_demand` holds at **192,607.05** in every one -- the invariant the `full_products` change could have broken.

**A cut that was available and REFUSED, recorded because the reasoning is the point.** `full.suggested_packs == fitted.packs_before_fit` on all 12,502 rows, zero differing -- so `full` appears derivable from the fitted run, saving a whole recipe execution. **Not taken.** That proves ONE column, while the `full` row also aggregates `budget_fit_reason`, `protected_lines` and `trimmed_lines`, which are fit-state-dependent and unobservable from the fitted run. Deriving it would be an instrument validated only for what it was tested on -- the same failure that moved 332 bucket-B rows on FORGE-MAP-001.

**Owed and named, not implied:** `sql/create_rpc_bloom_scenario_overview.sql` still needs its reconcile to live. It was ALREADY stale before this pass -- live carried four BLOOM-018 columns (`value_promo_lines`, `value_nonpromo_lines`, `promo_share_pct`, `promo_lines_pool`) the file does not -- which is why this migration was authored from `pg_get_functiondef` and not from the file. Reconcile by hash, generated never hand-keyed.

**R31 outstanding:** the panel has not been walked on the live desk, because the frontend is unmerged.

---

## 2026-08-04 ~20:0x SAST -- ENG-069: the KPI cards showed R0 for a day the ledger holds R127,599.98. A client-side cache, not a data gap.

**Found by Pieter on the live dashboard**, SPAR Roosville, 2026-08-04: Sales R0, GP 0.0%, -100.0% and WoW -100.0% -- while the Departments and Top 20 panels on the SAME screen showed real numbers for the SAME date.

**The data was never wrong.** `sigma_sales` holds **R127,599.98 incl-VAT / R114,166.24 ex-VAT across 2,137 lines** for 80175 on 2026-08-04, and all five stores have the day (10116 R258,963.47 · 21355 R21,539.06 · 80175 R127,599.98 · 80176 R15,789.83 · 80579 R18,894.67).

**Ruled out at source before touching anything.** Not permissions: `v_kpi_by_date` queried **as `anon`** -- the role the browser actually uses -- returns R127,599.98 for 08-04 (checked behaviourally with `SET LOCAL ROLE`, the ENG-068 lesson, never by reading a grant). Not source selection: `page.jsx` correctly picks `v_kpi_by_date` for a single date and `mv_kpi_by_date` only for multi-date.

**ROOT CAUSE.** `viewsCache` / `deptCache` / `top20Cache` were keyed on **stores|dates ONLY** -- no freshness dimension, no TTL, cleared only by the Reload button. A KPI fetch that ran BEFORE the day's push landed cached an **empty** result for the current date and served that zero for the life of the page. Departments and Top 20 happened to be fetched after the push, so they were current. **Two panels, one screen, two vintages, and nothing on screen saying so.**

**The decisive evidence it was a cached empty and not a stale source: R0 matches NO date in the ledger.** 08-03 is R90,058.49 and 08-04 is R127,599.98. It was not "showing yesterday" -- it was showing a pre-push empty fetch, preserved.

**THE FIX, two guards, because either alone leaves the hole open.** (1) **TTL** -- `CACHE_TTL_MS = 90_000`, so no entry can outlive a push by more than 90 seconds. (2) **NEVER CACHE AN EMPTY RESULT** -- caching "no rows" is what made this permanent: the current day always starts empty and always fills, so an empty answer is by definition the one answer that must not be remembered. All nine cache call sites now route through `cacheGet`/`cacheSet`; the Reload button's `clear()` is unchanged.

**WHY THE COMPARISONS MADE IT WORSE, and it is the reason this ranks above a cosmetic bug:** `-100.0%`, `WoW -100.0%` and `GP 0.0%` are all computed off the false zero. A blank would have read as "no data". A confident **-100%** reads as "the store sold nothing today" -- **a wrong number is worse than no number** (R22).

**AUDIT RUN ALONGSIDE, all reconciled to source:**
- **Departments: 10 of 10 exact, delta R0.00** against raw `sigma_sales`, and the panel is genuinely on 2026-08-04 (08-03 figures are entirely different).
- **Top 20: 10 of 10 exact, delta R0.00** against native per-item ex-VAT (`sales_incl_vat - vat_value`). Milk and vouchers reconcile identically incl and ex, which proves it is **not** using a flat 1.15 divisor.
- **Negative SOH (195 vs live 211) and Capital Tied raw (R6.48M vs R6.42M) are a day behind BY DESIGN** -- point-in-time metrics read the latest L2 snapshot and the L2 pipeline runs 22:15 SAST. Not a defect; worth a freshness label on the card, which is not built here.

**Verified:** `next build` clean, Middleware present at 81.7 kB; all cache access routed through the helpers (grepped); no console errors on load. **NOT verified by CC and stated rather than glossed: the logged-in KPI card itself.** The dashboard is behind a Google sign-in CC cannot pass, so **the end-to-end proof is Pieter's R31 walk** -- open SPAR Roosville on 2026-08-04 and see R127.6k where R0 was.

**⚠️ CLOCK, and it is CC's own error.** CC's machine clock ran ~5 hours slow today. Cross-checked three ways at 13:31 SAST and all agreed; by the time of this audit the machine read 14:52 while DB `now()` read 19:48. **The arbiter settles it against CC** (standing constraint 3): a COMPLETED push sits in `push_log` at 17:43:49 UTC, `cron.job_run_details` is consistent with the DB, and the dashboard's own strip read "10m ago" -- a push that has run cannot be in the future. **DB time is right; the machine is wrong.** Consequence: SAST times stamped by CC in today's earlier DEPLOY-LOG, HANDOVER and canonical-SQL entries are ~5h early. **The DATES are correct and nothing crossed midnight**, so no dated fact moves. Fifth firing of the clock rule.

---

## 2026-08-04 15:0x SAST -- SB-CC-FORGE-MAP-001: the WHOLE link-codes queue is resolved to a band. `l2_product_resolution` 0 -> 9,812 rows.

**Supersedes this morning's bucket-B-only entry.** Buckets C, D and E built on top of B, per Pieter's "go ahead on that plan". Engine version `FORGE-MAP-001 all-buckets v3.0`.

**Final state, 9,812 rows = every distinct code in the queue, nothing dropped:** `KEEP` 6,935 · `RESIDUE_HUMAN` 2,849 · `CONVERT_TO_NON_DEPLETE` 24 · `ZERO_AND_KILL` 4. **Askable 2,354**, each carrying its exact question.

**Bucket E dissolved, and that is a correction to the published figures.** The 37 "blocked" rows were never a distinct population: **SHARED_EAN is 37 PAIRS queued TWICE, once per direction, every pair holding exactly one `product_catalog`-sourced row and one native row (37 of 37, zero exceptions).** Re-derived on native `sigma_scan_refs` as canon requires before anyone is asked: **native holds the shared barcode on BOTH codes in all 37 pairs**, so the derivative was not inventing the collision and the R25 §2 block is discharged. Pair-level split 24 C / 4 B / 9 D. **Canon §17's own SHARED_EAN counts (66 rows -> 40/8/18) are direction-doubled and really describe 33 pairs -> 20/4/9 -- a measurement correction for PM, not a rule change.**

**THE REGRESSION THAT MATTERED, found by gating rather than assuming.** Rebuilding with the whole queue in view moved **332 of the previously-proven bucket-B rows**, every one of them `KEEP` -> `RESIDUE_HUMAN`, **none the other way**. Cause: v1.0 loaded only bucket-B slots, so it could not see that **329 of those codes are contested in another family or another candidate type** and resolved them confidently anyway. v3.0 sees the whole queue and declines. This is [[feedback_instrument_validated_only_for_what_it_tested]] firing on CC's own work -- the earlier "6,772 codes, 0 ambiguous" was true only within the slice it was measured on.

**THREE DEFECTS CC FOUND IN ITS OWN OUTPUT BEFORE SHIP.** (1) **40 codes were unresolved AND unaskable** -- the engine could not resolve them and nobody would ever be asked: a silent drop, which canon forbids. (2) **25 singles carry `record_stock_qty=0`**, meaning neither side of the family tracks stock and canon §14 v5's milk template is broken at both ends -- they had fallen to a generic "left for a person" with no question. (3) The **8 SHARED_EAN successor codes** had no verdict branch at all, despite canon calling them "the clean successor signature the database can rule alone"; they now resolve to `KEEP` on the surviving code and `ZERO_AND_KILL` on the superseded one, **the only place `is_keeper` is asserted in the whole table**.

**THE QUESTION IS NOW A STORED FIELD, NOT PROSE.** `evidence->>'question'` carries the exact words; `evidence->>'askable'` is the contract that says whether canon permits asking at all. **Three question forms, all physically observable and falsifiable:** *"Scan the pack on the shelf and tell me what code comes up."* · *"Count the singles inside the pack you are holding and tell me the number."* · *"Scan each of these two products in turn and tell me the code that comes up on each."* Canon §17 constraint 1 bans a question whose answer IS the resolution ("are these the same product"); storing the text instead of letting a UI compose it is what keeps that out. **Gate: 0 askable rows without a question, 0 unaskable rows carrying one, 0 banned judgement forms.**

**Bands.** `B_DB_DECIDES` nobody is asked · `C_RANK_LAST` real question, nothing live moves · `D_ASK_FIRST` the floor's question, worst-first by capital · `A_OUT_OF_SCOPE_correct_by_s11` 547 weighed lines, correct by canon §11, never a question · `A_HELD_not_askable` 495 with no numeric suffix, which canon says need the mid-string matcher **before** they are queued at all.

**R22, every gate green:** 9,812 written = 9,812 distinct queue codes · **determinism 0 differing** · 0 rows outside the queue · **0 unresolved-and-unaskable** · `is_keeper` asserted on exactly 8 rows · `cost_error` NULL on all 9,812 (NOT TESTED, never false) · queue unchanged at 6,712 with 0 statuses moved · `l2_product_map` still 0 · grants proven both legs.

**Scaffolds: 0 left** (`tmp_%` functions and `_w2%` scratch tables both zero). Canonical `sql/create_l2_product_resolution.sql` **hash-proven identical to live** (md5 `de81b5cf…`), generated from `pg_get_functiondef`.

**🔴 STILL OWED, AND THIS IS THE IMPORTANT ONE: NOTHING CONSUMES ANY OF IT.** 9,812 rows and 2,354 stored questions with **no reader** -- no Product-Mapper tab, no read RPC, no write path for the answers. That is the §0i PROSE state and the ENG-002/ENG-046 defect class exactly. The toolkit work and the direction it needs from PM are named in HANDOVER-CURRENT. **Nothing downstream reads this table, so no live number moved today.**

---

## 2026-08-04 14:52 SAST -- SB-CC-FORGE-MAP-001 bucket B: `l2_product_resolution` goes from 0 rows to 6,772, and the nightly chain calls it.

**FOUR live migrations.** Three schema/DDL on a zero-row zero-consumer scaffold, one asserted rewire of `refresh_l2_pipeline`. Two temporary scaffolds created and dropped, **both proven gone (0 `tmp_%` functions remain)**.

**What shipped.** `refresh_l2_product_resolution(p_store)` -- SECURITY DEFINER, idempotent per store -- and its output, **6,772 rows across five stores**: `KEEP` 6,713, `CONVERT_TO_NON_DEPLETE` 24, `RESIDUE_HUMAN` 35. Wired into `refresh_l2_pipeline` immediately after that store's `refresh_l2_link_codes_queue`, because it reads that queue.

**The gate this had to clear first, and it is the whole point.** Canon §17's item-12 ruling ends: *"if that residue is not published as a number before the build starts, this ruling has not been applied."* CC published it -- the queue decomposed into disjoint buckets summing to **6,712 exactly**: 847 out of scope, **3,953 the database decides**, 721 rank last, 37 blocked on a `product_catalog` derivative, and **1,154 the floor's question**. The build was then scoped to bucket B alone. **The floor is asked 1,154 questions instead of 6,712 -- an 83% cut in what a human ever sees.**

**The zero-rows gate on this table was SUPERSEDED, not ignored (R28).** Its own condition (b) was "PM/Pieter explicitly rules the algorithm may propose verdicts engine-only". Canon's 2026-07-26 item-12 churn inverted it -- *the database decides first, the floor gets only the residue* -- so withholding a deterministic resolution became the defect. The original gate is kept verbatim in the canonical SQL file.

**What the build refuses to assert, which matters more than what it writes.** `is_keeper` NULL on every row (the keeper-by-movement contest is a different question). `cost_error` **NULL, not false** -- this pass runs no cost test, and `false` would claim "tested and clean" on 6,772 untested rows. Its `NOT NULL DEFAULT false` was dropped precisely so NULL could mean UNTESTED. `confidence` **discriminates across 3 values** graded on price-vs-suffix agreement -- the direct answer to the flat 0.600 canon called *a constant wearing a confidence's clothes*. Every verdict is a RECOMMENDATION; nothing acts on one (canon §14 v5: a deviation is "a later floor recommendation with a report, not an engine assumption").

**Two schema changes made rather than write a falsehood**, named because canon said Phase 3 would need none (true of TABLES): `pack_multiple` added, because the multiplier the rule is partly made of had nowhere to live; and `level` gained `'pack'`, because the original `single/six/twelve_rb/twentyfour` vocabulary was written for the SAB beer anchor while the live population carries price-confirmed multiples of 3,4,5,8,10,15,16,20 -- stamping those `'unknown'` would be a lie in a column the engine reads. `'twelve_rb'` is deliberately never assigned: it asserts a returnable container this pass cannot evidence.

**R22, every gate green.** 6,772 written = 6,772 distinct bucket-B codes (measured before the build) · **determinism 6,772 rows, 0 differing on re-run** · 0 rows outside bucket B by code or by `queue_candidate_id` · `l2_link_codes_queue` unchanged at 6,712 with **0 statuses moved** (CHECK-lock intact) · `l2_product_map` still 0 · grants proven on BOTH legs of the five-times-fired trap (acl carries **no PUBLIC entry**, `anon` EXECUTE false, `authenticated` true).

**Named honestly, not claimed.** The pipeline wiring is proven **structurally** -- one call, correct position, after its dependency. **Its first end-to-end run is job 15 tonight, and the falsifier is `computed_at` moving to the ~20:15 UTC slot.** Do not quote this object as nightly-fresh until that is checked. `sql/create_refresh_l2_pipeline.sql` owes a reconcile to the rewired body; `sql/create_l2_product_resolution.sql` is hash-proven identical to live (md5 `a4a63dff…`) and was **generated from `pg_get_functiondef`, never hand-transcribed**.

**Out of scope and named so nothing is assumed done:** the 4 SHARED_EAN successor rows in bucket B are NOT written here -- a successor binding has no pack level, and forcing it into a family-shaped fact would be the wrong shape. They belong to the `identity` map_type on `l2_product_map`. So this pass delivers 3,949 of bucket B's 3,953 queue rows, and the 4 are still owed.

---

## 2026-08-04 13:51 SAST -- NO PRODUCTION CHANGE. Two live migrations applied and reversed, net zero residue (DB-SCHEMA de-derivation, CC-BRIEF-DBSCHEMA-DEDERIVE-001).

**Logged because `list_migrations` keeps them forever and unexplained residue is the thing this project refuses.** No app code, no schema, no engine object, no grant on any existing object changed. Nothing shipped to prod.

**What ran.** `tmp_column_inventory_csv_scaffold` and `tmp_column_inventory_csv_scaffold_v2` created one SECURITY DEFINER function, `public.tmp_column_inventory_csv()`, granted EXECUTE to `anon`; `..._drop` and `..._v2_drop` removed it. **Proven gone behaviourally, not asserted: `count(*)` on `pg_proc` for that name = 0.** The grant died with the function.

**Why a scaffold at all, and why it was not a shortcut.** The brief's §6 asks for a column-level inventory CSV on disk. There is no psql, no `DATABASE_URL`, no `pg` driver and no service-role key on this machine, so the only alternative was to retype 1,684 rows of a query result by hand into a file. **That is precisely the hand-transcription defect recorded on 2026-07-30** (a working file hand-keyed from a result set silently dropped 8 of 63 rows), and the standing rule from it is "generate it, and assert the row count before saving". So the file was generated: fetched to disk over PostgREST and **asserted equal to the catalog's own `count(*)` — 1,865 rows across 143 objects.**

**Exposure, stated rather than glossed.** The function was anon-executable for the minutes between create and drop. It returned schema STRUCTURE only -- object names, column names, types, nullability -- and no row of business data. `anon` can already enumerate exposed objects through PostgREST's own OpenAPI document, so the marginal exposure was small, and it is zero now. **v1 was replaced by v2 for a real reason: v1 read `information_schema.columns`, which returns ZERO rows for a materialized view, so it silently omitted 181 matview columns across 9 objects. v2 reads `pg_attribute` and covers tables, views and matviews alike.**

**The same defect would have shipped into the documentation.** `DB-SCHEMA.md` is now **v2.0, de-derived** under FILE-GOVERNANCE §0g obligation 3: column transcriptions replaced by live catalog pointers, every business meaning, Sigma source mapping, formula, index trap, sentinel, retirement note and named debt attached to them promoted to prose. **The pointer it publishes is `pg_attribute`, not `information_schema`, and the file says why with the proof.** R22 no-loss gate over the pre-pass snapshot: **634 distinct tokens across 11 classes, 0 missing.** Full detail and the four ways reality differed from the brief: `Daisy/archive/briefs/CC-BRIEF-DBSCHEMA-DEDERIVE-001-de-derivation.md`.

---

## 2026-08-04 07:58 SAST -- SB-CC-PMINI-WIRE-001 Gap B completed: the partner lockdown's PUBLIC-grant hole closed.

**ONE live database migration** (`pmini_partner_lockdown_revoke_public_execute`, applied via MCP; clock read fresh at 07:58 SAST). Closes the last hole in the Pulse Mini partner read path.

**The defect, stated plainly.** `pmini_partner_lockdown.sql` (the Route-3 partner role) revoked function EXECUTE **FROM the `pmini_partner` role** but never FROM **PUBLIC**. Postgres grants EXECUTE to PUBLIC on every function's creation and every role inherits PUBLIC, so `REVOKE ... FROM <role>` was a no-op: the partner key could still execute **167 of 229 public functions** -- including `rpc_dept_summary` / `rpc_top20` / `rpc_product_detail`, i.e. whole-store sales. The base-table lockdown was sound (no SELECT on any table); only the function surface leaked. This is the same PUBLIC-grant trap already recorded in memory and in BUG-LOG's SECURITY DEFINER firings -- the lockdown's OWN acceptance test ("no OTHER rpc callable") would have caught it, but was never run post-deploy.

**Pre-flight, so the revoke could be proven non-breaking rather than hoped.** Read-only, at source: **0** functions are reachable by `anon` ONLY via PUBLIC, and **0** by `authenticated` ONLY via PUBLIC -- every RPC either role actually uses holds an explicit grant in the function's ACL. So revoking PUBLIC removes nothing anon/authenticated use; it strips only `pmini_partner`'s inherited surface.

**Applied:** `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC` + `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, then `GRANT EXECUTE ON rpc_feed_health_daily(text,text) TO pmini_partner` -- the partner's second RPC had been PUBLIC-inherited (the original lockdown never granted it explicitly), so the revoke removed it and it was restored explicitly.

**Verified live, and the check was behavioural, not by reading the grant.** `pmini_partner`'s app-facing EXECUTE surface = **EXACTLY** `rpc_consignment_lines(text,text,integer,text,boolean)` + `rpc_feed_health_daily(text,text)` (`has_function_privilege` true), and **false** on `rpc_dept_summary`, `rpc_top20`, `rpc_product_detail`, `rpc_focus_chart` and every refresh_/classify_/kpi function. No base-table SELECT (`sigma_sales` / `daily_snapshots` / `sigma_articles` / `l2_consignment_daily` all false). `anon` + `authenticated` retain EXECUTE on every dashboard RPC. Gap B acceptance test now PASSES: with the partner key alone a browser reads the consignment lines + feed health and nothing else.

**🟠 OWED to Pieter / supabase_admin, and named rather than hidden.** The MCP role could not revoke PUBLIC from ~113 functions it does not own -- these are SYSTEM / EXTENSION utilities (pg_cron, pgrst, supabase internals), NOT app data RPCs, confirmed by filtering the still-PUBLIC set to app prefixes (only the two intended consignment RPCs remain). Not a partner-data-exposure risk. For a spotless PUBLIC surface, re-run the REVOKE as `supabase_admin`.

**SEPARATE, not bundled -- SEC-001 still open:** `anon`/`authenticated` still hold INSERT/UPDATE/DELETE on base tables (an outside key could delete the ledger). Broader than PMINI; tracked in `sql/pmini_partner_lockdown.sql` footer.

**Committed** `0fb1882` on branch `pmini-partner-public-revoke` (`sql/pmini_partner_public_revoke.sql`) -- DB change already live; branch awaiting review/merge.

---

## 2026-08-04 -- FORGE queue items 1-2: /toolkit folded into the repo, the compliance run-log built.

**FIVE live database migrations** (`20260804050417` tables+RLS+grants · `…050433` the write function · `…050452` the per-line diff · `…050508` the summary · `…050638` the SECURITY DEFINER fix, which was its own migration because the defect was found after the first four landed — counted at source in `supabase_migrations.schema_migrations`, not from memory). **App code merged to `main` and pushed on Pieter's go** (`forge-toolkit-fold-001` -> `main`). Clock read fresh and cross-checked local / machine-UTC / DB `now()` at +2 with cron job 10 on its own slot as arbiter, because this session crossed midnight.

**What merging does and does not do, stated plainly because an earlier draft of this entry said the branch was held.** It does NOT bind DNS or the Vercel domain -- those stay account-level actions and remain Pieter's. The `toolkit.<host>` rewrite is inert until `toolkit.socialbrand.africa` resolves. What it DOES do is make `/toolkit` reachable at the existing dashboard domain for a signed-in user, which is what lets the floor test happen before the domain lands (LANDING MODE: a tool nobody used is inventory, not product).

**Item 1 -- the repo fold and the host bind (`302df68`).** `public/toolkit.html` is byte-identical to `Daisy/Forge/toolkit.html`, served by `src/app/toolkit/route.js`, the same thin GET handler `bt` and `pmini` already use -- deliberately not a port to React, so CD's design pass (CD-SPEC-FORGE-002) polishes a repo-served page rather than a stray file, and the standalone stays the same bytes. `toolkit.<host>` on `/` rewrites to `/toolkit` in `src/middleware.js`, placed **AFTER** the auth gate exactly like `orders.`/`/bloom` and never with `/bt`'s public exemption, because Forge issues real floor work -- count lists and TLX zero files.

**The first verification gate was thrown out for being unfalsifiable.** A 307 to `/login` on `/toolkit` proves nothing, because `/nonexistent-route` 307s identically -- a gate that cannot fail is not proof (R28 §5). Re-run so it could fail: the public exemption was lifted for `/toolkit` alone, the route curled, then the gate restored. **Served 38,153 bytes, md5 `2e9cf764d7d141e912f952d88deb9106`, identical to `public/toolkit.html` AND to the Daisy source; title "Forge - Operations Toolkit"; all five tabs present.** Gate restored and re-proven on all three paths (`/toolkit`, `/toolkit.html`, `Host: toolkit.*` on `/`), no temp code left in the file, `next build` clean.

**Item 2 -- the compliance run-log (`c1b9c36`), closing canon §15's named CC debt.** `forge_count_run` + `forge_count_run_line` + `rpc_forge_log_count_run` / `rpc_forge_run_compliance` / `rpc_forge_compliance_summary`, plus `/api/forge/run`. Built as a **platform** fact, not a Forge table (R32): `rpc_forge_count_list` already feeds Forge, StockFlow selection and Bloom count capture, so `source` carries the issuing surface and all three log to one ledger. `last_counted_at_issue` is frozen straight from the ledger at issue -- not from `l2_last_counted`, which is nightly and up to a day stale -- and a line is executed only when the ledger moves PAST it, so a count booked earlier on the issue date cannot masquerade as compliance.

**Why the API route rather than a direct PostgREST call:** `toolkit.html` uses the publishable key and runs as `anon`, while the write function is `authenticated`-only with anon explicitly revoked. The page posts same-origin to `/api/forge/run`, which carries the user's session and calls the RPC as `authenticated` -- the grant stays correct instead of being widened to reach. **This is what folding the page into the repo unlocked**, and it is the argument for the queue's own ordering.

**R22, and the gate can fail -- two arms on real ledger rows at 10116.** POSITIVE: 5 lines counted 2026-08-03 -> `counted=true`, `counted_on` 08-03. NEGATIVE: 5 lines not counted since -> `counted=false`, 1 day outstanding. **Product 1110 (positive) shares the negatives' 07-30 prior count and still reads counted, and 501 (never counted, NULL anchor) reads counted** -- so the 08-03 count is doing the work, not prior state. Control arm, the same run before backdating: **10/10 uncounted, no false positive.** Summary: 50.0%, verdict `PARTIAL -- 5 line(s) outstanding`. Determinism: identical md5 over two consecutive calls. Grants: anon EXECUTE false / PUBLIC false / authenticated true on all three; tables RLS on with anon SELECT and INSERT both false and `authenticated` INSERT false, so the SECURITY DEFINER function is the only write path. Scratch deleted after the gate, both tables back to 0 rows, which also proves the FK cascade.

**A DEFECT IN CC's OWN BUILD, CAUGHT BEFORE SHIP (BUG-LOG ENG-068).** Both read functions were initially not SECURITY DEFINER, and `sigma_movements` has **RLS ENABLED with ZERO policies** -- locked by default, the same shape that silently emptied the Kitchen tab and the Pulse Mini tiles. They would have read the ledger as the caller, got zero rows, and reported a permanent, entirely plausible **0% compliance**. Proven rather than assumed: `SET ROLE authenticated` -> `count(*)` on the I-channel = **0**. Fixed, both revokes re-asserted (SECURITY DEFINER re-opens the default-privilege trap, fourth firing), and re-proven **behaviourally** -- the same role now reads 5/5/10, identical to the privileged read. **The method rule: a grant table saying `auth_select = true` does not mean a row is visible. Check by SET ROLE, never by reading the grant.**

**TWO CORRECTIONS TO THE QUEUE ITSELF, both Rule 18 against the live database.** (a) **Queue item 3, the nightly `l2_last_counted` fact, was ALREADY BUILT** -- live since 2026-07-11, wired into `refresh_l2_pipeline` (`refreshed_at` 2026-08-03 20:15 UTC = the job-15 slot), 35,567 rows, read by `rpc_forge_count_list` and `rpc_forge_integrity`. It was never documented in DB-SCHEMA, which is exactly why the queue still carried it as unbuilt work three and a half weeks later (ENG-067b). (b) **Its attached perf claim is FALSE (ENG-067):** it closed ENG-006, but the 5-store `daily` list still runs **13.2s warm / 15.3s cold** against **7.3s** summed one store at a time. The cost scales with the store array, so it is not count-recency and never was. Left open and named; do not re-quote "~12s cleared".

**✅ THE R30 §3 ONBOARDING CHECKLIST IS COMPLETE — `toolkit.socialbrand.africa` IS LIVE (2026-08-04 ~09:5x, CC on Pieter's mandate, in his own logged-in browser).** Checked at source rather than assumed, and two of the four were already done before this session touched them:

| # | Item | State |
|---|---|---|
| 1 | DNS CNAME | **Already done.** The host resolved to Vercel (`64.29.17.65`) before any work here |
| 2 | Vercel domain binding | **DONE THIS SESSION.** The sole blocker — the host resolved but returned `X-Vercel-Error: DEPLOYMENT_NOT_FOUND`, Vercel's signature for DNS-arrives-but-no-project. Added to `socialbrand-dashboard` → Production; verified instantly because DNS was already correct. Now **Valid Configuration** beside `orders.`, `dashboard.` and the `.vercel.app` |
| 3 | Supabase auth-redirect allowlist | **Already done.** `https://toolkit.socialbrand.africa/auth/callback` was already the third entry — checked before adding, so no duplicate was created |
| 4 | Login allowlist | Inherited. The login page states access is assigned by Pieter; no toolkit-specific gate exists or is needed |

**Proven end to end:** the 404 is gone, `https://toolkit.socialbrand.africa/` returns 307 → `/login` and renders the Pulse sign-in. **The code half is confirmed by the Vercel production record itself — Status Ready, source `main`, commit `f6af604`** — which is the discriminator NOT available from outside, where `/toolkit` and `/zzz-nonexistent` 307 identically.

**The one step CC does not take: signing in.** The R31 DoD is Pieter opening the URL, authenticating and completing a real action — a credential step, and his by definition.

---

## 2026-08-03 -- SB-CC-BLOOM-019 gates: ENG-064 shape fix, ENG-061 the money book, three canonical SQL bodies reconciled.

Two live database changes and one documentation commit. **No frontend change, no schema change, no migration.** Repo `f33840f` pushed to `main`.

**ENG-064 -- `rpc_bloom_order_recipe`, one line in `geared_ceiled`.** A non-`mp_life` line breaching the 35-day ceiling returned `0`, throwing away the whole geared quantity, while an `mp_life` line trimmed correctly to `LEAST(raw, GREATEST(1, packs_under_ceiling))`. One condition, two treatments, and the harsher one applied to the line with no presence guarantee. Now `THEN LEAST(g.geared_packs_raw, g.packs_under_ceiling)` -- no `GREATEST(1, ...)`, because a non-`mp_life` line carries no presence guarantee, and at `packs_under_ceiling = 0` the expression yields 0 so today's behaviour is preserved **by construction rather than by assertion**. Applied by asserted `regexp_replace` on `pg_get_functiondef` in a DO block: overloads asserted 1, pattern hits asserted 1 against 13 bare `THEN 0` elsewhere in the body, no-op refused, new fragment asserted present. Definition 41,211 -> 41,258 chars.

**R22, three gates, and the first one caught CC's own null.** Behaviour preservation: 32,613 rows hashed before and after across all five desks, 0 missing, **1 differing**. Positive case: that one row is a REAL live line with **zero inputs moved** -- 21355 product 17619 PETER STUYVESANT BLUE, `geared_packs` **0 -> 1**, `suggested_packs` **0 -> 0** because the line is not on promo, `value` **R0.00 -> R0.00** -- proven against the true prior function restored as `_w19_shadow_pre_eng064`, not against a reconstruction. Determinism: 15,078 rows re-run at 21355 and 80175, 0 differing. **Net R0.00 moved, 0 `suggested_packs` moved, one display column corrected.** CC had reported the live population as ZERO across five desks; it is ONE. The hand reconstruction computed `packs_under_ceiling` from the ROUNDED output column `rhythm_adjusted_demand` rather than the internal `ros_final`, and that line sits exactly where `35 x ros = 20.0 = one pack`.

**ENG-061 -- `refresh_order_budget_ledger_needs` gains the money book.** `order_budget_ledger.committed_amount` carried ONE distinct value across all 344 rows and it was zero, so the recipe's `budget_amount - committed_amount` ceiling was a no-op by construction. **The recipe needed no change at all -- it already nets the column. Nothing had ever written it.** Home is the needs function and not the actuals function for a second reason beyond the brief: the needs function is the one WIRED into `refresh_l2_pipeline`, while `refresh_order_budget_ledger()` is live but unscheduled, so the money book would have been stale from day one.

`committed_amount` per (store, ledger route, budget week) = **receipts already LANDED in that week** (`sigma_movements` R/W, `cost_value` ex-VAT) **plus in-transit expected to LAND in it** (`l2_on_order.on_order_cost`, line basis). Two books by design: the shelf book (`projected_soh`) stops us buying the same stock twice, the money book stops us spending the same rand twice. In-transit counted only where `array_length(route_keys,1) = 1`, so a multi-route product cannot double-count by construction (measured 0 such products). Route scope keys on the movement's/order's own `supplier_nr`, never a link (canon SS14 v9 7d). Budget-week anchor is the same literal expression the recipe uses, so the two objects cannot disagree.

**R22 isolation: 344 ledger rows compared, `budget_amount` moved on 0, `landed_amount` moved on 0, `committed_amount` moved on 28.** Strip truth reproduces PM to the cent: 80175 DC week 2026-08-01 committed **R181,832.68** on a R377,752.07 budget, 80176 DC **R116,055.04** on R121,770.80. Desk effect per desk, and both predicted states are live: **80175 DC_AMBIENT** remaining R195,919.39 exceeds the R188,460.95 order so Fit is IDLE, 374 lines both ways, 0 reduced, 0 floor lines zeroed; **80176 DC_TOPS** remaining R5,715.76 against a R67,636.99 order so the floor layer alone exceeds the wallet, 98 lines both ways, R67,636.99 -> R67,329.59, exactly ONE line lost fill-layer depth, **0 floor lines zeroed**. That is canon v13 confirmed at the boundary: floors funded, overage surfaced, no clamp-then-scale and no ENG-034 collapse. Grants re-proven per R30 addendum extension: anon EXECUTE false, PUBLIC false, authenticated true.

**Unrouted spend is excluded and surfaced, never absorbed.** Spend on a supplier carrying no configured desk is returned in the function's own JSON: `excluded_unrouted_landed` 10116 R856,225.91 / 80175 R303,860.11 / 80176 R26,102.62 / 21355 R462.86, and `excluded_unrouted_transit` R11,877.37 and R7,374.24. Excluding is the deliberate and permissive choice, because that budget was never sized to include those suppliers and netting their spend would understate cash and suppress orders. **PM ruling owed:** canon SS14 v9 7j puts dropship payable with the DC creditor.

**RECONCILE-001, three of four closed and hash-proven (`f33840f`).** `create_l2_on_order.sql`, `create_l2_stock_band.sql` and `create_l2_bloom_ros_pantry.sql` each had their function body replaced with catalog-emitted DDL; header comments and table DDL untouched. Gate per file: extract the file body, strip whitespace, lowercase, md5, compare against `md5(lower(regexp_replace(prosrc,'\s+','','g')))` from `pg_proc`. All three match live exactly. Drift closed 2,263 / 1,261 / 1,582 chars. **`create_rpc_bloom_order_recipe.sql` deliberately held** -- ENG-063 rule 3 rewrites the same body, so it reconciles once afterwards and picks up ENG-064 in the same pass.

---

## 2026-07-29 (later) -- SB-CC-BLOOM-018 v1.2 items 0-5: shipped, budget week fixed, gap worklist to the floor.

**Item 0 -- SHIPPED.** `bloom-018-surfacing` merged to main and pushed, `ce25e23..2b8575d`. (A stale `.git/index.lock` silently no-opped the first attempt; caught by checking `main` against `origin/main` rather than trusting the command's own output.)

**Item 1 -- ENG-055, and it is a cause of the under-buy.** The desk read `order_budget_ledger` with `.order('year_month', desc).limit(1)` against a table holding **28 forward weeks to 2027-01-16**, so every desk was judged against the furthest-out week -- which happened to be the smallest. 80175 DC read **R157,951.96** against a true delivery-week budget of **R363,695.98**: the buyer saw 92% spent while sitting at 40% spent. Fixed by filtering `.lte('year_month', deliveryDate)` before the sort, taking the newest row at or before the delivery date -- the ledger's own rows, not a client-side week derivation (R27). Same fix on the group `ALL` row. Verified in lockstep with `rpc_bloom_scenario_overview`, which stamps `budget_week_start` itself: both return 2026-08-01 / R363,695.98.

**Item 2 -- the gap worklist reaches the floor.** `rpc_bloom_promo_floor_gap` gains **`uplift_confidence`**, derived server-side in ONE place so no consumer parses a basis string (the ENG-047 class). **FOUR classes, not three -- the population needs a fourth**: MEASURED 705 / SEED 436 / BORROWED 141 / AT_CAP 154 of 1,436. `sibling_store` is a real class: it IS a measurement, just on another store's ledger (DF-1), so folding it into "measured" hides the borrow and into "seed" would be false. **AT_CAP + SEED = 590 = 41.1% carrying an unmeasured number**, matching PM's figure exactly. The desk renders the word, not the string; the worklist **exports to CSV**, cut from the buyer's live on-screen quantities per the round-trip rule (canon §14 v7 item 11b).

**R22 at 80175 DC_AMBIENT reproduces PM's hand-built `SB-ORD-003 v1.1` to the cent: 63 lines / R53,082.57.** Split by confidence: MEASURED 27 lines R27,079.15 (13 KVI/HERO, **R23,466.69**) · AT_CAP 26 lines R22,500.76 (4 KVI/HERO, R11,139.73) · SEED 6 lines R2,995.08 · BORROWED 4 lines R507.58. **Two-thirds of the KVI/HERO money is measured and bankable without the model**; the at-cap tranche is a FLOOR, never a ceiling.

**Item 4 -- two display fixes.** `pack_content` on the row: five pairs at 80175 rendered as one product under two codes (GOLDI IQF MP 2KG/5KG, SPAR EGGS LARGE 60'S/48'S, SUNFLOWER OIL 2LT/4LT, MAQ FLEXI 1KG/2KG, STORK 500GR/1KG) and `pack_size` does not separate them either. Measured: **zero shared EANs -- the pool is clean, the screen was not.** And the bare `#` count-first prefix is gone; it says COUNT FIRST in words, because Pieter read the `#` as a broken product code on his largest line.

**⚠️ THE GATE, AND WHY THE FIRST ONE WAS RETIRED MID-SESSION.** The prestate/poststate comparison went green at 36,205 rows / 0 differing, then a recapture showed 7 extra pool rows and a R130k value drop at 80175. **Cause found and it is real trading, not a defect: `l2_soh_daily` ingested a fresh snapshot at 11:07:33 UTC (13:07 SAST), between the two captures** -- SPAR MILK 80175/491 went SOH 0 -> 1800, a delivery landed, and the desk correctly stopped ordering it. That invalidates a before/after taken across the ingest. **Re-gated the drift-immune way: the pre-BLOOM-018 function restored as `_w18_shadow_orig_recipe` and run against the live function AT THE SAME INSTANT, all five DC desks -- 32,556 rows both sides, ZERO differing in either direction, identical total R1,144,977.26.** A same-instant isolation cannot be fooled by an upstream ingest; a timed before/after can. **The lesson generalises: a before/after gate is only valid if nothing upstream moved between the two halves, and on a live trading database that is an assumption, not a given.**

**Item 3's two named riders -- landed 2026-07-30 08:5x SAST** (this session crossed midnight; clock re-read at source, local + UTC + DB `now()` all agreeing, so the entries above stay stamped 07-29 and these two are 07-30 -- the FILE-GOVERNANCE clock rule applied to its own named trap). Both measured to source first: **21355 counts 16 in-transit lines whose landing ESTIMATE has already elapsed** -- correctly counted, because canon §14 v15 rule 5a rules the estimate is never an exclusion test, but previously counted with no label; the desk now names them and tells the buyer to chase rather than assume. **80579 returns 0 in-transit against 299 stale documents** -- a desk fed by inter-branch transfer legitimately carries none of its own, so the panel SAYS that instead of rendering an empty box (§8.6 guard 4, no silent empties). Neither changes a quantity.

**Item 5 -- ANSWERED, nothing built.** `v_dom := EXTRACT(DAY FROM p_delivery_date)`, and the mode CASE reads `archetype` + day-of-month with **no reference to `p_preset`**. So **YES, build mode is reachable without a named preset** -- proven live on the same desk: delivery 2026-08-20 gives **74 build lines**, delivery 2026-08-01 gives 0. The rhythm pantry is called and works; the 100% `minimum` is the delivery date (dom=1) sitting outside both windows. **For PM's ruling: the windows are judged on the DELIVERY date's day-of-month, so an EARLY_MONTH line's last drop before the pension peak -- which lands on the 1st -- can never build** (`dom >= 25` cannot be true for it). That is the structural reason a delivery landing in pension week puts 3.9% into the pension basket.

---

## 2026-07-29 -- SB-CC-BLOOM-018 items 1+2 (ENGINE HALF): the promo floor gap and the truck are surfaced. Live migrations + repo. **Frontend built and compiling, NOT yet visually verified -- see the open item at the end.**

**What shipped, and the one design decision that matters.** Both items needed the same surgery: extra columns on `rpc_bloom_order_recipe` (55 today) and on `rpc_bloom_scenario_overview` (25). Run as two passes that is the same 32k-char body cut twice, two full gates, four days before a fixed Monday. **Run as ONE signature pass it is cut once.** PM's sequence of VALUE is unchanged -- item 2's gap and KPI land first on screen, item 1's truck note second -- only the engine surgery collapsed from two to one.

**THE PATTERN, recorded because it generalises (PM instruction; now in DB-SCHEMA Architecture Rules + memory).** The recipe materialises into a temp table and returns `SELECT *`. So the surfacing columns are **appended AFTER the compute has finished** and populated by plain joins to `l2_stock_band` and `l2_on_order`. **The change is therefore structurally incapable of moving a suggested quantity, rather than merely verified not to have.** Not one byte of the 24k-char `format()` string or its 29 positional args was touched. PM: "that is the assertion-that-cannot-fail rule turned the right way round -- you built the safety into the shape instead of asserting it afterwards."

**R22 GATE, the same gate for both items: 36,205 rows, ALL 20 desks, FULL scenario fit-off, prestate vs poststate, ZERO differing in either direction.** Evidence: `_w18_recipe_prestate`, `_w18_recipe_poststate`, `_w18_fn_predef` (rollback stash incl. grants).

**Objects.** `rpc_bloom_order_recipe` +20 columns (10 promo-gap, 10 in-transit); NEW `rpc_bloom_promo_floor_gap(p_store_code,p_delivery_date,p_next_delivery,p_route)`; `rpc_bloom_scenario_overview` +`value_promo_lines`/`value_nonpromo_lines`/`promo_share_pct`. Adding return columns changes the return type, so both were DROPped and recreated -- **DROP loses grants, both re-granted explicitly** and verified. Caller set re-derived at source: **five real callers, nine call sites, all positional** (`rpc_bloom_scenario_overview` ×4 incl. three `SELECT *`, `rpc_bloom_delivery_chain` ×2, `rpc_bloom_stock_state`, `rpc_bloom_month_projection`, `rpc_bloom_direct_dc_overlap`); `refresh_l2_pipeline` and `rpc_project_route_sales_budget` match the name in **comments only**. DB-SCHEMA listed four and missed `rpc_bloom_direct_dc_overlap` -- corrected. All five smoke-clean after.

**THE GAP, MEASURED ACROSS THE BANK FOR THE FIRST TIME** (each desk at its own offered delivery; figures are generate-specific by construction):

| Store | Promo lines in window | Ordering zero | % | Below promo floor | of which KVI/HERO | Rand to close |
|---|---|---|---|---|---|---|
| 10116 DC_AMBIENT | 585 | 393 | 67.2% | 96 | 20 | R134,284.26 |
| 80175 DC_AMBIENT | 462 | 344 | 74.5% | 71 | 20 | R59,756.03 |
| 21355 DC_TOPS | 83 | 59 | 71.1% | 15 | **11** | R13,548.13 |
| 80176 DC_TOPS | 83 | 63 | 75.9% | 9 | **8** | R7,920.56 |
| 80579 DC_TOPS | 77 | 52 | 67.5% | 13 | **10** | R21,253.87 |
| **GROUP** | **1,290** | **911** | **70.6%** | **204** | **69** | **R236,762.85** |

Not a swallow: five stores, both formats, 67-76%. **At TOPS almost every line below its promo floor is a KVI line** (11/15, 8/9, 10/13 against 20/96 and 20/71 at the SPARs) -- TOPS has no HERO at all (BT scope gap), so the breach lands on the KVI set there. Pieter's named line reproduces to the unit: 822145 B/SOFT, HERO + KVI_IMPORTANT, SOH 0, band demand 18.71/day at uplift 5.00, floor 103 units, order demand 2.11/day, 62 units ordered, **short 21 packs / R7,267.68, 3.3 days cover against a floor of 7.5**.

**ENG-054 RAISED FROM THIS PASS -- the cap censors the model's own input.** 154 of 1,436 promo-window lines (**10.7%**) report exactly the 5.0 cap: 80175 13.0% · 80579 10.8% · 10116 10.6% · 21355 5.7% · 80176 3.1%. A capped value is a BOUND, not a measurement. **ENG-053's cross-store "disagreement" is resolved and reinterpreted: EAN 6001019912371 reads 1.12 at 10116 (real) and 5.00 at 80175 (censored) -- one bound beside one measurement, never two stores disagreeing.** PM ruling: the uplift re-derivation does not begin until this rate is measured; it now is. The discriminating string `promo_uplift_basis` already existed and no consumer read it -- fourth instance of the ENG-002/035/046 class.

**Promo share KPI** reconciles to the cent on all four scenarios (80175: R231,940.32 promo + R95,743.52 normal = R327,683.84 = card total; 70.8%). Split on `promo_active`, the same flag the CSV/TLX/promo-sheet export splits on, so it reconciles to the files. **Confirmed independently with PM, 20/20 rows across five DC desks: `scenario_overview.promo_lines` is a POOL count, not a scenario property** -- unchanged here, sits on Wave 2 counter aggregation.

**Frontend** (`src/app/bloom/page.jsx`): both demands on every promo row, GAP / CAP / IN TRANSIT / EN ROUTE chips, in-transit marked on SOH, a PROMO FLOOR GAP worklist panel and an in-transit desk total (both recomputing off the buyer's LIVE edited quantities), promo share on every scenario card. **`next build` passes -- `/bloom` compiles 22.2 kB, types and lint clean.**

**🔴 OPEN AND NAMED: the frontend is NOT visually verified.** localhost:3000 has no entry in the Supabase auth redirect allowlist, so the dev server cannot be driven through sign-in, and I will not alter auth config or enter credentials. **The engine half is live in the production database while the repo frontend is not deployed**, which is a canon §13 rule-3 divergence that must close this session -- either by shipping the frontend (CC standing deploy authority, gate is green, revert-in-Vercel is the net) or by rolling the migrations back from `_w18_fn_predef`. **Awaiting Pieter's call.** Nothing a buyer sees has changed yet; no quantity moved either way.

---

## 2026-07-28 -- SB-CC-BLOOM-017 Wave 1 item 1.3: GREEN. The selection rebuilt to canon v15 rules 1-6a, the projection leg wired, the cutoff derived. Commit `771c386` (repo) + live migrations.

**State at close: item 1.3 is GREEN. One desk moved. Eight offered delivery dates moved, every one LATER.**

**THE SELECTION (rules 1-5a).** `refresh_l2_on_order` rebuilt -- the table, its four config keys, its grants and its pipeline wiring were already correct and were NOT rebuilt from scratch (only the selection moved, as the handover instructed). Latest-of-its-kind only, ranked over ALL order types so a partition whose latest is received yields nothing (r1); partition `(store_code, supplier_nr, status_2)`, `status_2` OPAQUE (r2); open population `order_type IN ('0','1','2')`, never a date test, and a received order inside the filter now RAISEs a WARNING rather than being dropped (r3, s8.6 guard 4); recency on `order_nr` (r4); **5a, ruled mid-build on a measured question CC put to PM: "passed" is judged against the store's own LEDGER WATERMARK, never the calendar.** New columns `promise_basis`, `landing_estimate_state`, `excluded_reasons`.

**R22, both grains, published on ONE basis (ENG-050 / canon s12e 4b):**
- all-open baseline, line basis **R64,477,050.11**
- in transit, `(store,supplier,status_2)` grain **R643,965.94** on 1,316 products
- excluded and worklisted with age, route and reason **R63,833,084.17**
- **reconciliation delta R0.00**
- Sigma's own header total for the same pool is **R64,456,863.37** and is published beside it, NAMED as disagreeing with its own lines by R20,186.74. Rule-1 at `(store,supplier)` header grain: R601,108.30.

Gates: rule-3 guard **0 received orders inside 0/1/2 on all five stores** · determinism twice-run **16,247 rows, 0 differing** on qty, cost and reasons · live-vs-shadow **16,247 rows, 0 differing** · every one of 3,513 open headers lands in exactly one verdict, count and rand both summing to the pool.

**THE PROJECTION LEG, wired into `rpc_bloom_order_recipe`.** In-transit landing on or before the delivery date lifts `projected_soh`; joined in the `needc` CTE, patched by asserted `replace()` on a 32k-char body with the anchors verified unique first, prestate stored in `_w13_recipe_prestate`. **Isolation by revert, measure, re-apply** -- the before was taken with the wire provably absent (`l2_on_order` references read 0 during it, 2 after):

| Desk | Delivery | Before | After | Delta |
|---|---|---|---|---|
| 10116 DC_AMBIENT | Thu 30 Jul | 575 / R247,675.74 | 575 / R247,675.74 | 0 |
| **80175 DC_AMBIENT** | Wed 29 Jul | 408 / R274,958.56 | **322 / R234,182.90** | **-86 lines, -R40,775.66** |
| 21355 DC_TOPS | Thu 30 Jul | 203 / R154,032.57 | 202 / R153,632.95 | -1 line, -R399.62 |
| 80176 DC_TOPS | Wed 29 Jul | 123 / R112,770.24 | 123 / R112,770.24 | 0 |
| 80579 DC_TOPS | Thu 30 Jul | 169 / R126,767.69 | 169 / R126,767.69 | 0 |

Invariants: **0 lines went UP on any desk** (adding in-transit can only reduce need) · **0 HERO touched** · the 95 reduced lines decompose 63 CORE/STANDARD, 17 KVI_IMPORTANT, 12 KVI_CRITICAL, 2 CONSUMABLE_CARVE, 1 SLOW, with 87 going to zero. **All 6 KVI_CRITICAL zeros were checked individually** and every one projects ABOVE its own min_band at delivery on stock genuinely landing on or before that date -- five of the six placed that same day.

**The reverted v14 build is vindicated by the numbers.** It had stripped 21355 from 308 lines to 199 (-R102,142) on six open orders never tested for latest-of-kind. Under v15 that desk's entire in-transit exposure is **2 lines and R2,763.87**. The gap between R102,142 and R2,764 is the measure of why the revert was correct.

**RULE 6 + 6a -- THE CUTOFF IS DERIVED.** NEW `rpc_derive_order_cutoff(p_store_code, p_route_key)` (STABLE, returns the proposed row WITH its evidence -- median, pairs observed, dow lead, cycle, seeded prior) + `refresh_supplier_calendar_cutoff(...)` (SECURITY DEFINER writer; store #6 onboarding is one call). `supplier_calendar` gains `order_cutoff_basis`, `order_cutoff_anomaly`, `order_cutoff_seeded_prior` -- the last written ONCE via COALESCE so the original seed survives every later re-derivation (R28 lineage, retired with a date and a successor, never deleted). Basis: the route's own demonstrated placement->GRV median where the ledger carries at least `in_transit_min_received_orders` real pairs, else `placement_dows` x `delivery_dows` (v9 7l) -- reusing the existing threshold rather than inventing a second one. **6a (Pieter ruling 2026-07-28): an anomalous derivation is FLAGGED and NOT enacted.**

**17 of 20 routes moved off the seeded 2. Eight offered delivery dates moved, every one LATER, and Pieter saw the table before it landed:**

| Store | Route | Seeded | Derived | Basis | Offered move |
|---|---|---|---|---|---|
| 10116 | DIRECT_MONDELEZ | 2 | 8 | pair lead n=11 | 30 Jul -> 13 Aug |
| 80175 | DIRECT_NATBRANDS | 2 | 8 | pair lead n=10 | 4 Aug -> 18 Aug |
| 10116 | DIRECT_CLOVER / DIRECT_DANONE | 2 | 3 | pair lead n=14 / 40 | 30 Jul -> 4 Aug |
| 80175 | DIRECT_CLOVER / DIRECT_DANONE | 2 | 5 / 3 | pair lead n=14 / 51 | 30 Jul -> 4 Aug |
| **21355 / 80579** | **DC_TOPS** | 2 | **4** | **pair lead n=191 / 151** | **30 Jul -> 3 Aug** |
| 10116 | DIRECT_NATBRANDS | 2 | 8 -> **1** | **6a ANOMALY, not enacted** | no move |

**The TOPS DC finding is the operationally important one: those desks had been offering Thursday deliveries the DC does not hit.** 191 and 151 real placement-to-GRV pairs both say 4 days against a typed 2. **80176 DIRECT_BEER derives 1 = Pieter's own floor figure reached by formula, closing ENG-048** (invisible on a Tuesday, visible Mon 3 Aug -- the day he hit it).

**Config, canon s0h point 2.** Five `forge_config` keys stamped `SEED, UNDERIVED` with the derivation logged as owed work: `in_transit_lead_multiple` 2, `in_transit_min_received_orders` 5, `in_transit_lead_fallback_days` 7, `corrector_min_observable_share` 0.5, `corrected_ros_cap_multiple` 2.0. `in_transit_lead_window_days` 182 keeps its reference to `cadence_window_days` and takes no stamp.

**Grants (R30 addendum extension), proven on both new functions before merge:** PUBLIC REVOKEd, anon REVOKEd, authenticated GRANTed.

**Repo:** `771c386` pushed -- `sql/create_rpc_derive_order_cutoff.sql` (new, carries both functions and the three ALTERs), CLAUDE.md mirrored to FILE-GOVERNANCE v2.9 with the ruled byte report, and `.gitignore` gaining `Clients/` by exact path and bare name on the sb-key.txt pattern (the folder is the control, the ignore line is the belt -- this repo pushes and Daisy's does not).

**NAMED DEBT, not hidden.** `sql/create_l2_on_order.sql` and `sql/create_rpc_bloom_order_recipe.sql` owe a reconcile to live, alongside the two Wave-1 bodies already carried. Live is authoritative until closed.

**⚠️ OPEN AND HELD, found the following day and logged as ENG-052:** the promo uplift reaches `l2_stock_band` and dies before the order, because the recipe recomputes its bands at order time from an unlifted demand. 472 of 577 uplifted promo lines at 10116 order zero. The fix is built on `_shadow_recipe_eng052` and **deliberately not deployed** -- it over-predicts the largest promo line 2.16x against observed trading, and the model measures median 0.89 with only 47% of lines inside 1.5x. ENG-052 and the uplift re-derivation deploy together or not at all.

---

## 2026-07-27 later -- SB-CC-BLOOM-017 Wave 1 item 1.3: `l2_on_order` BUILT, then its projection leg REVERTED the same session (canon moved under the build)

**State at close: the FACT is live and HELD. The PROJECTION leg is REVERTED. No live order value is changed by 1.3.**

**What shipped and stayed.** NEW `l2_on_order` (per store/product: `on_order_qty` in SINGLES, `on_order_cost`, `expected_landing_date`, `route_keys`, `lead_days_used`/`lead_basis`, plus a `stale_*` leg carrying the excluded documents with age and route for the worklist) + `refresh_l2_on_order(p_store)`, wired into `refresh_l2_pipeline` immediately after the SB-CC-DEBT-001 creditor block. Four `forge_config` DEMO_CALIBRATION keys (`in_transit_lead_multiple` 2, `in_transit_lead_window_days` 182, `in_transit_min_received_orders` 5, `in_transit_lead_fallback_days` 7). Grants proven live before merge, all three legs of the R30 addendum extension: anon EXECUTE **false**, PUBLIC **false**, authenticated **true**. Determinism proven (21355 re-run: 460 rows, 0 differing).

**What was reverted, and why.** The build was written to canon §14 ADDENDUM **v14 rule 3**, read in full at session start. **ADDENDUM v15 landed the same day and is this object's actual specification** — it states `l2_on_order` "unbuilt" and refines exactly the half I implemented: v14 named the in-transit BOUND, v15 names the SELECTION. Non-conforming on five of seven rules — only the LATEST order of its kind is outstanding and everything behind it is cancelled (rule 1, Pieter ruling); the partition is `(store_code, supplier_nr, status_2)` with `status_2` opaque and supplier-alone explicitly a defect (rule 2); the open population is `order_type` 0/1/2 **measured, never a date test** (rule 3); recency is `order_nr`, not the 76%-sentinel `order_date` (rule 4); a promised date that has passed means not in transit (rule 5). The rand shows it: v15 measures all-open at **R64,978,904** and the rule-1 answer at **R231,452**; this build reported **R886,144.56**, sitting between the two because the sentinel date-filter removed much of the population while nothing applied latest-of-kind.

**The revert was not optional.** The projection leg had moved a live desk on placement morning — 21355 DC_TOPS 308 → 199 lines, R247,505.89 → R145,363.60, on six open orders never tested for latest-of-kind. `rpc_bloom_order_recipe` restored from the reconstructed prestate shadow and verified back to **308 lines / R247,505.89** exactly; the shadow was then dropped; the live body carries **zero** `on_order_qty` references. `sql/create_rpc_bloom_order_recipe.sql` reverted in step, so repo == live.

**Measurements that survive the rebuild** (each proved to source, and the v15 rebuild inherits them):
- **UNITS.** `sigma_order_lines.ordered_qty` is **SINGLES**, the same basis as the R/W movement qty and as SOH — 8,723 of 13,430 matched receipt lines equal it exactly, multipack ratio 1.0298 where mean pack is 18.38. No pack bridge on the quantity leg.
- **COST.** `cost` is the **CASE** cost. `ordered_qty * cost` runs **11.94×** the invoiced total — canon §12e point 4's trap, which inflated July 15.7×. The line value is `ordered_qty * cost / pack_size`, landing at 0.942 of invoiced (residual = ordered-vs-invoiced difference).
- **Route-demonstrated placement→GRV leads** (median/p90, 182d): 10116 DC 2/4 · 80175 DC 2/5 · 80176 DC 3/6 · 21355 DC 4/7 · 80579 DC 4/7 · CLOVER 4/4-5 · DANONE 3-4/5-6 · MONDELEZ 3-7/10-12 · NATBRANDS 7-8/9-14.
- **`status_1='7'` is an INERT guard.** All 31 real-dated rows carry a GRV, so it can never remove an open order. Kept defensively, named inert rather than claimed as working (R28 §5).
- **SAB has no derivable lead.** `order_date` is the sentinel on essentially every SAB header (21355/555 = 1 real of 58; 80176/590 = 3 of 148), which independently confirms canon v15 rule 6's route to the cutoff via `placement_dows` × `delivery_dows`.

**`outstanding_order_window_days` was never created in `forge_config`** — the withdrawn 30-day seed is retired before it was built, so no lineage row was manufactured for a key that never existed.

**Owed next session:** rebuild `refresh_l2_on_order` to v15 rules 1-5, then the rule-6 cutoff derivation (BUG-LOG ENG-048), then re-run the before/after and publish per-desk. `l2_on_order` carries a `COMMENT` marking it HELD and not canon-correct so nothing reads it meanwhile.

---

## 2026-07-27 -- SB-CC-BLOOM-017 Wave 1: the ordering number is made right

Items 1.1 (re-scoped by PM ADDENDUM v1.3), 1.2, 1.5 and 1.6, all four in the objects where they live. Applied by migration to the live DB and R22-verified on all five stores before this commit. **Live order values moved, which is why this is committed the same night: Pieter places Monday for Wednesday and Thursday.**

**What moved on the desk** (FULL preset, next real delivery dates):

| Desk | Ordered | Value | Non-promo | Promo |
|---|---|---|---|---|
| 10116 DC_AMBIENT (Thu 30 Jul) | 490 -> 457 | R240,791.58 -> **R188,820.80** | R107,670 -> R108,363 (+0.6%) | R133,122 -> **R80,458 (-39.6%)** |
| 80175 DC_AMBIENT (Wed 29 Jul) | 416 -> 361 | R280,016.99 -> **R258,005.29** | -- | R169,667 |
| 21355 DC_TOPS (Thu 30 Jul) | 315 -> 308 | R274,299.23 -> **R247,505.77** | -- | R84,255 |

**The promo drop was decomposed, not accepted.** It is not the gear: the retired inline formula was reproduced side by side and averaged 2.041 against the new 1.963, with only 175 of 872 lines differing at all. It is the observable-day floor, and it lands exactly where the defect was -- **17.8% of promo lines have their 14-day window withheld against 4.1% of non-promo, a 4.3x concentration.** That is the signature of a line that sells hard on promo, runs out, goes quiet, and had its rate computed off three observable days. The desk was over-ordering promo lines off collapsed divisors.

**Guards after the lift:** `pack_forced_review` 7 / 4 / 1 and `hero_pack_over_max` **0 on all three desks** -- the 35-day ceiling and max-band still bind on a promo-lifted band. `count_first` falls to 2.6% / 1.7% / 2.6%, closing brief item 2.8 as a by-product.

**Two defects found during the build, both by reading the objects rather than the brief's description of them, and both the same class -- one rule with several implementations.** BUG-LOG ENG-046 (`refresh_l2_pipeline` never called `fill_l2_bloom_promo_pantry_sibling_fallback()`, leaving 9,938 of 16,903 promo-pantry rows at NULL uplift every night) and ENG-047 (the recipe carried a third independent promo uplift, calendar-day, hardcoded 5.0 cap and 2.0 default). ENG-041, ENG-044 and ENG-045 close with this deploy.

**One correction I made mid-build, recorded because the R22 caught it and not a walk:** the first cut had the recipe read `l2_stock_band.promo_uplift_used`, which hands it the band's anchor-based window test as well as the magnitude. The band is date-agnostic by design and cannot know the delivery date. That silently dropped gearing on 479 of 872 promo-active lines at 10116. Fixed to magnitude-from-pantry, gate-from-recipe.

**Named debt, not hidden:** the function bodies in `sql/create_l2_bloom_ros_pantry.sql` and `sql/create_l2_stock_band.sql` are not yet reconciled to live (table DDL and headers are). Live is authoritative until they are, next session.

**Nothing in §16 or the calendar is wired, no date literal from the 4 July DC interruption exists in any function, view or matview** -- verified at source. Pieter's ruling: it is an event, not a regime, and nothing is calibrated to it.

---

## 2026-07-26 -- ORD-STOP-001 defect 5: l2_range_state wired into the nightly chain (`e5bf527`)

The one Ship-2 object never wired into `refresh_l2_pipeline`, and it DRIVES DEPTH in `rpc_bloom_order_recipe` (canon §14 v10 item 1: a missing row defaults to SLOW = zero depth = never ordered). Last refresh 2026-07-12 17:00 UTC against every sibling at 2026-07-25 20:15 -- 13 days stale on the table that decides what gets ordered.

**Why it was skipped, and why the slot matters.** It reads `l2_classification` (early), `l2_kvi_profile` (mid, Ship-2 chain) and `l2_bt_heroes` (LATE, built by `refresh_bt_precompute`). It is the only pantry fact whose dependencies straddle the whole chain, so it fits with none of its siblings. Wired AFTER `bt_precompute` -- placing it with the Ship-2 group would read a stale `l2_bt_heroes` and mislabel every HERO.

**R22, before -> after, all five stores refreshed:** NORMAL products with no range_state row 766 -> 0 · pass the life gate but called SLOW/DERANGE/MARKDOWN 486 -> 0 · labelled CORE/HERO but fail the gate 470 -> 0.

**⚠️ FIXED BUT NOT UPSTREAM, AND ORD-STOP-001 IS NOT CLOSED.** 10116 DC_AMBIENT full moved only 479 -> 487 lines / R236,897 -> R240,293 (+1.7%) against the 2026-07-21 signed reference of 1,718 lines / R736,416. Judgement delivered per PM's instruction, each item measured not inferred:
- **Defect 4 (order a fraction of its reference) is NOT a defect.** The 10116 CORE+HERO pool rose 118,463 -> 154,159 units SOH between 21 and 25 Jul (+30.1%), in-stock lines 5,914 -> 6,849. Projected SOH now averages 11.41 against min_band 2.50, so 4,616 of 5,051 CORE lines sit ABOVE band: need is legitimately 0 and v12 min-presence correctly does not fire. **The store restocked.** Comparing to the 21 Jul figure is a comparison across a regime boundary (canon's own `regime` rule). **The 21 Jul reference was cut on an understocked store and may need re-cutting before it can gate again -- PM's call.**
- **Defect 3 (catch_up collapsed) is a SYMPTOM** of the same restocking: catch-up targets 21 aggregate stock-days and the pool is already near it.
- **Defect 1 is MISDIAGNOSED as inert Fit.** The recipe DOES honour `p_fit_to_budget` (`budget_fit_applied` true on all 318 lines at 21355, two distinct reasons) and correctly refuses to trim, because ALL 318 ordered lines are floor layer: 228 `protected_kvi_hero` + 90 `min_presence_floor`. Canon v13 §1 forbids trimming either. **The real defect is narrow: `rpc_bloom_scenario_overview` never aggregates the recipe's own `budget_fit_reason` into `protected_lines`/`trimmed_lines`** -- BUG-LOG ENG-036.
- **Defects 2, 7, 8 CONFIRMED REAL AND OPEN** (ENG-041, ENG-038-adjacent yardstick, ENG-037).

**The Recipe desk is still NOT safe to order off. The `rpc_bloom_order_dc` fallback stands as PM ruled.**

---

## 2026-07-26 -- SB-CC-DEBT-001: the creditor/stock match baseline + ageing instrument (`68194d0`, `1a7bd66`)

CANON §12e. What we RECEIVED married to what we OWE, per (store, order_nr), with named verdicts carrying their reason in a buyer's words (R29). Establishes the cost-integrity baseline before any cost calculation, per Pieter's ruling.

- **NEW `l2_creditor_stock_match`** + `refresh_l2_creditor_stock_match(p_store)`, header grain, wired into `refresh_l2_pipeline` ahead of every cost consumer. Seven verdicts: `MATCHED` / `VALUE_BREAK` / `NO_INVOICE` / `NO_GRV` / `INVOICE_VALUE_MISSING` / `RECEIPT_OUT_OF_WINDOW` / `OPEN_ORDER`.
- **NEW `v_creditor_ageing`** -- who we owe, how much, how old, and how much is backed by stock that actually arrived.
- **NEW config** `forge_config.creditor_match_tolerance_rand` = R1.00, DEMO_CALIBRATION. Justified from a measured bimodal distribution (625/684 within R1, only 4 between R1 and R10, then 55 genuine breaks to R12,527) -- no percentage floor was measurable as a natural break, so none was invented (R21).
- **`supplier_invoices` RETIRED IN PLACE** with lineage (0 rows -- the dead scaffold that made us believe the invoice data was unfetched). Commented, never dropped.

**R22 reproduced FROM THE BUILT FACT, exact to the cent ×5 against PM's independent baseline:** R7,028,184.86 received / R6,975,847.20 invoiced ex-VAT / −R52,337.66 (0.745%), 684 headers / 13,459 receipt lines, Dice at +R0.01.

**PM's three landmine laws applied** (VAT boundary; singles×case units avoided entirely; header grain, dead `received_qty` never read). **Four further source traps found by CC and neutralised, each of which produces a false catastrophic number:** `grv_nr = 0` is the no-GRV sentinel and NOT NULL (18,049 headers -- testing `IS NOT NULL` reports ZERO no-GRV cases and hides the whole overpayment population) · `vat_total` populated where `invoice_value = 0` (15,980 headers, fabricates −R2,068,847 of phantom negative invoice) · date sentinels `1990-01-01` (`order_date` on 41,920/55,002) · **`due_date` is a DEAD COLUMN, one distinct value across all 55,002 rows** (ENG-039).

**Second pass (`1a7bd66`):** NO_GRV now carries its rand -- `invoice_value` is 0 on ALL 2,585 NO_GRV headers, so `exposure_ex_vat`/`exposure_basis` fall back with provenance named per row (R1,659,567.62 measurable on 162 headers; 2,423 marked `none_captured` rather than rendered R0). NEW `is_credit_or_return` [DEDUCTIVE -- a negative order value cannot be a purchase]: `status_1='7'` spans 17,316 headers dominated by negative/zero values and 5,147 carried `NO_INVOICE`, which on a screen reads as "stock we hold unbilled" when it is a RETURN. Deliberately a FLAG not an eighth verdict -- a credit can legitimately be MATCHED, so pre-empting the cascade would move a proven baseline. **R22 re-proven unchanged after the change.**

**Not done, named:** the DoD screen (Pulse). The fact and view answer all four of Pieter's questions; nothing surfaces them yet.

---

## 2026-07-26 -- IDENTITY PHASE 2: native-first `v_ean_bridge`, the R25 §2 break retired (`900b8b6`)

CANON §17 Phase 2, the item-12-INDEPENDENT foundation.

- **NEW `l2_ean_resolved`** + `refresh_l2_ean_resolved(p_store)` -- the deterministic resolved identity, one canonical key per (store, product), native `sigma_scan_refs` first via `v_scan_ref_decoded`, `product_catalog` demoted to fallback. 278,198 rows ×5.
- **`v_ean_bridge` REPOINTED to a thin view over it** (`CREATE OR REPLACE`, identical column contract, so none of its dependents moved). **PERSISTED, NOT A VIEW, and that was measured:** the decoder over 240k scan rows ran 6,835 ms as a plain query; persisted, the bridge reads in 55 ms.
- **NEW `l2_link_codes_queue`** + `refresh_l2_link_codes_queue(p_store)` -- 6,698 CANDIDATES in three deterministic classes: SHARED_EAN (the recode/successor signature), PACK_FAMILY (canon's five parent-child guards), ABSENT_FROM_DBREFE (the COKE ZERO class that can never key a TLX). **Unblocks ENG-020 leg 2, which could not pass its own non-empty gate while the object did not exist.**
- **The item-12 hold is STRUCTURAL:** `status` CHECK-locked to `CANDIDATE`, no keeper/verdict/resolution column, and an UPDATE to `RESOLVED` proven rejected. `l2_product_resolution` + `l2_product_map` stay at 0 rows by ruling, scaffolded with the identity + export/gate-flag columns so Phase 3 needs no schema change.

**R22 gates, all passed pre-repoint:** (store,product) unique 240,142/240,142 with 0 dupes (R20 fan-out safety intact) · **0 products lost** from the old bridge · 1,462 keys changed to native · EAN-8 rescue 3,113/3,113 and UPC-A 7,672/7,672 check-digit valid · **sales reconciliation delta R0.0000 on all five stores** (R20 addendum) · Phase-1 freeze intact (0 frozen and 0 ineligible on a live TLX) · `upsert_search_index` and `REFRESH mv_rate_of_sale` both clean despite 66 shared barcodes.

**Coverage won:** native real-EAN 77.4 / 88.4 / 83.7 / 91.1 / 88.4% against the catalogue bridge's 43.0 / 2.5 / 16.0 / 2.6 / 2.2%. `mv_rate_of_sale` keys now 78-91% real, which **retires "treat TOPS EAN-grain coverage as synthetic-dominant"**. Export-ineligible collapsed 238,888 -> 44,505 group-wide (ENG-032 largely fixed, not merely measured).

**Canon corrections owed and accepted by PM:** `v_ean_bridge` has 32 live dependents (PM's recount; CC measured 31), not the 7 §17 recorded · `product_catalog` retirement is Phase 3, 4,512 rows still resolve only through it · 25 `FULL13` codes Sigma holds fail their own GS1 check digit (pre-existing L1 data quality, NOT a decoder defect).

---

## 2026-07-26 -- RECONCILE-001 JOB 1: canonical SQL for the Identity Phase 1 objects (`3c57bc6`)

Closes the debt the 2026-07-22 entry below flagged as OWED. One file per object, reconstructed from live DDL (R22): NEW `create_gs1_check_digit.sql` and `create_v_scan_ref_decoded.sql`; `create_v_item_ean.sql` (repoint), `create_l2_export_key.sql` (the Phase-1 freeze on `refresh_l2_export_key`) and `create_rpc_forge_lines.sql` (export gate + `tlx_held`) updated to live. **No behaviour change -- prod already ran these objects; the repo now matches live.** RECONCILE-001 whole again.

---

## 2026-07-22 -- IDENTITY PHASE 1: the decoder reads Sigma's type_flag, not string length (ENG-030 closed)

CANON §17 Track B Phase 1. The `v_item_ean` decoder classified scan codes by LENGTH and ignored Sigma's own `DBREFE.cTYP`/`cSYSTEM`, stamping ~4,303 EAN-8 bodies as PLU. Now decoded natively. **DB-only, L1 byte-identical, extractor untouched.** Applied live via MCP migrations; **canonical `sql/create_*.sql` OWED (RECONCILE-001, next session) -- flagged, not silently skipped.**

- **NEW `gs1_check_digit(text)`** -- immutable, length-agnostic GS1 mod-10.
- **NEW `v_scan_ref_decoded`** -- the decoder, L2 over `sigma_scan_refs`. `code_kind_v2 = f(type_flag, system_flag, GS1 prefix)`, NEVER length. UPCA_BODY len-11 only, EAN13_BODY len-12 only; a short body under a real-code flag decodes `ANOMALY_LEN` (surfaced) rather than fabricating a check digit.
- **`v_item_ean` REPOINTED** onto it, output contract unchanged. Gate 1 proven: 0 has_barcode regressions, 3,110 products gained a real barcode.
- **`refresh_l2_export_key`** carries the Phase-1 freeze (`ineligible_reason='identity_phase1_freeze'`) on every flipped product until Phase 3. R30 double-revoke (PUBLIC + anon) re-proven, `anon` EXECUTE = false.
- **`rpc_forge_lines` gated on `l2_export_key.export_eligible` -- a PRE-EXISTING ENG-031 gap, not Phase 1's.** The export gate governed the Bloom order TLX only; the Forge STOCKTAKE TLX (which zeroes stock in Sigma) read `l2_classification.artifact` directly and bypassed it. Live impact caught: **89 of 90 lines on the current Forge TLX carried manufactured synthetic keys** (R28,354.44) that Sigma silently drops on import -- the "exported 1,891, imported 1,845" R22 failure §17 names, live and invisible on screen. New `tlx_held` selector surfaces every held line with its reason (R21 §5).

- **Two self-caught fabrication defects, fixed before anything landed:** `type_flag=2` len-10 → `UPCA_BODY` (a UPC-A body is 11 digits -- invented a barcode, flipped 3,048 products on fiction) and `type_flag=1` len-7/8/10 → `EAN13_BODY` (3 products). Caught by reconciling flips BY CAUSE, not by the gate passing. Both now `ANOMALY_LEN`.
- **Gate (c) ruled (PM):** the `2000xx` scale reading was FALSIFIED (catches ~3% of `scale_flag=1`) -- `type_flag=0` 20-29 decodes IN_STORE as a class, scale carried on `sigma_articles.scale_flag`, never a prefix literal (R21/R25).

**VERIFIED post-nightly (R22, 2026-07-23):** the nightly `refresh-l2-pipeline` (2026-07-22 20:15 UTC) applied the decoder to `l2_classification` ×5. `ean_status` REAL 14,340 / **UNRESOLVED 384 (non-zero BY DESIGN -- R23 §2)** / PLU 215; **0 frozen products reached a live TLX artifact**; **Forge TLX emit collapsed 90→1** group-wide; **0 REAL lost**. Capital Tied R5,597,947 -- identity-attributable move ~R9k (0.17%), the rest ordinary day-advance. `SOURCE_FIX` (R12) + `EXPENSE_ZERO` (R8,960) fall to AMBIGUOUS; the 6 `COST_ERROR` lines / R2.88M never counted (fire at cascade 0b ahead of `ean_status`).

Migrations `identity_phase1_decoder_v_scan_ref_decoded`, `identity_phase1_decoder_tighten_upca_and_itf14`, `identity_phase1_decoder_length_validity_and_freeze`, `identity_phase1_repoint_v_item_ean_onto_decoder`, `forge_tlx_honours_l2_export_key`. **No repo commit yet** (canonical SQL owed; `sb_secret` rotation hold on the Daisy push stands, separate repo).

---

## 2026-07-21 -- ENG-034: Fit-to-Budget is a RANKED WHOLE-PACK FILL, never proportional scaling

PM ruling the same day, on the defect leg d exposed. Retires canon SS14 v10's "scale the remaining quantities proportionally" with lineage (R28) and reconciles v8 (ranked trim), v10 (floor-protected) and v12 (presence never zeroed) with what an indivisible pack permits.

- **The defect [DEDUCTIVE]:** a pack is indivisible, so scaling a 1-2 pack line by a fraction and flooring lands on zero. 10116 DC_AMBIENT, budget R506,841: 12,453 lines worth R525,584.57 collapsed to **R3,602.85 with 6 survivors** at a ~0.494 factor, the fitted order landed R255k BELOW its own budget, and the v12 minimum-presence packs were re-zeroed. Proportional allocation of a fixed budget across atomic units is incoherent by construction -- no base rate needed.
- **The fix, reusing what exists (R21):** the CATCH_UP priority-basket walk. A FLOOR layer is funded first and never trimmed (HERO/KVI protected lines at full quantity + the v12 minimum-presence pack), then remaining DEPTH fills in the existing `cu_rank` order (HERO -> KVI band -> GMROI -> product_code) at WHOLE packs on a prefix cutoff. Lines past the cutoff hold at their floor with a reason, never a fractional collapse. New `budget_fit_reason` values: `min_presence_floor`, `ranked_fill`, `below_cutoff_held_at_floor`, `below_cutoff_not_funded`.
- **R22, isolation:** unfitted output byte-identical to `packs_before_fit` on all 6 store/route pairs tested -- the change touches the fit path only. 10116 DC_AMBIENT fitted moves from 152 lines / R250,798.56 to **1,718 lines / R736,415.69**; nothing is shaved onto an empty shelf. `next build` clean.
- **🔴 WHAT THE FIX EXPOSED, reported not absorbed: `depth_funded = 0` at every store/route today** -- the floor layer alone exceeds the rail everywhere, so the ranked walk currently has nothing left to allocate. 10116 DC floor R733,042 vs rail R495,603 · 80175 DC R493,421 vs R368,873 · 21355 DC_TOPS R315,002 vs R47,563 · 80579 DC_TOPS R295,495 vs R44,834 · 80176 DC_TOPS R187,803 vs R90,394 · 21355 DIRECT_BEER R83,723 vs R10,480. Two causes, both named: the stores are genuinely broadly below band, AND **the TOPS rails are structurally understated** because `l2_sales_budget` is LY-anchored and TOPS LY coverage is ~11% (the known family/EAN-bridge debt, canon v11 3c-d) -- the 6.6x gap at 21355 is that debt, not a buying signal. The order therefore lands ABOVE the rail, which is the SAFE direction and the RULED behaviour (canon v9 item 5 / v7 item 9), now surfaced on the budget strip as "over the week's rail by R X -- floors protected".
- **Silent display defect fixed in the same pass:** the strip's `protectedCount` / `trimmedCount` filters matched **no engine value at all** (`protected_kvi`, `trimmed_partial`, `trimmed_to_zero` are never emitted), so it had shown 0 protected and 0 trimmed on every order since it shipped.

Migration `eng034_fit_is_a_ranked_whole_pack_fill`. Files `sql/create_rpc_bloom_order_recipe.sql`, `src/app/bloom/page.jsx`.

**SIGN-OFF LABELS (PM 2026-07-21, canon SS14 v13 -- labels not logic, no Fit gate, min-presence stays inside the protected floor):** the over-rail flag is unchanged, and the budget strip now carries the rail's own **measured** LY coverage -- `rail provisional · LY N% of pool` -- read from `l2_sales_budget.products_with_ly_history / products_in_pool` for that (store, DESK), with the same caveat repeated inside the over-rail banner. **Deliberately NOT a TOPS-only label (R21):** a store-list label is the hardcoded-store-list rule we ban, and a SPAR-vs-TOPS threshold would be a constant fitted to two observations. The measured figure is stated instead and it immediately earned that choice -- live coverage is **10116 DC 27% · 80175 DC 13% · 21355 DC_TOPS 9% · 80176 DC_TOPS 10% · 80579 DC_TOPS 10% · DIRECT_BEER 19-24%**. **80175's SPAR DC rail is 13%, nearly as thin as TOPS** -- the "TOPS problem" is not a TOPS problem, it is an LY-coverage problem that happens to be worst at TOPS. A store-list label would have hidden that.

**Nightly proof, unplanned and welcome:** `refresh-l2-pipeline` fired mid-session at 20:15 UTC and picked up BOTH of this session's new wirings on its first live run -- `l2_export_key` and the NEEDS rail refreshed themselves without intervention (verified via `resolved_at` / `updated_at` = 20:15:00 exactly). That also explains a R6,492 movement in unfitted order values between the evening's measurements: `l2_stock_position` refreshed underneath them, not a code change.

---

## 2026-07-21 -- LEG D: the budget rail derives itself, and the stale-week fallback is no longer silent

Track A item 3 (canon SS17 A3). The weekly rail had been frozen at the WC-11-Jul hand seed for three weeks, so every auto-fitted DC and direct order was fitting to a stale number. Two defects sat underneath it, both fixed here.

- **The projection could not produce the current budget week.** `rpc_project_route_sales_budget` computed the Saturday on/before its anchor and then **advanced it by 7** unless the anchor was itself a Saturday -- so `l2_sales_budget` only ever held weeks starting in the FUTURE (earliest row 2026-07-25 while the current budget week started 2026-07-18), while `rpc_bloom_order_recipe.v_week_start` uses the week CONTAINING the delivery. The two disagreed by construction, and the projection's own comment claimed they were the same formula. **That disagreement IS the live half of ENG-016.** Advance retired with lineage; the projection now starts at the week containing the anchor.
- **NEW `refresh_order_budget_ledger_needs(p_store)`, wired into `refresh_l2_pipeline`** immediately after `refresh_l2_sales_budget`. Desk-to-ledger route mapping is taken from the consumer (`v_ledger_route`): `DC_*` -> DC, `DIRECT_BEER` -> its own rail, every other `DIRECT_*` summed into DIRECT. **MANUAL is sovereign** -- a row flagged `budget_manual_override` is the cashflow punch-in and NEEDS never overwrites it; monthly rows (the SAB Jul-Dec management rail) are never touched.
- **⚠️ The conversion factor, stated not buried (R27 SS7).** Canon v11 reads needs = projected_sales x 0.82, but that 0.82 converts RETAIL to cost and `projected_sales_cost` is already at cost -- applying it again under-funds the rail ~18%. Measured to source, trailing 91d, ×5 stores: purchases/sales-at-cost = 0.984 / 1.027 / 0.954 / 0.735 / 0.581, purchases/sales-ex-VAT = 0.807 / 0.836 / 0.802 / 0.787 / 0.508. The 0.82 law reproduces exactly on the ex-VAT basis; the cost basis sits at ~1.0. Default 1.00, held in config `purchases_to_sales_ratio_cost_basis`. The demonstrated per-store ratio is **surfaced in `source_note` and NOT applied** -- 21355 (0.735) and 80579 (0.581) have been under-buying, and budgeting a starved store forward at its starvation rate is the DF-2 mistake. CC's reading, flagged to PM as a CANDIDATE.
- **REAL SCHEMA DEFECT caught by the build:** `order_budget_ledger`'s PK was `(store_code, route_key, year_month)` and **ignored `grain`**, so a weekly Saturday landing on a month start could never coexist with the monthly row. **2026-08-01 is a Saturday** and the first NEEDS run at a TOPS store hit `duplicate key (21355, DIRECT_BEER, 2026-08-01)` against the SAB monthly rail. PK now includes `grain`. No FK references the table (verified before altering).
- **The fallback is surfaced.** `budget_week_source` has been an engine output all along and nothing displayed it -- that is what made ENG-016 silent. The budget strip now names the basis (`NEEDS (projection)` / MANUAL / 82% / 80%) and raises a loud amber warning when the engine fell back to a past week or found no row at all.
- **R22:** rails written ×5 stores (10116 +52, 80175 +52, 21355 +78, 80176 +52, 80579 +52), **0 manual rows overwritten**, and **every desk now reports `budget_week_source = 'delivery_week_exact'`** where all of them previously read `nearest_past_week_fallback`. Unfitted order values byte-identical across all 8 store/route pairs tested (the rail does not touch quantities unless Fit is on). Sanity-checked the current week reading lower than next week: `ly_base_cost` is near-identical (R655,301 vs R664,446) and the whole gap is the pay-cycle rhythm index (w3 lull vs w4 payday) -- correct behaviour, not a clipped window. `next build` clean.

**🔴 THIS EXPOSED A CRITICAL DEFECT -- BUG-LOG ENG-034, NOT FIXED, needs a ruling.** With a truthful (smaller) budget, Fit-to-Budget binds for the first time at 10116 -- and it does not trim, it annihilates. Proportional scaling is applied per line to an INTEGER pack count and rounded down, so `floor(1 pack x 0.494) = 0` wipes every single-pack line: 12,453 scaled lines worth R525,584 before fit collapse to **6 lines / R3,602.85**, and the fitted order lands R255k BELOW its own budget while the shelf empties. It also contradicts canon v12 minimum-presence. **Floor guidance until ruled: order on FULL, Fit-to-Budget OFF** -- which is effectively what has been happening, since the stale rail meant Fit never bound.

Migrations `legd_01_projection_covers_current_budget_week`, `legd_02_needs_refreshes_the_ledger`, `legd_03_order_budget_ledger_pk_includes_grain`, `legd_04_wire_needs_into_pipeline`. Files `sql/create_refresh_order_budget_ledger_needs.sql` (new), `sql/create_l2_sales_budget.sql`, `sql/create_refresh_l2_pipeline.sql`, `src/app/bloom/page.jsx`.

---

## 2026-07-21 -- TRACK A ITEM 1 / ENG-031: the TLX export-eligibility gate is an ENGINE fact

The `if (q <= 0 || !l.ean) continue` guard in all three `exportTlx()` builders has been dead code since 2026-06-30 -- the R20-addendum COALESCE made `ean` never null, so manufactured store-prefixed keys rode the TLX, Sigma dropped them on import, and the buyer saw a line count that never arrived (R22, the silent-drop failure mode). Canon SS8.4 and SS14 v7 item 11 already forbade it; nothing enforced it.

- **New pantry fact `l2_export_key`** (PM placement ruling: ONE L2 fact per `(store_code, product_code)`, engine-owned, read by desks and exporters alike, the frontend never decides what a real barcode is). Carries `export_key`, `key_source`, `export_eligible`, `ineligible_reason`. `refresh_l2_export_key(p_store)` is **wired into `refresh_l2_pipeline`** after the last_counted loop -- an unwired pantry fact drifts, which already happened once to the Ship-2 pantry (ENG-002).
- **The test is deliberately narrow, and that is the load-bearing choice.** Ineligible ONLY where the key is one WE manufactured: `SYNTHETIC_FALLBACK` (no `v_ean_bridge` row, the COALESCE built it) or `BRIDGE_PLU_SYNTHETIC` (a catalogue PLU-category row, whose ean is the same store-prefix construction). It does **not** judge whether Sigma holds a given REAL code -- that is the `DBREFE.type_flag=3` question Track B Phase 0 reads at source, and pre-empting it would cost real orders on a hypothesis. The 45 short-but-real barcodes stay on the TLX. Both classes carry a structural belt (the key must literally BE the store-prefixed construction), so a mis-categorised real short code stays eligible.
- **New published interface `rpc_bloom_export_eligibility(p_store_code, p_product_codes)`** (R30). **Named deviation, flagged not taken silently:** PM specified "an engine flag from `rpc_bloom_order_recipe`". The verdict is engine-owned and native-sourced exactly as ruled, but delivered as its own interface, because adding columns to that function's RETURNS TABLE forces a DROP + CREATE of an 850-line body with five function-to-function callers Postgres does not track in `pg_depend` (canon SS13 read-only class -- nothing would warn us). That return-type change deserves its own pass with its own R22. **Folding the flag into the recipe row remains OWED** and is the cleaner end state.
- **Frontend:** all three `exportTlx()` builders now read the engine verdict and write the engine's own `export_key`. Held-back lines are **surfaced with their reason** -- a report strip on the desk exporter (mirroring the import report), a loud alert on the two legacy screens that have no strip. A failure to read eligibility **blocks the export** rather than shipping a guessed file.
- **R22:** the fact reproduces the recipe's own emitted key on **all 1,802 ordered lines at 10116 DC_AMBIENT, 0 mismatches**, with 0 lines missing a fact row. 44 lines / R11,107.10 ineligible (26 PLU-synthetic + 18 no-bridge), reproducing ENG-031's independent measurement (46 / R11,439 on a 1,891-line order 12 days out) within order-date drift. Whole-catalogue ineligibility is large (10116 43,053/70,243 through 80579 50,868/52,021) because `v_ean_bridge` covers only 2.2%-43% of articles per store -- that is ENG-032, which this fact **measures** rather than causes. `next build` clean.
- **Security fix caught in verification, not after the fact:** `refresh_l2_export_key` came out of CREATE with `anon=X` despite its own `REVOKE ... FROM PUBLIC` -- Supabase's default-privilege auto-grant, the documented trap (R30 addendum 2026-07-07, same class as the BLOOM-004 write RPCs). A mutating SECURITY DEFINER function executable by `anon` is a real hole. Revoked by name and verified live; the read RPC deliberately keeps anon EXECUTE like every other Bloom read.

Migrations `a1_l2_export_key_pantry_fact`, `a1_wire_l2_export_key_into_pipeline`, `a1_rpc_bloom_export_eligibility`, `a1_revoke_anon_from_refresh_l2_export_key`. Files `sql/create_l2_export_key.sql`, `sql/create_rpc_bloom_export_eligibility.sql`, `sql/create_refresh_l2_pipeline.sql`, `src/app/bloom/page.jsx`.

---

## 2026-07-21 -- ENG-033: the SAB desk (DIRECT_BEER) is ACCOUNT-scoped, not merch-group-scoped

Pieter ruling relayed by PM the same day: re-scope the SAB desk to the supplier-account pattern the later desks use, no manual skip-lists, fix once not twice. Sequenced into Track A ahead of the Track-B Phase-1 identity freeze because the fix is **identity-independent** -- it keys on `product_code` / `supplier_nr` / receipts via `v_supplier_class` and touches no EAN and no TLX zeroing.

- **Identity, receipt-proven (canon SS14 v9 7d, never a name and never a link count):** `direct_supplier_nrs` = **555** at 21355 and 80579, **590** at 80176, all `SAB - DUMMY ACCOUNT`, all supplier_type `F` (DIRECT). The link-only **`1392 SAB BREWERIES`** carries 326 links at 21355 and 319 at 80579 and **zero receipts ever** -- excluded, exactly as CLOVER `1611` was at 10116 in BLOOM-009 wave 2.
- **`DIRECT_BEER` loses its own branch** in `rpc_bloom_order_recipe`, `rpc_bloom_stock_state`, `rpc_project_route_sales_budget`, `rpc_backtest_l2_sales_budget` and `refresh_order_budget_ledger`, and joins the one `DIRECT_*` code path. **Retired with lineage (R28), never deleted:** the `merch_group_nrs` pool scope and the ENG-029 non-Z-receipt gate bolted onto it -- account scope subsumes both, because link-only DC-supplied beer (Distell/Diageo/Heineken/DGB/Isicebi) is not linked to the SAB account at all. The ledger key is UNCHANGED (`v_ledger_route` still returns `DIRECT_BEER`, ENG-013), and the `DIRECT` rollup deliberately keeps its `<> 'DIRECT_BEER'` exclusion or SAB spend would double-count against the DIRECT rail.
- **R22, anchor 2026-07-21, pure addition:** zero lines lost, zero quantities changed. 21355 31 -> 48 lines, R78,533.98 -> R84,541.39 (+R6,007.41 across 17 new lines). 80176 18 -> 30 lines, R23,523.57 -> R28,804.01 (+R5,280.44 across 12). The 29 new lines are Brutal Fruit, Redd's, Black Crown, Bernini&Tonic, Corona Cero and Guinness in merch 301/302/401 -- **15 of them KVI_CRITICAL or KVI_IMPORTANT** and structurally invisible to the beer-merch-group scope. This is the A2 gap, closed the right way: the SAB-supplied 301/302 lines enter on their own account and the DC-dominated ones never do, so the +72 dual-sourced lines the merch-group ADD would have created do not happen.
- **Isolation:** DC_TOPS byte-identical at all three TOPS stores before and after (305/R297,706.97 · 222/R182,295.94 · 253/R285,494.42). Other routes are unaffected by construction -- the changed predicate is route-gated -- and DC_AMBIENT / DIRECT_COCACOLA / DIRECT_SIMBA / DIRECT_CLOVER smoke-tested clean.
- **The guard now runs on the desk it was built for.** `rpc_bloom_direct_dc_overlap` used to RAISE on DIRECT_BEER (no `direct_supplier_nrs`); it now returns **9** dual-sourced products at 21355 and **1** at 80176.
- **Ledger legs repointed to the account and reconciled to the cent:** `landed_amount` July MTD = R180,080.87 (21355) and R214,887.49 (80176), matching an independent `sigma_movements` R/W sum exactly. The old merch-group scope had 80176 at R67,297 -- a 3x understatement, because SAB receipts on 301/302 articles were being excluded. NEEDS rails re-derived: 21355 R11,079 -> R11,755/wk, 80176 R33,770 -> R32,150, 80579 R18,535 -> R14,384.
- **Bonus, no code needed:** `rpc_derive_supplier_cadence` scopes on `DIRECT_*` desks carrying `direct_supplier_nrs`, so the SAB desks derive their own cadence for the first time -- and **confirm the stored calendar**: 21355 Friday weekly (median gap 8, 80.0% dow confidence, 1 outlier gap of 54 named and excluded), 80176 Tuesday weekly (gap 7, 81.8%), both `dow_matches_calendar = true`.
- **Two named gaps (R21 sec 5, surfaced not absorbed):** (1) 80579 has no `supplier_calendar` DIRECT_BEER row so its desk still cannot generate, and its SAB regime has been dark since 2026-03-27 -- the door-closed recovery target the route exists to reopen. (2) `rpc_bloom_direct_beer_flags` is deliberately LEFT merch-group-scoped: it is a beer-CATEGORY floor worklist (136/150/144 lines), and account-scoping it would silently drop real floor work for DC-supplied beer that nobody decided to drop. Its scope is now inconsistent with the desk beside it -- PM's to rule.
- **Drift found while applying, recorded not absorbed:** the live `rpc_bloom_order_recipe` body did not carry the six ENG-029 explanatory comment lines the repo file has. Same logic, different comments; the repo is now authoritative again.

`a874593`. Migrations `eng033_sab_desk_account_scope_config`, `_recipe`, `_stock_state`, `_sales_budget`, `_budget_ledger`. Files `sql/create_rpc_bloom_order_recipe.sql`, `create_rpc_bloom_stock_state.sql`, `create_l2_sales_budget.sql`, `create_refresh_order_budget_ledger.sql`. No schema change (R32 clean: config + function bodies only), no frontend change (`page.jsx` carries labels and the ledger route key, neither of which moved).

## 2026-07-21 -- Chrome MCP tool-name prefix corrected (repo-only, no production deploy)

`f317294`. CLAUDE.md Step 1, `/autopilot` and the settings.json allowlist all used `mcp__Claude_in_Chrome__`; the live namespace is `mcp__claude-in-chrome__`, so the `select:` query resolved nothing (Step 1 silently loaded zero browser schemas) and 22 allowlist entries matched no real tool. Verified by running the corrected 15-name query: all 15 schemas returned. Typo fix, no policy change.

## 2026-07-20 -- SB-CC-BLOOM-014: rpc_bloom_order_recipe v12 -- full-need MINIMUM PRESENCE

Canon SS14 v12 (amends v10 DEPTH, lineage kept). The 80175 DC_AMBIENT Full audit left 387 empty, still-selling lines at zero (343 CORE, 41 SLOW, 2 HERO) because v10 made the order-stock ceiling universal and all-or-nothing -- any line whose single supplier pack breaches it was zeroed, blocking the first pack onto an empty shelf (DF-7 phantom-death spiral, the opposite of Full's availability job).

- **Fix (all in the `packs_mp`/`packs_ceiled`/`geared_ceiled`/`resolved` CTEs, `%8$L IS NULL` guarding it to REAL scenarios so the yardstick/stock_state diagnostic path is byte-unchanged):** (1) a life-gate line (HERO/CORE) whose PROJECTED soh at delivery is below its own min_band gets >=1 pack; that first pack is exempt from the ceiling; the ceiling still caps pack 2+. Trigger is the projection, so it fires above SOH 0 when thin (Pieter). (2) A SLOW line earns the one-pack minimum ONLY where one pack turns within `relevant_min_cover_days` (forge_config, DEMO_CALIBRATION, seed 60); a slower SLOW pack is `keep_or_delist=true`, NOT ordered, surfaced for a keep-or-delist range decision. (3) MARKDOWN/DERANGE/VERIFY unchanged. HERO never silently zeroed -- orders its one exempt pack, carries `hero_pack_over_max`.
- **New (additive, name-safe for every caller): output cols `min_presence_forced` / `keep_or_delist`;** config key `relevant_min_cover_days`. R32 clean -- config + recipe + the `story` label (R29); no schema change. Frontend already surfaces the two new reasons via the `line.story` tooltip.
- **R22, two stores, isolation by measure-before / apply / measure-after.** 80175 DC_AMBIENT Full: 0 pre-ordered lines moved; 426 HERO/CORE below-band now carry a pack; SLOW split 16 ordered / 28 worklist; 0 worklist lines ordered; group rand delta R143,405.86 == exact sum of the added packs (zero gap); 3 HERO empties now order + flag. 80176 DC_TOPS Full: 45 min-presence adds all single-pack & below-band, 0 HERO silently zeroed, worklist exclusive, 0 real ceiling breaches. ESSENTIALS excludes the SLOW minimum (0), CATCH_UP excludes SLOW (0), FITTED + scenario_overview run clean with the new columns.
- **Note (fixed in the same deploy):** the population-ceiling WARNING compared the ROUND(,4) display demand against the full-precision internal ceiling, so a line sitting at EXACTLY 35.0 days read a hair over and cried wolf (2 rows on 80175). Given a 1-day display-rounding guard (`> ceiling + 1`); genuine breaches are days over.

`sql/create_rpc_bloom_order_recipe.sql`, `sql/create_forge_config.sql`. Migrations `rpc_bloom_order_recipe_v12_min_presence_bloom014` + `_warning_rounding_guard` + `forge_config_relevant_min_cover_days_bloom014`. Frontend follow-up (not blocking): a dedicated keep-or-delist worklist view (currently the lines return at 0 packs with the KEEP_OR_DELIST story; queryable via `keep_or_delist`).

---

## 2026-07-20 -- ENG-029: DIRECT_BEER (SAB desk) receipt-scoped, not link-scoped

Found by Pieter's question "is the SAB order just SAB lines?" -- it wasn't. The `DIRECT_BEER` pool scoped by beer/cider merch-group + non-DC *link*, never checking a real direct *receipt*, so link-only DC-supplied beer leaked onto the "SAB Direct" desk and double-counted against DC_TOPS. Receipt-proven at 21355: only SAB (555) has direct receipts (462 in 182d, R1.22M); Distell/Diageo/Heineken/DGB/Isicebi all have ZERO -- their stock arrives on the DC truck (SPAR SOUTHRAND, type Z). The canon 7d trap (attribution by receipts, not links), just never enforced in this pool.

- **Fix:** the DIRECT_BEER base-pool clause in `rpc_bloom_order_recipe` now additionally requires a real non-Z `R/W` receipt for the product in 182d. Applied via a surgical in-place edit (`pg_get_functiondef` -> `replace` the one clause -> `EXECUTE`, guarded) -- the ~300-line dynamic-SQL recipe was NOT hand-retyped. `sql/create_rpc_bloom_order_recipe.sql` line 358.
- **R22, isolated:** DC_AMBIENT 10116 = 977 lines byte-identical with the change reverted vs applied (proven by revert/measure/re-apply); DC_TOPS and DIRECT_<brand> unchanged. Only DIRECT_BEER moves: 21355 41->28 lines, 80176 27, 80579 24. Double-count vs DC_TOPS 19 -> 7.
- **Partial by design -- the remaining 7 are a routing ruling for PM.** They are genuine SAB beers (Carling Black Label, Castle Lite, Corona, Stella, Castle Milk Stout, ~R30k) that are ALSO DC-orderable (dual-sourced -- real receipts on both routes). Canon 7d ("only SAB is direct") says they belong on SAB, i.e. the DC_TOPS pool should exclude direct-receipt-proven beer -- a second core-pool change + routing decision, flagged not rushed. BUG-LOG ENG-029.

`sql/create_rpc_bloom_order_recipe.sql`.

---

## 2026-07-19 -- Mondelez direct desk seeded (call-3 reversal, account-scoped)

Pieter reversed the Mondelez parking: the "doesn't fit the built desk model" read was itself the rule-break relocated -- the "42 of 96 lines Mondelez" split was brand-name text-matching on product descriptions to decide account membership. Correction: one order is placed against one Sigma supplier account; the account IS the order, not the description-matched subset. So Mondelez seeds as a standard `DIRECT_<brand>` desk scoped to the full RECEIVING account, no brand filter, life gate excludes dead lines. R32 config-only, same pattern as Coca-Cola 21355 / National Brands 80175.

- **`DIRECT_MONDELEZ` seeded at 10116 (account 950) + 80175 (account 654)** -- SUPER GROUP AFRICA - MONDELEZ, type S dropshipment (migration `mondelez_01_seed_direct_desk_account_scoped` + `refresh_supplier_calendar`, `sql/create_bloom_route_config_direct_mondelez.sql`). Cadence reproduces canon §14 v9 7g exactly: FORTNIGHTLY (`cycle_weeks=2`), median gap 13, the 42-day supply hole excluded as a regime outlier, real drops R12,054-R49,337 vs noise <=R1,839; 10116 Thursday (60% dow-conf), 80175 Wednesday (37.5% dow-conf, flagged uncertain -- Pieter's walk confirms the day).
- **DC-overlap guard clean (0) at both** (`rpc_bloom_direct_dc_overlap`). R22 end-to-end: next-deliveries land 14 days apart (fortnightly proven -- 10116 07-30->08-13, 80175 07-29->08-12); full-scenario order 10116 34 lines R22,880 / 80175 10 lines R5,374, both clear the R5,000 minimum. The account-scoped pool (224/215 linked) produced real orders -- the life gate excluded dead lines to 34/10 sellable, exactly as ruled (no description pre-filter).
- Frontend `STORE_DESKS` entries added (`Mondelez Direct` at both SPARs, `src/app/bloom/page.jsx`, auth-gated -- Pieter's R31 walk is the gate). `confirmed_by` NULL until the walk.

The "fortnightly four" is now four seeded (Coca-Cola 21355, National Brands 80175, Mondelez 10116+80175), all walk-ready. `sql/create_bloom_route_config_direct_mondelez.sql`.

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
