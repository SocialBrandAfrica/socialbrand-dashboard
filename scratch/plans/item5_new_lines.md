# BLOOM-035 item 5: new lines protected one quarter (R3). Build plan and draft

**Written:** 14-10-2026 16:2x SAST (system clock, `date` at write time) · **By:** CC, read-only prep seat · **Class:** WORKING, not canon · **Status:** NEEDS_LIVE_READ
**Scoped start-read (PM-approved 2026-07-20).** I did not run the CLAUDE.md recital. I read the files that govern this item, listed in section 0. I had no database access. Every figure below is a repo or document figure, and anything that needs the live database is a numbered read in section 7 for the 20:00 to 22:00 window.
**Build lane:** CC's alone. This file prepares. It decides no scope. Where a ruling is missing it is a question in section 6, each with the default I would build on.

---

## 0. What I read, and what I did not

**Read in full:**
- `Bloom/SB-CC-BLOOM-035_Rulings-13-10-Build_v1.0_2026-10-13.md` (v2.0 text, 175 lines)
- `Bloom/RULED-ALREADY_ordering-decisions_2026-10-13.md` (295 lines)
- `sql/create_rpc_bloom_stock_state.sql`, `sql/create_l2_range_state.sql`, `sql/create_sigma_lifecycle.sql`, `sql/create_l2_stock_position.sql`, `sql/create_l2_kvi_profile.sql`, `sql/create_l2_rate_of_sale.sql`, `sql/bt_009_identifiers_dept.sql`, `sql/create_refresh_l2_population_verdict.sql`, `sql/bloom035_e1_cache_rows.sql`, `sql/bloom035_item3b_days_to_truck.sql` (untracked draft), `scratch/README.md`
- `sql/create_rpc_bloom_order_recipe.sql`, all 1,100 lines

**Read in part (ranges):**
- `sql/create_l2_classification.sql` 1-130 and 180-480 of 525 (signals and the cascade, not the DDL or the summary block)
- `sql/bt_010_buying_sunday.sql` 1-150 of 406 (the tail function only)
- `sql/create_refresh_l2_pipeline.sql` 20-373 (the chain order)
- `sql/create_bloom_order_cache.sql` 28-84 and 150-240, `sql/create_rpc_bloom_hidden_demand.sql` 30-60 and 155-224, `sql/create_rpc_forge_count_list.sql` 15-30, 78-112 and 160-180, `sql/create_rpc_bloom_link_verify.sql` 160-205, `sql/create_rpc_bloom_relist_queue.sql` 1-30 and 70-100, `sql/create_l2_bloom_ros_pantry.sql` 196-345, `sql/eng240_stocktake_pool_single_home.sql` 15-45, `sql/create_l2_population_verdict.sql` by grep
- `PROJECT-LEXICON.md` 396-435, `ORDERING-CANON.md` 93-104, `Bloom/SB-PM-CLOSE_2026-10-14_Platform-Lane-State-and-Next-Moves.md` 122-180 and by grep, `Bloom/SB-CC-BLOOM-032_ref/MASTER-BLUEPRINT_2026-10-06.txt` 1-40 and by grep
- `BUG-LOG.md` by line range only: ENG-099 (line 263), ENG-102 (line 266), ENG-235 (3165-3182), ENG-236 (3184-3190)

**Grepped only (no section read):** `ENGINE-CANON-CLASSIFICATION.md`, `ENGINE-CANON-*` children, `CLEANUP-ENGINE-CANON.md`, `ORDERING-CANON-LEDGER.md`, `RULE-BOOK.md`, `SQL-CONVENTIONS.md`, `HANDOVER-CURRENT.md`, `DB-SCHEMA.md`, `src/app/bloom/page.jsx`, `src/app/bloom/StoredOverview.jsx`.
**Not read:** the other ~20 files in the CLAUDE.md start-load, `create_refresh_bloom_order_cache.sql` beyond its header, any Bloom spec other than the two above.
**Grep result worth stating:** no canon file defines a settling window or a new-line test. The only canon hits are `PROJECT-LEXICON.md:418` (PROSE), `ORDERING-CANON.md:103` (the rate divisor for a new line) and the blueprint. The rule exists only as R3 and the lexicon line.

---

## 1. The starting facts, checked

| Fact given | Status | Source |
|---|---|---|
| A line under 91 days from its first sale gets minimum presence and is not judged on its rate | **Verified** in text | `BLOOM-035` line 84. `RULED-ALREADY` lines 171-172 (R3), Pieter 15:04 13-10: "new line is protected for at least 1 qurter" |
| Acceptance: 0 lines under 91 days in SLOW, MARKDOWN or DERANGE | **Verified** in text | `BLOOM-035` line 85 |
| The "measured settling window" is now at least 91 days | **Verified**, with one word to keep: it says "at least" | `RULED-ALREADY` line 172. The blueprint line is `MASTER-BLUEPRINT_2026-10-06.txt:17` and stage 4 at `:36` |
| About 98 SLOW lines under 91 days existed at 10116 on 14-10 | **Unverified. No document I read carries the 98.** | Not in `HANDOVER-CURRENT`, `BUG-LOG` or `SB-PM-CLOSE` by grep. The nearest measured figure is ENG-235: 261 new lines (first till sale in 91 days) in the 10116 DC ambient desk pool, BUG-LOG 3171. Live read 1b gives the real figure |
| Part 4b: a line under 91 days goes to NEW before any derange flag | **Verified** in text | `BLOOM-035` line 71. `RULED-ALREADY` line 283: "On the sheet, NEW now comes before the derange flag" |

One more fact from the files. `RULED-ALREADY` section B (line 93) says 1,712 new lines fail the life gate today "because the gate cannot tell new from dead". The scope of that figure is not stated.

---

## 2. Deliverable 1: where each state comes from

### 2.1 The file you named holds none of the three
`sql/create_rpc_bloom_stock_state.sql` derives no range state. It groups the desk pool by `kvi_band`, in the `lined` CTE at lines 141-148: KVI_CRITICAL and KVI_IMPORTANT to KVI, LONG_TAIL to TAIL, the rest to CORE. It reads `l2_population_verdict` (lines 119-124), never `l2_range_state`. Item 5 does not move it. Item 4b will, because it must stop new lines counting as TAIL (see risk 12).

### 2.2 Where SLOW, MARKDOWN and DERANGE are derived

**The engine's state, `l2_range_state`.** One function writes it: `refresh_l2_range_state(p_store)`, `sql/create_l2_range_state.sql:108-181`. It deletes the store's rows (line 117) and inserts one CASE per line (lines 137-145):

| Order | Line | Test | State |
|---|---|---|---|
| 1 | 138 | line is in `l2_bt_heroes` | HERO |
| 2 | 139 | `l2_classification.bucket` in NON_STOCK, COST_ERROR, SOURCE_FIX, DEPOSIT | EXCLUDED |
| 3 | 140 | `l2_kvi_profile.passes_life_gate` | CORE |
| 4 | 141 | bucket PHANTOM_ZERO | VERIFY |
| 5 | **142** | bucket DEAD_ZERO | **DERANGE** |
| 6 | **143** | bucket LEAVE_COUNTED | **MARKDOWN** |
| 7 | **144** | everything else | **SLOW** |

The function reads three tables: `l2_kvi_profile` (line 121), `l2_bt_heroes` (line 125) and `l2_classification` (line 130). It reads no date. It never looks at a first sale.

**Upstream of those buckets.**
- `passes_life_gate` is `sold in the last 56 days AND at least 3 selling days in 91 AND bucket not in DEAD_ZERO, PHANTOM_ZERO, COST_ERROR, NON_STOCK`. `create_l2_kvi_profile.sql:187-190`. A line in its first two selling days cannot show 3 selling days, so it fails the gate by construction. An older new line fails it when it sold on fewer than 3 days. That is how a new line lands in SLOW.
- DEAD_ZERO is `no movement of any type in 365 days`. `create_l2_classification.sql:371`. A line with a till sale in the last 91 days cannot be DEAD_ZERO.
- LEAVE_COUNTED is `counted within 91 days`, reached at line 377. Lines 372-376 exit first only when the line is HEALTHY (`sold_91`, stock above 0, real EAN or two-way movement) or COUNT (negative stock with a real EAN, or two-way movement). **A line that sold and was counted, with no real EAN and no receipt, falls through to LEAVE_COUNTED.** That is a new line landing in MARKDOWN. It also contradicts the header claim at `create_l2_range_state.sql:36-42` that LEAVE_COUNTED lines are "by construction" dead for a quarter. Live read 8 measures it.
- The classification pool needs `soh <> 0` (`create_l2_classification.sql:341-342`). A new line at zero stock has no bucket, so it can only be SLOW, never MARKDOWN or DERANGE.

**Four more places the word SLOW, MARKDOWN or DERANGE is made.** Item 5's acceptance names the first. Ask PM about the rest (question Q8).
1. **Default when no `l2_range_state` row exists:** `COALESCE(rs.range_state,'SLOW')` at `create_rpc_bloom_order_recipe.sql:535`, `create_refresh_l2_population_verdict.sql:218`, `create_rpc_bloom_hidden_demand.sql:173`, `create_rpc_bloom_link_verify.sql:169`. A line with no row reads as SLOW, no depth.
2. **Bonnie Tyler tail, `l2_bt_tail.action_bucket`:** `bt_010_buying_sunday.sql:113-124` (MARKDOWN 114-116, DERANGE 117-119, VERIFY 120-122, SLOW 123). The table keeps only lines with `units_365 > 0 AND units_91 <= 2` (lines 141-142). A new line that sold 1 or 2 units sits there as SLOW (`VSLOW_91D`, line 102). MARKDOWN and DERANGE need `units_91 = 0`, so a new line cannot reach them. The recipe reads this table once, to keep DERANGE lines out of the temporary floor (`create_rpc_bloom_order_recipe.sql:781-782`).
3. **Population state `SLOW_BELOW_GATE`:** `create_refresh_l2_population_verdict.sql:309`, reason text at line 335: "Listed, no depth, correctly not ordered". A new line that fails the gate gets this label today.
4. **Pulse "Slow Movers" (`slow_mover_signal`):** `create_l2_stock_position.sql:210-214`, `src/app/page.jsx:21,467`. A different idea (no sale in 14 days, active line). **Item 5 must not touch it.**

### 2.3 Where the first-sale date comes from
No range-state object reads one today. Four sources exist:

| Source | Where | What it is |
|---|---|---|
| `sigma_lifecycle.first_sale_date` | `create_sigma_lifecycle.sql:16`, passed through as `l2_stock_position.first_sale_date` at `create_l2_stock_position.sql:125` (join 281-284) | Sigma's own field, loaded by the extractor. A 1990-01-01 sentinel exists in this table (`create_l2_rate_of_sale.sql:33-35`). Classification canon treats Sigma summary fields as cross-checks, never inputs (`create_l2_classification.sql:18-21`) |
| `l2_rate_of_sale.first_sale_date` | `create_l2_rate_of_sale.sql:84-93` (MIN at line 90), selected at line 116 | `MIN(sale_date)` over `sigma_sales`, **with no `period_kind` or `txn_kind` filter**. Matview, unique index, refreshed at pipeline line 65, before `refresh_l2_range_state` |
| The ledger, ENG-235's definition | BUG-LOG 3167 | First till sale: `sigma_sales`, `period_kind 'T'`, `txn_kind 1`, in the 91 days to the store watermark. This produced the PM-accepted 261 |
| First receipt | `_pv_first`, `create_refresh_l2_population_verdict.sql:144-149` | Not a sale date. It feeds `NEW_RANGE` |

History on the mirror started 2025-02-01 at 10116 when it was measured on 07-06 (`create_l2_rate_of_sale.sql:37-38`). It may reach further back now (a memory note records Pieter's 21-09 instruction as about 6 quarters of history, not checked against a file). A line that sold before the first mirrored day and restarted inside 91 days would read as new on either ledger source. Live read 2 counts the disagreements and live read 10 gives each store's first mirrored day.

### 2.4 Does a NEW state exist?
- **`range_state`: no.** The vocabulary is HERO, CORE, SLOW, MARKDOWN, DERANGE, VERIFY, EXCLUDED (`create_l2_range_state.sql:89`, `:188`). No CHECK constraint on it appears in the repo. Live read 5 confirms.
- **The lexicon defines it as prose.** `PROJECT-LEXICON.md:418`: NEW is "a range state for a line inside its settling window. It gets minimum presence and is not judged on its rate", stamped PROSE, and it names `NEW_RANGE` as the nearest live object "which the order does not read".
- **`NEW_RANGE` exists, but it is another thing.** It is a `population_state` (`create_refresh_l2_population_verdict.sql:305`), defined as never sold AND (first receipt within 120 days OR created within 120 days) (lines 292-294). It is a line before its first sale. R3 starts at the first sale. The two do not overlap. The recipe does not read `population_state` at all.
- **Blueprint:** "NEW gets a buffer" at the life gate, before any quantity (`MASTER-BLUEPRINT_2026-10-06.txt:36`).

---

## 3. Deliverable 2: the minimal patch

### 3.1 Design in six lines
1. **One home.** The new-line test lives in `refresh_l2_range_state` and nowhere else. Every reader reads `range_state = 'NEW'`. No second test in the recipe (R33 clause 3, the ENG-102 lesson at ORDERING-CANON §B4).
2. **NEW replaces SLOW, MARKDOWN and DERANGE only.** It sits after VERIFY and before DERANGE in the CASE. A new line that is HERO, EXCLUDED, CORE or VERIFY keeps that state. This matches the acceptance wording and keeps good new sellers at full CORE depth. (Question Q3.)
3. **Settling days from config.** New key `forge_config.new_line_settling_days = 91`, `store_format '*'`, scope DEMO_CALIBRATION, stamped RULING and SEED, UNDERIVED (§0h). The key exists and is populated before the function reads it (the config-key gate).
4. **Window measured to the store watermark,** not `CURRENT_DATE`: `first_sale_date > watermark - 91`. Same anchor as `refresh_l2_kvi_profile` (`create_l2_kvi_profile.sql:125-127`) and ENG-235.
5. **Minimum presence by the wired mechanism.** The recipe's own `mp_life` (canon v12, lexicon `PROJECT-LEXICON.md:405`), extended to NEW. NEW is not a new mechanism.
6. **Readers first, fact last.** Apply order is config row, recipe, cache writer, population verdict wording, then the range-state function. If the fact lands first, NEW lines hit the "not HERO or CORE" branches and get zero depth, worse than SLOW today.

### 3.2 Apply order and pins
Every function change is an asserted replace on `pg_get_functiondef`, each anchor counted, raising if the count is wrong. That is how every recipe change since ENG-102 landed. Pin on `md5(prosrc)` at apply time.

| Function | Repo body md5 (CRLF stripped) | Chars | Status |
|---|---|---|---|
| `rpc_bloom_order_recipe` | `f2fb054fbf7f06943171c490abd51b5b` | 46,427 | Equal to the pin in `sql/bloom035_item3b_days_to_truck.sql:7`. Item 3b may apply first, which moves this pin. Take the pin at apply time |
| `refresh_l2_range_state` | `109081c931a4a070d621783d23fd8b12` | 2,894 | **Not shown equal to live.** The file is the July original (verified live 2026-07-12, repo catch-up 2026-07-14, only a comment line changed since, 2026-09-04). It has `DROP TABLE ... CASCADE` at line 83. `eng240_stocktake_pool_single_home.sql:27` and BUG-LOG line 3037 name this function among the "counted in 91 days" sites. The repo body has no counted flag, only the classification bucket. Either that list is loose or the live body differs. Live read 0 first |
| `refresh_l2_population_verdict` | `406292eb6f6df27e536d8a0738794234` | 20,000 | Re-synced 14-10 |
| `refresh_l2_pipeline` | `8ad6e03a949a7b139680d1427d78fd45` | 13,447 | Matches commit `6fdb8af` |
| `refresh_bloom_order_cache` | not computed | | Two repo files define it (`create_bloom_order_cache.sql:94`, `create_refresh_bloom_order_cache.sql:41`). The older one has no covered rule. Treat the live body as the only source |

**Hash trap:** the files on disk carry CRLF. They hash equal to live only after CRLF is turned into LF. I checked this on the recipe and on the pipeline file.
**Never run `sql/create_l2_range_state.sql` as written.** Line 83 is `DROP TABLE IF EXISTS public.l2_range_state CASCADE`. After the apply, re-sync that file to the live definition, hash-gated, with the DROP removed (R28, stamp the old text retired).

### 3.3 The ordered edit list

**Group A. Config (one insert, first).**
- A-1. `INSERT INTO forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES ('new_line_settling_days','*',91,'DEMO_CALIBRATION', <date from the clock at apply>, '<RULING, Pieter 13-10-2026 15:04 "at least 1 quarter", base rate unstatable, SEED, UNDERIVED, derivation owed: the blueprint's measured settling window>')`. Pre-flight: live read 5 shows no key by that name or like it. Read it back after. Do not copy a date from this file.

**Group B. Recipe, `rpc_bloom_order_recipe`.** 8 replacements, 9 occurrences. Line numbers are in `sql/create_rpc_bloom_order_recipe.sql` after CRLF to LF. Each anchor is the exact text. Expected count is the number of times it appears in the whole body.

| # | Line | Anchor (exact) | Count | Replace with | Why |
|---|---|---|---|---|---|
| B-1 | 681 | `WHEN w.range_state = 'HERO' THEN w.max_band_ot` | 1 | same line, then a new line `WHEN w.range_state = 'NEW' THEN w.min_band_ot` | NEW targets the min band, never the max band, never build mode |
| B-2 | 714 | `(CASE WHEN t.range_state NOT IN ('HERO','CORE') THEN 0` | 1 | `NOT IN ('HERO','CORE','NEW')` | without this NEW has need 0 (`needc.needu`) |
| B-3 | 736 | `AND p.range_state IN ('HERO','CORE') AND p.proj < p.min_band_ot AND p.ros_final > 0) AS mp_life` | 1 | add `'NEW'` to the list | NEW gets minimum presence: one pack when the projected position is under the min band, first pack exempt from the 35-day ceiling |
| B-4 | 755 | `WHEN m.range_state NOT IN ('HERO','CORE') THEN 0` | 1 | add `'NEW'` | without this the pack count is forced to 0 for NEW |
| B-5 | 778 | `c0.range_state IN ('HERO','CORE','SLOW')` | 1 | add `'NEW'` | NEW keeps the temporary 3-unit floor SLOW has today, so no moved line loses a pack |
| B-6 | 775 | `COALESCE(d.tf_cand AND d.ps / NULLIF(d.ros_final,0) >  %31$s, false) AS tf_delist` (two spaces after `>`) | 1 | `COALESCE(d.tf_cand AND d.range_state <> 'NEW' AND d.ps / NULLIF(d.ros_final,0) >  %31$s, false) AS tf_delist` | the floor may add a pack to NEW, it may never delist it. This removes the derange flag |
| B-7 | 810 | `(CASE WHEN wg.range_state NOT IN ('HERO','CORE') THEN 0` | 1 | add `'NEW'` | same as B-2 for the promo (geared) branch |
| B-8 | 996 and 1096 | `(range_state IN (''CORE'',''HERO'') AND soh <= min_band)` (doubled quotes, it sits inside a string) | **2** | `(range_state IN (''CORE'',''HERO'',''NEW'') AND soh <= min_band)` | a NEW line at or under its min band is kept on the sheet at zero, never dropped silently (the ENG-102 rule) |

After B, assert two totals on the new body. `'NEW'` appears **9** times (B-1 to B-7 once each, B-8 twice, and none in the body today). `'HERO','CORE'` still appears **8** times, because every edit keeps that pair as a substring. Per-anchor counts decide. The totals are a second check.

**Left alone on purpose** (the first two would bring the derange routing back if touched):
- line 748 `pack_forced_review` (HERO and CORE only). Keeping NEW out means no NEW line is ever routed to "route to derange/review" (story text at line 967).
- line 737 `slow_candidate` and line 839 `resolved` (SLOW only). NEW never enters the 60-day pack test.
- line 692 `target_reason`. NEW falls to the ELSE and prints `state_reason`, so the story reads "range_state=NEW: ...". The reason text is written in C-6.
- line 850 `is_protected` stays HERO or KVI. NEW is not exempt from the fit's depth cut. Its one pack survives as a floor (line 897, `mp_life`).
- lines 856-857, Catch-up (`cu_always_in`, `cu_eligible`). NEW is left out of the Catch-up walk (question Q5).
- line 535 default `'SLOW'`. A line with no row is not new. Live read 1 counts rows missing (the `no_row` column).

**Group C. `refresh_l2_range_state`, plus one column.** Anchors in `sql/create_l2_range_state.sql`. Reconcile the repo file to live first (live read 0). Table first: `ALTER TABLE public.l2_range_state ADD COLUMN IF NOT EXISTS first_sale_date date` (additive, nullable, existing grants stay). It lets 4b read one home. If PM wants no column, drop C-7 and C-8.

| # | Line | Anchor (exact) | Count | Change |
|---|---|---|---|---|
| C-1 | 115-117 | `  v_summary jsonb;\nBEGIN\n  DELETE FROM public.l2_range_state WHERE store_code = p_store;` | 1 | add `v_anchor date; v_new_days int;`. After BEGIN: `SELECT MAX(sale_date) INTO v_anchor FROM sigma_sales WHERE store_code = p_store AND period_kind='T' AND txn_kind=1`. Read `new_line_settling_days` from `forge_config` (`store_format '*'`, `retired_on IS NULL`). **Raise if the key or the watermark is missing**, before the DELETE, so an old table stays whole if the call fails (the pipeline wraps each store in its own EXCEPTION block, `create_refresh_l2_pipeline.sql:318-322`) |
| C-2 | 133 | `  states AS (` | 1 | insert before it a CTE `fs AS (SELECT product_code, first_sale_date FROM public.l2_rate_of_sale WHERE client_id = 'socialbrand' AND store_code = p_store),` (or the ledger form, see Q1) |
| C-3 | 135 | `      k.product_code, k.passes_life_gate, lc.bucket,` | 1 | add `fs.first_sale_date,` |
| C-4 | 148 | `    LEFT JOIN lc ON lc.product_code = k.product_code` | 1 | add `LEFT JOIN fs ON fs.product_code = k.product_code` |
| C-5 | 142 | `        WHEN lc.bucket = 'DEAD_ZERO' THEN 'DERANGE'` | 1 | insert before it `WHEN fs.first_sale_date > v_anchor - v_new_days THEN 'NEW'` |
| C-6 | 162 | `      WHEN 'DERANGE' THEN 'l2_classification DEAD_ZERO:` | 1 | insert before it `WHEN 'NEW' THEN 'NEW: first sale ' || s.first_sale_date || ', inside the ' || v_new_days || '-day settling window: minimum presence, not judged on its rate'` |
| C-7 | 153 | `    passes_life_gate, classification_bucket, engine_version, profiled_at\n  )` | 1 | add `first_sale_date` to the column list |
| C-8 | 167 | `    s.passes_life_gate, s.bucket, 'v1.0', now()` | 1 | `s.passes_life_gate, s.bucket, 'v1.1 BLOOM-035 item 5', now(), s.first_sale_date`. Check the position of `first_sale_date` against C-7 |
| C-9 | 89 and 187-188 | the `HERO\|CORE\|SLOW...` column comment and the `COMMENT ON TABLE` text | 1 each | add NEW to the stamped vocabulary (R28) |

**Group D. Cache writer, `refresh_bloom_order_cache`.** One anchor, count 1 in the live body: `     AND range_state IN ('CORE', 'HERO')` (the covered-row rule, `create_bloom_order_cache.sql:215`). Add `'NEW'`. Effect: a NEW line kept at zero packs at or under its min band is tagged `covered` and withheld from the served desk like a CORE line (ENG-102). Without it the line serves as an `ordered` row with 0 packs. Pin and count on the live body, because the repo files may differ from it (E1 patched the live body on 13-10 and I did not see a re-sync of either file).

**Group E. Population verdict wording (recommended, one replace).** `create_refresh_l2_population_verdict.sql:335`, anchor `              ELSE 'Below the life gate on its own demand. Listed, no depth, correctly not ordered.' END,` count 1. Make it `WHEN f.range_state = 'NEW' THEN 'New line, first sale inside the settling window: minimum presence, not judged on its rate.' ELSE '...' END`. Reason text only. It adds no `population_state` value, because `l2_population_verdict_state_ck` (`create_l2_population_verdict.sql:96`) would need altering. The state name stays `SLOW_BELOW_GATE` for these lines (Q8). Why it matters: `bloom035_e1_received_placement.sql:160` copies `population_state` and `state_reason` into the reason on 'unordered' sheet rows. Without E it would tell the buyer a new line is "correctly not ordered".

**Not in the patch:** `refresh_l2_bt_tail` (BT's SLOW bucket, Q8), `rpc_bloom_stock_state` (4b), `refresh_l2_kvi_profile` and `refresh_l2_classification` (they feed the state, they do not judge it), the relist queue (`create_rpc_bloom_relist_queue.sql:78-82` lists new lines that fail the gate, which is a ranging worklist and not an order judgement).

### 3.4 Effect on minimum presence and on the rate judgement

**Today, for a new line that fails the gate:**
- SLOW: no depth. One pack only if the projection is under the min band AND `ros_final > 0` AND one pack sells inside 60 days (`slow_candidate`, `pack_relevant`, lines 737 and 743, `relevant_min_cover_days` 60). Otherwise the temp floor: position at or under 3 units AND one pack sells inside 28 days (lines 778 and 774). Otherwise **`keep_or_delist = true`** (lines 751 and 770), shown on the sheet as "KEEP_OR_DELIST: likely to derange" (line 972). That is the derange flag item 4b means.
- MARKDOWN and DERANGE: target is the current stock, need 0, never ordered (line 689 and 714).

**After the patch, for a line in NEW:**
- Target is the **min band** (`ros_final x (drop cover + safety)`), in every mode and preset (B-1). It never builds to the max band.
- **Minimum presence:** one pack when the projected position is under the min band and `ros_final > 0` (B-3). The first pack is exempt from the 35-day ceiling (lines 750 and 757). It carries `min_presence_forced`. It survives the fit as a floor pack (line 897).
- **No rate judgement left that can delist or park it:** no 60-day pack test, no `keep_or_delist` (B-6), no "route to derange/review" (line 748 untouched), no MARKDOWN or DERANGE.
- **What the rate still does:** it sizes the min band, and the trigger needs `ros_final > 0`. The rate for a new line is weak. The 56-day figure is diluted by the days before launch. In standard minimum mode `ros_final` is the published 56-day rate or else `q56/56` (recipe lines 628-630), and the pantry withholds a corrected rate that keeps under half its days observable (`create_l2_bloom_ros_pantry.sql:336-341`). ORDERING-CANON §B5 (line 103) says the honest divisor for a new line is days in stock, and that fix is ruled and not built. So the min band for a young line is low and a line with no sale in the last 56 days (first sale 57 to 90 days ago) has rate 0 and gets nothing. R3 protects the label and the delist. It does not make the engine buy with no demand reading (Q4).
- **Quantity:** it can only add packs for lines that move out of SLOW, MARKDOWN or DERANGE. With B-5 and B-6 no moved line loses a pack it has today. This is a checkable invariant for the R22 (section 5).

### 3.5 Hold or go (Pieter: hold only on a pivot)
R3 is ruled (Pieter 15:04 13-10, the acceptance is in BLOOM-035). I read item 5 as build-to-ruling, not a pivot. The defaults in section 6 are the narrow reading of that ruling. A different answer to Q3 (NEW overrides CORE) or Q4 would change what a buyer sees a strong new line do, and I would stop for PM on those two.

---

## 4. Deliverable 3: acceptance count and the before and after design

### 4.1 The acceptance query (read only, per store)
Run it in the 20:00 to 22:00 window. Send `SET lock_timeout = '5s'` and `SET statement_timeout = '120s'` in the same call. It reads `l2_rate_of_sale`, which the 22:15 chain refreshes under an exclusive lock, so it must finish before 22:00 and never be left running (ENG-236, BUG-LOG 3188).

```sql
SET lock_timeout = '5s'; SET statement_timeout = '120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm
  FROM sigma_sales
  WHERE period_kind = 'T' AND txn_kind = 1 AND sale_date >= current_date - 90
  GROUP BY store_code
),
base AS (
  SELECT k.store_code, k.product_code, r.first_sale_date, r.last_sale_date, wm.wm
  FROM l2_kvi_profile k
  JOIN wm ON wm.store_code = k.store_code
  JOIN l2_rate_of_sale r ON r.client_id = 'socialbrand'
        AND r.store_code = k.store_code AND r.product_code = k.product_code
  WHERE r.first_sale_date > wm.wm - 91
)
SELECT b.store_code,
  count(*)                                                       AS new_lines,
  count(*) FILTER (WHERE rs.product_code IS NULL)                AS no_row,
  count(*) FILTER (WHERE rs.range_state = 'HERO')                AS hero,
  count(*) FILTER (WHERE rs.range_state = 'CORE')                AS core,
  count(*) FILTER (WHERE rs.range_state = 'NEW')                 AS new_state,
  count(*) FILTER (WHERE rs.range_state = 'SLOW')                AS slow,
  count(*) FILTER (WHERE rs.range_state = 'MARKDOWN')            AS markdown,
  count(*) FILTER (WHERE rs.range_state = 'DERANGE')             AS derange,
  count(*) FILTER (WHERE rs.range_state = 'VERIFY')              AS verify,
  count(*) FILTER (WHERE rs.range_state = 'EXCLUDED')            AS excluded,
  count(*) FILTER (WHERE rs.range_state IN ('SLOW','MARKDOWN','DERANGE')
                      OR rs.product_code IS NULL)                AS breaches,
  count(*) FILTER (WHERE b.last_sale_date <= b.wm - 56)          AS silent_56d
FROM base b
LEFT JOIN l2_range_state rs ON rs.store_code = b.store_code AND rs.product_code = b.product_code
GROUP BY b.store_code
ORDER BY b.store_code;
```
- **Acceptance:** `breaches = 0` at all five stores. `no_row` is counted as a breach because the recipe reads a missing row as SLOW.
- **Population:** the base is `l2_kvi_profile`, the same pool `refresh_l2_range_state` reads. Lines outside the pool (PRODUCTION, NON_STOCK) are out of scope by construction.
- **`silent_56d`:** new lines with no sale in 56 days. They get the NEW label and no pack (rate 0).
- Desk grain (live read 1b) and sheet grain (live read 4) use the same base and count the same breaches.

### 4.2 Before and after design
**Why a before snapshot is mandatory.** The nightly cache rebuild replaces each desk's rows. After 01:30 the "before" sheet is gone. Snapshot it first.

1. **Before (20:00 to 22:00, today).**
   - Run live reads 0 to 10. Save the outputs in the BUG-LOG addendum.
   - Write two scratch tables, `service_role` only, `REVOKE ALL` from anon, authenticated and PUBLIC in the same call, dropped after PM reads (the `scratch/README.md` practice, no write outside `cc_scratch_*`):
     - `cc_scratch_b035_i5_state_before`: `store_code, product_code, range_state` from `l2_range_state` (one row per pool line, 14,389 joined rows at 10116 on 31-08, BUG-LOG line 266) plus `first_sale_date` and the watermark.
     - `cc_scratch_b035_i5_sheet_before`: for the named desks, the line columns of the latest nightly standard cache, fit off and fit on: `product_code, range_state, suggested_packs, value, keep_or_delist, min_presence_forced, count_first, story, soh, min_band`. Named desks: one DC desk and one direct desk per store, ten desks. Include 10116 DC_AMBIENT.
2. **Simulate before applying (same window).** Live read 7 reproduces the CASE as a SELECT. Three checks, in the simulate-first method:
   - **Control:** the replica with the old CASE equals the live table, 0 differing rows. If it does not, the repo function is not the live function and no apply goes ahead.
   - **Patched:** the replica with the NEW branch moves only SLOW, MARKDOWN and DERANGE lines with a first sale under 91 days. HERO, CORE, VERIFY and EXCLUDED move 0.
   - **Boundary:** read the lines whose first sale is exactly 90, 91 and 92 days before the watermark. The test is strict, so 91 is out.
   - Then a recipe dry run on the ten named desks: in one session create `pg_temp.l2_range_state` as the patched states (a temp table named like the real one shadows it for an unqualified read, and the recipe sets no `search_path`, header lines 328-332), call a `pg_temp` copy of the patched recipe, call the live recipe against a control copy of the live table, and diff. Same data, same session, so data movement cannot masquerade as the patch. The cache writer allows 300 seconds a desk (`create_refresh_bloom_order_cache.sql:53`). I have no measured run time for the recipe, so time one desk first and cut the list to fit before 22:00. Zero live writes.
3. **Apply (before 22:00).** Order: A, B, D, E, then `ALTER TABLE`, then C. Read back the pins. Then run `refresh_l2_range_state` for the five stores by hand (a light delete and insert, seconds each) and run live read 1 for an immediate reading.
4. **After.**
   - 22:15 the chain refreshes the state again. 01:30 the cache rebuilds. Read back in the morning with live reads 1, 1b and 4 (light reads of tables the pipeline is not holding by then). If PM counts any read between 07:00 and 20:00 as a test, run them at 20:00 on 15-10.
   - **Conservation:** per store, `rows` unchanged. HERO, CORE, VERIFY and EXCLUDED unchanged. `SLOW + MARKDOWN + DERANGE` fell by exactly the before count of new lines in those states. `NEW` rose by the same number.
   - **Named desks:** the same ten desks, before and after, as in section 5.

---

## 5. Deliverable 4: risks, readers, and the R22 compare

### 5.1 Every reader I found
Searched: `sql/` (all `.sql`, `_archive` excluded), `src/`, `scripts/`, all `.js .jsx .ts .py .ps1 .html .json` outside `node_modules`. The only front-end hits are three lines in `src/app/bloom/page.jsx`. **The live database can hold more (views, functions not in `sql/`).** Live read 6 lists them.

| # | Reader | file:line | Reads | After item 5 |
|---|---|---|---|---|
| 1 | Order recipe | `create_rpc_bloom_order_recipe.sql:527, 535-537, 564, 567` | table, default SLOW, HERO flag, EXCLUDED filter | pool unchanged. NEW passes through |
| 2 | Order recipe depth and packs | same file `:681-696, 714-715, 736-737, 748, 755, 775, 778, 810, 839, 850, 856-857, 943, 950, 967, 971, 996, 1096` | the states | edited as B-1 to B-8, the rest left alone on purpose (3.3) |
| 3 | Population verdict | `create_refresh_l2_population_verdict.sql:218, 236, 242, 256, 287, 291, 337` | copies state into `l2_population_verdict`. HERO and CORE only feed `f_hidden`. VERIFY feeds `f_phantom` | carries NEW. NEW lines are never "hidden sellers". Reason text via E |
| 4 | Hidden-demand card | `create_rpc_bloom_hidden_demand.sql:165-173, 189, 215` | HERO and CORE only | NEW excluded, same as SLOW today |
| 5 | Link verify | `create_rpc_bloom_link_verify.sql:169, 199, 202` | label | label only |
| 6 | Count list (stocktake pool) | `create_rpc_forge_count_list.sql:87-88, 97, 170` | `is_ranged` = HERO, CORE, VERIFY (tier 1) | NEW is not ranged. A SLOW line moving to NEW keeps its tier. 0 change |
| 7 | Pool search | `create_rpc_bloom_pool_search.sql:126` | output | label only. `src/app/bloom/page.jsx:2101` copies it into a manually added line |
| 8 | Cache writer, hidden rows | `create_bloom_order_cache.sql:187` | copies state into cache rows | carries NEW |
| 9 | Cache writer, covered rule | `create_bloom_order_cache.sql:215` (and `eng102_surface_covered_lines.sql:120`) | `IN ('CORE','HERO')` | edit D |
| 10 | Unordered rows | `bloom035_e1_cache_rows.sql:48` and `bloom035_e1_received_placement.sql:160` | copies `range_state`, `population_state`, `state_reason` | wording via E |
| 11 | Promo floor gap | `create_rpc_bloom_promo_floor_gap.sql:71, 108, 143` | reads cache lines | label only |
| 12 | Hidden export | `src/app/bloom/page.jsx:2741, 2749` | CSV column | label only |
| 13 | Stock state card | `create_rpc_bloom_stock_state.sql:144-148` | `kvi_band`, **not** range state | unchanged (risk 12) |
| 14 | BT tail and prune list | `bt_010_buying_sunday.sql:113-124`, `bt_009_identifiers_dept.sql:288-340` | its own SLOW and DERANGE buckets | unchanged. Recipe reads it at `create_rpc_bloom_order_recipe.sql:781` |
| 15 | Relist queue | `create_rpc_bloom_relist_queue.sql:78-82` | `passes_life_gate = false` | unchanged |
| 16 | Pipeline | `create_refresh_l2_pipeline.sql:316-324` (range state), `:330-337` (verdict) | order of the chain | order stays, `l2_rate_of_sale` refreshes at line 65, before the range state, so C-2 reads fresh data |

### 5.2 The risks
1. **The repo `refresh_l2_range_state` is not proven equal to live.** The file is the July original, never re-synced from live, and the ENG-240 text lists the function among the "counted in 91 days" sites. Pin it first (live read 0). If the md5 differs, rebuild the anchors from the live body before writing.
2. **The first-sale source moves the counts.** Three sources, three possible answers (2.3). Live read 2 measures the disagreement. `l2_rate_of_sale` has no `period_kind` filter. `sigma_lifecycle` has a sentinel and canon calls it a cross-check. Q1.
3. **Reader-before-fact.** If the range-state function lands before the recipe, NEW lines get need 0, worse than SLOW. Apply order in 4.2.
4. **The 22:15 chain.** It refreshes `l2_rate_of_sale` and `l2_stock_position` under exclusive locks. A read of either left running past 22:00 can block the chain for 90 minutes, which happened on 13-10 (ENG-236). Every read in section 7 sets a lock and a statement timeout and ends before 22:00.
5. **Quantity moves, and floors are funded above the wallet.** NEW packs enter the fit as floor packs (line 897). The fit funds floors first and keeps them when the wallet is short (lines 902-936). Item 2's acceptance is that each desk's stored order totals no more than its own need. NEW floors can push a desk over. The R22 compares desk totals to own need, before and after.
6. **The day-91 step.** At day 91 a line leaves NEW. If it still fails the gate it goes to SLOW, MARKDOWN or DERANGE that night, with no taper. Q6.
7. **Re-coded product codes.** A line can be a new product code for a product that has sold for years (ENG-235 tested a line's own first till sale, not its EAN family). The new code is protected, and the old code, still holding stock, goes to MARKDOWN or DERANGE. Live read 3 counts new lines whose EAN has an earlier selling sibling. Q2.
8. **Weak rate for young lines (3.4).** Min band is low, and rate 0 gives no pack. Not fixed by this item.
9. **Missing row defaults to SLOW** in four places (2.2). It stays. `no_row` in the acceptance query catches any new line caught by it.
10. **Name collisions.** Pulse "Slow Movers" (`slow_mover_signal`), BT `SLOW`, and `SLOW_BELOW_GATE` are different objects. A search and replace on the word SLOW would break the dashboard.
11. **Config-key gate (§0h).** The function reads `new_line_settling_days`. The key must exist and be populated before the function does. The function raises when the key is missing. A raise in one store leaves that store's old table whole and records `range_state_error_<store>` in the chain result. That is stale for one night, not collapsed (the 13-day stale incident in ENG-035 is the warning).
12. **Item 4b depends on this.** 4b says the long tail never holds new lines (`BLOOM-035:66`). Today `kvi_band LONG_TAIL` is every NORMAL line that fails the gate, so new lines sit in the "TAIL" group (`create_rpc_bloom_stock_state.sql:146`). 4b should read `range_state = 'NEW'` or `l2_range_state.first_sale_date`, not a second first-sale test. The order of work puts 4b before 5. Build the NEW definition first or with 4b. Also add NEW to 4b's Essentials list.
13. **MARKDOWN defect underneath.** Sold lines reach LEAVE_COUNTED (2.2). The patch removes only the new-line share. A sold line older than 91 days can still be in MARKDOWN. Live read 8. Not item 5's scope. Worth its own row.
14. **Canon text is stale.** ORDERING-CANON `:97-98` says the recipe "recomputes the gate inline". The recipe on disk has no life-gate CTE (grep for `passes_life_gate` returns two comment lines, 208 and 308). Live read 0 checks the live body.
15. **One seat on the recipe.** Items 2 to 5 share it. Item 3b's draft (`sql/bloom035_item3b_days_to_truck.sql`, untracked, unapplied) edits `t.ros_final * %9$s` (count 2) and `(wg.ros_final*wg.gear) * %9$s` (count 2). My anchors share no text with those, so the two patches apply in either order. Each takes its own pin.

### 5.3 What the R22 check compares
Per store, then per named desk, on identical inputs (the dry run, section 4.2).

1. **State conservation.** Rows by state before and after. Only SLOW, MARKDOWN, DERANGE fall and NEW rises, by equal amounts. 0 differing rows for HERO, CORE, VERIFY, EXCLUDED.
2. **Every moved line, listed.** `product_code`, first sale date, old state, new state, `soh`, `min_band`, packs before, packs after, `keep_or_delist` before and after, value.
3. **No pack lost.** For every line that moved out of SLOW, `packs_after >= packs_before` on both the fit-off and fit-on order. For MARKDOWN and DERANGE, `packs_after >= 0`. Any exception stops the apply.
4. **Nothing else moves.** Every line that did not change state has the same `suggested_packs`, `value`, `story` and flags. Expect 0 differing rows. This is the check that item 5 changed nothing outside its own lines.
5. **The flag is gone.** 0 NEW lines with `keep_or_delist = true`. 0 NEW lines with `pack_forced_review = true`.
6. **Minimum presence works.** Every NEW line with `projected_soh < min_band` and `rhythm_adjusted_demand > 0` has `suggested_packs >= 1` on the fit-off order. On the fit-on order it has 1 as a floor.
7. **Rands per desk.** Total value before and after, the delta equal to the sum of the moved lines' added packs, to the cent. Then desk total against the desk's own need (item 2), before and after. Report any desk that crosses its need.
8. **The stored sheet.** 0 sheet rows labelled SLOW, MARKDOWN or DERANGE among lines under 91 days, on every desk, fit off and fit on (live read 4).
9. **Wording.** The unordered and hidden rows for a NEW line do not say "correctly not ordered".

---

## 6. Deliverable 5: open questions for PM

Each has the default I would build on if you say nothing. I would stop only on Q3 and Q4 (they change what a buyer sees a good new line do).

**Q1. Which first-sale date?** Default: the ledger, `sigma_sales` `period_kind 'T'`, `txn_kind 1`, as ENG-235 (the 261 you accepted). I would read it from `l2_rate_of_sale.first_sale_date` only if live read 2 shows it equals the ledger. If they differ, say which wins. Sigma's own `first_sale_date` is a cross-check under classification canon.

**Q2. New by product code or by EAN?** Default: by the line's own first sale, as ENG-235. A re-coded successor of a long-selling product would be protected, and its old code would go to MARKDOWN or DERANGE. Live read 3 counts it. If the count is material, new should mean no earlier sale on the same EAN.

**Q3. Does NEW override CORE?** Default: no. NEW replaces only SLOW, MARKDOWN and DERANGE. A new line that already passes the life gate stays CORE with full depth. The acceptance reads this way. The cost: 4b's long-tail test needs the stored first-sale date and not the state alone. If you want every line under 91 days to read NEW, a strong new seller would lose its build-mode depth and its Catch-up place.

**Q4. What is minimum presence for a line with no demand reading?** Default: the wired rule. One pack when the projected position is under the min band and the rate is above 0. A new line with no sale in 56 days (first sale 57 to 90 days ago) gets the label and no pack. The other reading is one pack whenever the shelf is empty, whatever the rate. That is a method change.

**Q5. NEW in Essentials and Catch-up?** Default: Essentials gives NEW its min band (as non-KVI CORE gets it today, B-1 applies in every preset). Catch-up leaves NEW out of the walk (0 packs, no flag). When 4b limits Essentials to KVI, HERO and promo, add NEW to that list, since R3 is a protection.

**Q6. The day-91 step.** Default: none. At day 91 the line follows its own gate result that night. Do you want a taper, for example one more quarter at SLOW depth before MARKDOWN or DERANGE can apply?

**Q7. Lines received and not yet sold.** R3 starts at the first sale, so a never-sold line stays outside it. Those lines are `NEW_RANGE` in the population verdict (first receipt within 120 days) and the verdict's own text says they "never reach the order sheet" (`create_refresh_l2_population_verdict.sql:320-322`). The lexicon's NEW ("a line inside its settling window") reads wider than R3. Default: out of scope for item 5. Say so if you want them in.

**Q8. Which SLOW does the acceptance count?** Default: `l2_range_state` only, because it is what the recipe and the sheet read. The Bonnie Tyler tail also carries new lines as SLOW (`VSLOW_91D`), and the population verdict labels them `SLOW_BELOW_GATE`. I fix the verdict's reason text (E) and leave both state names. If the acceptance covers either name, that is two more edits and, for the verdict, a CHECK constraint change.

**Q9. The 91 as a key.** Default: `forge_config new_line_settling_days = 91`, stamped RULING and SEED, UNDERIVED, derivation owed ("at least 1 quarter" gives a floor, the blueprint says measured). Is the measured window still wanted, for example days until a line holds N selling days, and is it ever allowed to exceed 91?

**Q10. Order of work.** 4b before 5 in the written order, but 4b needs the new-line test. Default: build the NEW definition (Group C and the column) with 4b, and keep the recipe edits (Group B) in item 5. Confirm.

---

## 7. Live reads for the 20:00 to 22:00 window

All read only. Send each as one call. Each sets a lock and a statement timeout and must finish before 22:00 (risk 4). Run in this order. `wm` is the store's ledger watermark, the same anchor `rpc_bloom_stock_state` uses (lines 111-113).

**Read 0. Pins: is the repo copy the live function, and does the recipe hold its own gate?**
Answers: whether `refresh_l2_range_state` on disk equals live (expect `109081c9...`, 2,894 chars) and the others (recipe `f2fb054f...` 46,427, verdict `406292eb...` 20,000, pipeline `8ad6e03a...` 13,447), whether any overload exists, and whether the recipe has an inline life gate.
```sql
SET lock_timeout='5s'; SET statement_timeout='60s';
SELECT p.oid::regprocedure AS sig, md5(p.prosrc) AS prosrc_md5, length(p.prosrc) AS chars,
       position('passes_life_gate' in p.prosrc) > 0 AS mentions_life_gate,
       (length(p.prosrc) - length(replace(p.prosrc, '''HERO'',''CORE''', ''))) / length('''HERO'',''CORE''') AS hero_core_pairs,
       (length(p.prosrc) - length(replace(p.prosrc, '''CORE'',''HERO''', ''))) / length('''CORE'',''HERO''') AS core_hero_pairs,
       position('range_state IN (''CORE'', ''HERO'')' in p.prosrc) > 0 AS cache_covered_rule
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('refresh_l2_range_state','rpc_bloom_order_recipe','refresh_l2_population_verdict',
                    'refresh_bloom_order_cache','refresh_l2_pipeline','refresh_l2_kvi_profile',
                    'refresh_l2_classification','refresh_l2_bt_tail')
ORDER BY p.proname, 1;
```
Expect for the recipe: `hero_core_pairs` 8, `core_hero_pairs` 2, `mentions_life_gate` false.

**Read 1. The acceptance baseline, per store.** Answers: how many lines are under 91 days from first sale, in which state, and how many are breaches today (the unverified 98 at 10116). Use the query in section 4.1 unchanged.

**Read 1b. The same, per desk.** Answers: the breaches on the desk pool, which is where ENG-235 counted.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
)
SELECT pv.store_code, pv.route_key,
  count(*) AS new_lines_on_desk,
  count(*) FILTER (WHERE pv.range_state='NEW')      AS new_state,
  count(*) FILTER (WHERE pv.range_state='SLOW')     AS slow,
  count(*) FILTER (WHERE pv.range_state='MARKDOWN') AS markdown,
  count(*) FILTER (WHERE pv.range_state='DERANGE')  AS derange,
  count(*) FILTER (WHERE pv.range_state IN ('HERO','CORE')) AS hero_core,
  count(*) FILTER (WHERE pv.population_state='SLOW_BELOW_GATE') AS pop_slow_below_gate
FROM l2_population_verdict pv
JOIN wm ON wm.store_code = pv.store_code
JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=pv.store_code AND r.product_code=pv.product_code
WHERE r.first_sale_date > wm.wm - 91
GROUP BY pv.store_code, pv.route_key
ORDER BY pv.store_code, pv.route_key;
```

**Read 2. Do the three first-sale sources agree?** Answers Q1: the count of lines where the ledger, `l2_rate_of_sale` and `sigma_lifecycle` give different answers to "under 91 days", and how many of those candidates carry the 1990-01-01 lifecycle sentinel.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
),
cand AS (
  SELECT k.store_code, k.product_code, wm.wm, r.first_sale_date AS ros_first, lc.first_sale_date AS lc_first
  FROM l2_kvi_profile k
  JOIN wm ON wm.store_code = k.store_code
  LEFT JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=k.store_code AND r.product_code=k.product_code
  LEFT JOIN sigma_lifecycle lc ON lc.client_id='socialbrand' AND lc.store_code=k.store_code AND lc.product_code=k.product_code
  WHERE r.first_sale_date > wm.wm - 91
     OR (lc.first_sale_date > wm.wm - 91 AND lc.first_sale_date <= wm.wm)
),
led AS (
  SELECT ss.store_code, ss.product_code, min(ss.sale_date) AS led_first
  FROM sigma_sales ss
  JOIN cand c ON c.store_code=ss.store_code AND c.product_code=ss.product_code
  WHERE ss.period_kind='T' AND ss.txn_kind=1
  GROUP BY ss.store_code, ss.product_code
)
SELECT c.store_code, count(*) AS candidates,
  count(*) FILTER (WHERE l.led_first > c.wm - 91)                    AS new_by_ledger_t1,
  count(*) FILTER (WHERE c.ros_first > c.wm - 91)                    AS new_by_rate_of_sale,
  count(*) FILTER (WHERE c.lc_first > c.wm - 91 AND c.lc_first <= c.wm) AS new_by_lifecycle,
  count(*) FILTER (WHERE (l.led_first > c.wm - 91) IS DISTINCT FROM (c.ros_first > c.wm - 91)) AS ledger_vs_rate_of_sale_differ,
  count(*) FILTER (WHERE (l.led_first > c.wm - 91) IS DISTINCT FROM (c.lc_first > c.wm - 91 AND c.lc_first <= c.wm)) AS ledger_vs_lifecycle_differ,
  count(*) FILTER (WHERE c.lc_first = DATE '1990-01-01')             AS lifecycle_sentinel
FROM cand c
LEFT JOIN led l ON l.store_code=c.store_code AND l.product_code=c.product_code
GROUP BY c.store_code ORDER BY c.store_code;
```

**Read 3. Re-coded product codes.** Answers Q2: how many "new" lines share an EAN with a code that sold earlier.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
),
newl AS (
  SELECT k.store_code, k.product_code, r.first_sale_date
  FROM l2_kvi_profile k
  JOIN wm ON wm.store_code = k.store_code
  JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=k.store_code AND r.product_code=k.product_code
  WHERE r.first_sale_date > wm.wm - 91
),
fam AS (
  SELECT n.store_code, n.product_code,
    EXISTS (
      SELECT 1 FROM v_ean_bridge b1
      JOIN v_ean_bridge b2 ON b2.store_code = b1.store_code AND b2.ean = b1.ean AND b2.product_code <> b1.product_code
      JOIN l2_rate_of_sale r2 ON r2.client_id='socialbrand' AND r2.store_code=b2.store_code AND r2.product_code=b2.product_code
      WHERE b1.store_code = n.store_code AND b1.product_code = n.product_code
        AND r2.first_sale_date < n.first_sale_date) AS has_earlier_sibling
  FROM newl n
)
SELECT f.store_code, count(*) AS new_lines,
  count(*) FILTER (WHERE f.has_earlier_sibling) AS with_earlier_sibling_code
FROM fam f GROUP BY f.store_code ORDER BY f.store_code;
```

**Read 4. The stored sheet today.** Answers what the buyer sees now for new lines, and the baseline for the R22: new lines on the latest nightly standard sheets, by desk, with the SLOW rows, the `keep_or_delist` flags and the ordered value.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
),
hdr AS (
  SELECT c.cache_id, c.store_code, c.route_key, c.delivery_date, c.fit_to_budget
  FROM bloom_order_cache c
  WHERE c.preset = 'standard' AND c.generated_at > now() - interval '40 hours'
)
SELECT h.store_code, h.route_key, h.fit_to_budget, h.delivery_date,
  count(*) AS new_lines_on_sheet,
  count(*) FILTER (WHERE l.range_state='SLOW')                   AS slow,
  count(*) FILTER (WHERE l.range_state IN ('MARKDOWN','DERANGE')) AS markdown_derange,
  count(*) FILTER (WHERE l.keep_or_delist)                       AS keep_or_delist,
  count(*) FILTER (WHERE l.suggested_packs > 0)                  AS ordered,
  round(coalesce(sum(l.value) FILTER (WHERE l.suggested_packs > 0), 0)::numeric, 2) AS ordered_value
FROM hdr h
JOIN bloom_order_cache_line l ON l.cache_id = h.cache_id
JOIN wm ON wm.store_code = h.store_code
JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=l.store_code AND r.product_code=l.product_code
WHERE r.first_sale_date > wm.wm - 91
GROUP BY h.store_code, h.route_key, h.fit_to_budget, h.delivery_date
ORDER BY h.store_code, h.route_key, h.fit_to_budget, h.delivery_date;
```

**Read 5. Config collision and constraints.** Answers: whether a settling key already exists, and whether any CHECK constraint blocks a new `range_state` value.
```sql
SET lock_timeout='5s'; SET statement_timeout='30s';
SELECT 'forge_config' AS what, config_key AS name, store_format::text AS detail, value_num::text AS val
FROM forge_config WHERE config_key ILIKE '%new%line%' OR config_key ILIKE '%settl%'
UNION ALL
SELECT 'check', conrelid::regclass::text || '.' || conname, pg_get_constraintdef(oid), NULL::text
FROM pg_constraint
WHERE contype = 'c'
  AND conrelid IN ('public.l2_range_state'::regclass, 'public.l2_population_verdict'::regclass,
                   'public.bloom_order_cache_line'::regclass)
ORDER BY 1, 2;
```

**Read 6. Every live object that mentions `range_state`.** Answers: readers the repo does not show. The live database outranks the repo on this.
```sql
SET lock_timeout='5s'; SET statement_timeout='60s';
SELECT 'function' AS kind, p.oid::regprocedure::text AS obj
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' AND p.prosrc ~* 'range_state'
UNION ALL
SELECT 'view', c.oid::regclass::text
FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('v','m')
  AND pg_get_viewdef(c.oid) ~* 'range_state'
ORDER BY 1, 2;
```

**Read 7. The simulation, with its control.** Answers: whether the replica of the old CASE equals the live table (`control_differs_from_live_table` must be 0), and what the patched CASE would move. Pure SELECT, zero writes.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
),
hero AS (SELECT DISTINCT store_code, product_code FROM l2_bt_heroes),
lc AS (
  SELECT DISTINCT ON (store_code, product_code) store_code, product_code, bucket
  FROM l2_classification ORDER BY store_code, product_code, snapshot_date DESC
),
sim AS (
  SELECT k.store_code, k.product_code,
    CASE
      WHEN hero.product_code IS NOT NULL THEN 'HERO'
      WHEN COALESCE(lc.bucket,'') IN ('NON_STOCK','COST_ERROR','SOURCE_FIX','DEPOSIT') THEN 'EXCLUDED'
      WHEN k.passes_life_gate THEN 'CORE'
      WHEN lc.bucket = 'PHANTOM_ZERO' THEN 'VERIFY'
      WHEN lc.bucket = 'DEAD_ZERO' THEN 'DERANGE'
      WHEN lc.bucket = 'LEAVE_COUNTED' THEN 'MARKDOWN'
      ELSE 'SLOW' END AS old_state,
    CASE
      WHEN hero.product_code IS NOT NULL THEN 'HERO'
      WHEN COALESCE(lc.bucket,'') IN ('NON_STOCK','COST_ERROR','SOURCE_FIX','DEPOSIT') THEN 'EXCLUDED'
      WHEN k.passes_life_gate THEN 'CORE'
      WHEN lc.bucket = 'PHANTOM_ZERO' THEN 'VERIFY'
      WHEN r.first_sale_date > wm.wm - 91 THEN 'NEW'
      WHEN lc.bucket = 'DEAD_ZERO' THEN 'DERANGE'
      WHEN lc.bucket = 'LEAVE_COUNTED' THEN 'MARKDOWN'
      ELSE 'SLOW' END AS new_state,
    (r.first_sale_date - (wm.wm - 91)) AS days_inside_window
  FROM l2_kvi_profile k
  JOIN wm ON wm.store_code = k.store_code
  LEFT JOIN hero ON hero.store_code = k.store_code AND hero.product_code = k.product_code
  LEFT JOIN lc   ON lc.store_code   = k.store_code AND lc.product_code   = k.product_code
  LEFT JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=k.store_code AND r.product_code=k.product_code
)
SELECT s.store_code, count(*) AS rows,
  count(*) FILTER (WHERE s.old_state IS DISTINCT FROM rs.range_state)         AS control_differs_from_live_table,
  count(*) FILTER (WHERE s.new_state <> s.old_state)                          AS lines_that_move,
  count(*) FILTER (WHERE s.old_state='SLOW'     AND s.new_state='NEW')        AS slow_to_new,
  count(*) FILTER (WHERE s.old_state='MARKDOWN' AND s.new_state='NEW')        AS markdown_to_new,
  count(*) FILTER (WHERE s.old_state='DERANGE'  AND s.new_state='NEW')        AS derange_to_new,
  count(*) FILTER (WHERE s.old_state IN ('HERO','CORE','VERIFY','EXCLUDED') AND s.new_state <> s.old_state) AS protected_states_that_move,
  count(*) FILTER (WHERE s.new_state='NEW' AND s.days_inside_window BETWEEN 1 AND 2) AS leaving_window_in_1_or_2_days
FROM sim s
LEFT JOIN l2_range_state rs ON rs.store_code = s.store_code AND rs.product_code = s.product_code
GROUP BY s.store_code ORDER BY s.store_code;
```
Expect `control_differs_from_live_table` 0 and `protected_states_that_move` 0. `days_inside_window` is 1 when the first sale is 90 days before the watermark (in) and 0 when it is 91 days before (out). The last column counts the lines one or two days from leaving the window.

**Read 8. Do sold lines sit in MARKDOWN?** Answers risk 13: the claim at `create_l2_range_state.sql:36-42` against the cascade.
```sql
SET lock_timeout='5s'; SET statement_timeout='60s';
SELECT rs.store_code, count(*) AS markdown_lines,
       count(*) FILTER (WHERE c.sold_91) AS markdown_with_sale_in_91d
FROM l2_range_state rs
LEFT JOIN LATERAL (
  SELECT lc.sold_91 FROM l2_classification lc
  WHERE lc.store_code = rs.store_code AND lc.product_code = rs.product_code
  ORDER BY lc.snapshot_date DESC LIMIT 1) c ON true
WHERE rs.range_state = 'MARKDOWN'
GROUP BY rs.store_code ORDER BY rs.store_code;
```

**Read 9. The Bonnie Tyler tail.** Answers Q8: new lines in the BT buckets.
```sql
SET lock_timeout='5s'; SET statement_timeout='60s';
WITH wm AS (
  SELECT store_code, max(sale_date) AS wm FROM sigma_sales
  WHERE period_kind='T' AND txn_kind=1 AND sale_date >= current_date - 90 GROUP BY store_code
)
SELECT t.store_code, t.action_bucket, t.flag, count(DISTINCT t.product_code) AS new_lines
FROM l2_bt_tail t
JOIN wm ON wm.store_code = t.store_code
JOIN l2_rate_of_sale r ON r.client_id='socialbrand' AND r.store_code=t.store_code AND r.product_code=t.product_code
WHERE r.first_sale_date > wm.wm - 91
GROUP BY t.store_code, t.action_bucket, t.flag
ORDER BY t.store_code, t.action_bucket, t.flag;
```

**Read 10. History start per store.** Answers the truncation risk in 2.3: the first sale a store can show.
```sql
SET lock_timeout='5s'; SET statement_timeout='120s';
SELECT store_code, min(sale_date) AS history_start, max(sale_date) AS watermark
FROM sigma_sales WHERE period_kind='T' AND txn_kind=1 GROUP BY store_code ORDER BY store_code;
```

---

## 8. The build order, once the reads are in

1. 20:00 to 22:00: reads 0 to 10, scratch snapshots, simulation, dry run on ten desks. Report to PM before any apply.
2. Write `sql/bloom035_item5_new_lines.sql` (groups A to E, asserted replaces, md5 pins, one count assertion per anchor, read-back of the config key) and `scratch/sim_item5_new_lines.sql`. Not written today.
3. Apply before 22:00 if the control is 0 and the invariants in 5.3 hold. Otherwise the next window. No apply between 22:00 and 03:00.
4. Read back (4.2), BUG-LOG row, DB-SCHEMA entry for `l2_range_state`, re-sync `sql/` to live with the md5, commit, push. PM does the R22 read on the live desk, then canon with lineage (ORDERING-CANON §B, lexicon E4 line 418 from PROSE to WIRED).
