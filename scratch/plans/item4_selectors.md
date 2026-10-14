# BLOOM-035 items 4 and 4b: every selector works, depth by class. Build plan

**Written:** 14-10-2026 16:4x SAST (clock read 16:40 +02:00 local, 14:40 UTC, the two agree, re-read before the stamp) by CC, prep seat · **Status:** PLAN. Nothing built, nothing applied, no database touched, no existing file edited · **Owner of the build:** the builder seat (one seat on the recipe) · **Governing:** SB-CC-BLOOM-035 v2.0 items 4 and 4b (lines 44 to 82), RULED-ALREADY v1.7 R5, R10 and R11 (the R10 KVI and long-tail lines are withdrawn, R11 replaces them), PM rulings of 14-10 09:0x (hold only on a pivot).
**Companion plan:** `scratch/plans/item5_new_lines.md` (item 5). Item 4b needs its new-line test. Section 5.1 says how the two fit.

**Map to the five things asked:** (1) each selector, its code path, its verdict and its read-back test is section 2. (2) Storing Essentials and Catch-up nightly, with row count, run time and the 23:30 UTC risk, is section 3. (3) The pension build is section 4. (4) The 4b class changes as an ordered edit list with anchors and counts is section 5. (5) Ready, needs PM, and the build order are sections 6 and 7. The reads for the 20:00 to 22:00 window are section 8.

---

## 0. Scope, what I read, what I did not

**I scoped the start-read** (PM-approved 2026-07-20, task text). I did not run the CLAUDE.md recital. This plan rests on the files below. A canon rule I did not load is not used here.

**Read in full:**
- `Bloom/SB-CC-BLOOM-035_Rulings-13-10-Build_v1.0_2026-10-13.md` (176 lines)
- `Bloom/RULED-ALREADY_ordering-decisions_2026-10-13.md` (296 lines, R2, R5, R10, R11 and the rest)
- `sql/create_rpc_bloom_order_recipe.sql` (1,100 lines, body at 328 to 1100)
- `sql/create_refresh_bloom_order_cache.sql`, `sql/create_bloom_order_cache.sql`, `sql/_archive/refresh_bloom_order_cache_pre_e1.sql`
- `sql/bloom035_e1_cache_rows.sql`, `sql/bloom035_item2_fit_own_need.sql`, `sql/bloom035_item3b_days_to_truck.sql`
- `sql/create_rpc_bloom_stored_overview.sql`, `sql/create_rpc_bloom_stock_state.sql`, `sql/create_l2_range_state.sql`
- `sql/create_rpc_bloom_next_deliveries.sql`, `sql/create_calendar_events.sql`, `sql/create_refresh_l2_pipeline.sql`
- `Engine/SB-AUD-RHYTHM-001_Calendar-and-Rhythm-Dependency-Trace_v1.0_2026-09-03.md`
- `scratch/item3_rhythm_shape.sql`

**Read in part:**
- `src/app/bloom/page.jsx`: lines 30 to 130, 1280 to 2685. The old Generate form and the hidden Recipe mode (130 to 1280) only by grep. Lines 2685 to 3484 not read.
- `sql/create_l2_population_verdict.sql` 1 to 160, `create_l2_gmroi_profile.sql` 36 to 142, `create_l2_export_key.sql` 30 to 80, `create_l2_rhythm_profile.sql` 1 to 150, `create_l2_stock_position.sql` 1 to 190, `create_rpc_bloom_desks.sql` 70 to 126, `2026-08-13_bloom_recipe_eng083_v16.sql` 1 to 80, `bloom035_1b_dc_fresh_phase0.sql` 1 to 60.
- `Engine/SB-CC-QUEUE-001_CC-Build-Queue_v1.0_2026-08-25.md` 395 to 447 (the pension ruling).
- `HANDOVER-CURRENT.md` 40 to 75, `Bloom/SB-PM-CLOSE_2026-10-14_Platform-Lane-State-and-Next-Moves.md` 105 to 247 and 325 to 335, `BUG-LOG.md` 3165 to 3195 (ENG-235 and ENG-236).
- `scratch/plans/item5_new_lines.md` lines 76 to 172 and 286 to 333 (a sibling plan, read to avoid two edits on one anchor).
- `sql/bloom035_fresh_cover_cap.sql` lines 1 to 66 (an untracked draft from another seat, 16:34 today, read for the same reason). I only looked at the headers of `sql/bloom035_beer_family_budget.sql` and `sql/bloom035_item2_retire_pooled_direct.sql`. Neither edits the recipe.

**Not read:** every canon file (ORDERING-CANON and its children, ENGINE-CANON-*, RULE-BOOK, PROJECT-LEXICON, PIETERSTYLE), BUG-LOG rows ENG-012, 020, 056, 058, 077, 078, 117, 183, 204, 237, `rpc_derive_placement_day`, `refresh_l2_population_verdict`, `rpc_bloom_pool_search`, `rpc_bloom_delivery_chain`, `rpc_bloom_month_projection`, `StoredOverview.jsx` (grep only), `SB-CC-BLOOM-034`. Style comes from the task text.

**What I wrote besides this file:** four small helper files in the session scratchpad (a Node hash and anchor counter and three anchor lists, in `C:\Users\User\AppData\Local\Temp\claude\...\scratchpad\item4_*`). They are outside the repo. Every anchor count below came from that counter run on the repo recipe.
**No live read happened.** Everything that needs the database is a numbered read in section 8.

---

## 1. The facts you gave me, checked

| # | Fact | Verdict | Evidence |
|---|---|---|---|
| 1 | Cron 26 stores only preset standard | **Verified in code, count not re-read.** | `refresh_bloom_order_cache_all` defaults `p_presets` to `ARRAY['standard']` and the cron line calls it with no argument (`sql/create_bloom_order_cache.sql:397`, `:469-470`). The 0 and 0 count is RULED-ALREADY R5 line 179 (read 13-10). Read 4 re-counts. The cron command itself is a live read (read 1). |
| 2 | Build mode reads a typed day 25, not the income calendar | **Verified, and there are three typed sources, not one.** | (a) `forge_config month_end_build_anchor_dom` = 25 (`create_rpc_bloom_order_recipe.sql:432-433`, created at `2026-08-13_bloom_recipe_eng083_v16.sql:33-36`). It drives the derived window, and only for preset standard on DC_AMBIENT and DC_TOPS (`:430-431`). (b) The parameter default `p_early_month_build_start_day` = 25 (`:328`, `:363`) drives EARLY_MONTH lines on every route and every preset (`:627`, `:640`, argument `%7$s` at `:977`). (c) The fallbacks 15 and 24 (`:328`, `:361-362`) drive MONTH_END lines on every direct desk and every other preset. The cache builder passes NULL for all three (`create_bloom_order_cache.sql:145`). Two other callers pass the literals 15, 24, 25 (`create_rpc_bloom_scenario_overview.sql:93,103,107,111,115`, `create_rpc_bloom_direct_dc_overlap.sql:43`). |
| 3 | The recipe reads no income calendar | **Verified.** | A grep of the recipe body for `calendar_events`, `SASSA` and `income` returns nothing. The only reader of `calendar_events` is `rpc_bloom_next_deliveries` (`create_rpc_bloom_next_deliveries.sql:97-165`), plus `eng082_h13_h14_placement_one_home.sql`. SB-AUD-RHYTHM-001 section 1 says the same. |
| 4 | Pieter's pension rule (01-09) | **Verified.** | `Engine/SB-CC-QUEUE-001...md:419`: "the 25th is one payday cycle in the rythm. the order preceding pension window is another. so the last order before pension is the last uplift day. the order delivered immediately after that one must be the first minimum band." |
| 5 | KVI unchanged, CORE unchanged | **Verified.** | KVI safety days 4 and 2 (`recipe:643`), min band `ros x lead + safety x ros` (`:648`), CORE target min band in minimum mode (`:687-688`). |
| 6 | The 3-unit floor lives in `forge_config temp_floor_units` | **Verified.** | Keys `temp_floor_units` 3 and `temp_floor_pack_days` 28, DEMO_CALIBRATION, effective 05-10 (`2026-10-05_eng228_eng229_eng230_ordering_three_fixes.sql:46-49`), read at `recipe:375-381`. Pieter's 05-10 words keep the pack test in the floor: "longer than 4 weeks to sell one pack is flagged for deletion" (`:49`). |
| 7 | Tail is "today CORE with tier BOR" | **Verified.** | `tier` comes from `l2_stock_position` (`recipe:533`), default BOR (`create_l2_stock_position.sql:178`). |

**Five corrections you did not ask for:**

1. **The repo copy of the cache builder is not the live one.** `sql/create_refresh_bloom_order_cache.sql:41-173` has no `covered` tagging, no ENG-117 store-local anchor and no E1 STEP 3b. `sql/create_bloom_order_cache.sql:94-247` has the first two and not E1. The live body is `sql/_archive/refresh_bloom_order_cache_pre_e1.sql` plus the E1 patch (`bloom035_e1_cache_rows.sql:17-78`). Take every cache-builder anchor from `pg_get_functiondef` at build time, never from either `create_*` file. Re-sync the file first (step A-1, section 6).
2. **The recipe file header is stale and the body is right.** The header names a retired pin (`create_rpc_bloom_order_recipe.sql:3`, b6bbee1e). I hashed the body here: `md5(prosrc)` of the repo copy is `f2fb054fbf7f06943171c490abd51b5b`, 46,427 characters, equal to the pin in `bloom035_item3b_days_to_truck.sql:7`. Read 0 confirms live.
3. **The class words on the live desk are not the words in R11.** "KVI Critical, Standard, Consumable, Long tail" and "recipe, life gate, KVI floor, GMROI fill" belong to the hidden Recipe mode (`page.jsx:773-774`, `:807`, `:912`). The live desk (`OrderDesksMode`, `page.jsx:1578`) shows Tier (`:1523`), the hover story (`:1415`), the stock-now groups (`:2618-2635`) and the card words (`StoredOverview.jsx:37-40`). Section 5.5 lists the edits.
4. **The stock-now groups are set in two places.** Server: `create_rpc_bloom_stock_state.sql:144-148`. Client, for the "days after this order" figure: `page.jsx:1924-1931`. Both map the old `kvi_band = 'LONG_TAIL'` band to TAIL. That band is not the new long tail (RULED-ALREADY R11 says so). The new class code must not reuse the string `LONG_TAIL`. I use `LONGTAIL` (section 5.1).
5. **Job 26 skips DC_FRESH, and the repo function has no filter that does it.** `HANDOVER-CURRENT.md:61` says job 26 builds every desk but DC_FRESH. `rpc_bloom_desks` lists every `supplier_calendar` row of an active store (`create_rpc_bloom_desks.sql:90-125`). The untracked draft `sql/bloom035_fresh_cover_cap.sql:16` says the release step is "cron job 26 stops excluding DC_FRESH". So the exclusion is in the cron command. Read 1 shows its text. The new presets job (J-2) must use the same desk list as job 26 until DC_FRESH is released.

---

## 2. Part 1: the seven selectors

**The one path every selector takes.**

1. The page keeps `preset` (default standard, `page.jsx:1590`), `basis` (default normal, `:1587`), `fitToBudget` (default true, `:1589`), `deliveryDate` and `nextDeliveryDate` (set from the calendar, `:1706`).
2. **Generate** calls `rpc_bloom_order_cached` with store, desk, both dates, `p_preset` (NULL for standard) and `p_fit_to_budget` (`:1967-1972`). Nothing runs until the buyer presses Generate, except the basis switch, which re-seeds quantities at once (`:2142-2150`).
3. The reader matches one header on the exact key store, route, delivery date, next delivery, preset, fit (`create_bloom_order_cache.sql:283-287`). No match returns a labelled MISS and never falls through to the recipe (ENG-097, `page.jsx:1991-1999`).
4. The stored lines came from `refresh_bloom_order_cache`, which calls `rpc_bloom_order_recipe` once per key (`create_bloom_order_cache.sql:139-146`, positional insert).
5. The nightly job calls `refresh_bloom_order_cache_all`, which loops desks x fit {false, true} x presets x drops, with NULL dates (`create_bloom_order_cache.sql:413-436`).

**What the recipe does with each selector** is in the sub-sections. The recipe's format arguments are numbered: `%8` days-cover override, `%9` lead, `%10` preset, `%11` catch-up, `%13` fit, `%14` weekly budget, `%15` route, `%23` delivery date, `%24` essentials, `%27` store target days, `%28` ceiling (`recipe:976-982`).

### 2.1 Standard

| | |
|---|---|
| UI | Option at `page.jsx:1311`. `lineQty` reads `suggested_packs` for non-promo lines (`:70-74`). |
| Reader | Header preset `standard`. NULL `p_preset` maps to it (`create_bloom_order_cache.sql:286`). |
| Builder | Stores preset `COALESCE(p_preset,'standard')` (`create_refresh_bloom_order_cache.sql:70-81`). Nightly default `ARRAY['standard']` (`create_bloom_order_cache.sql:397`). |
| Recipe | `v_preset_applied` (`recipe:480`). Standard alone gets the stable 56-day demand in minimum mode (`:625-632`, label at `:944`). Standard alone gets the derived build window (`:430-446`). |
| **Changes the order as labelled today?** | **Yes**, it is the one stored preset. The build window it uses is the typed 25 (section 2.4). |
| Read-back test | Every desk has both fits stored for the next delivery. See **T-STD** below. |

```sql
-- T-STD: standard is stored for every desk (DC_FRESH is held and may be the one gap)
select count(distinct (c.store_code, c.route_key)) as desks_stored,
       (select count(*) from rpc_bloom_desks()) as desks_total
from bloom_order_cache c
where c.preset = 'standard' and c.generated_at > now() - interval '30 hours';
```

### 2.2 Order Essentials

| | |
|---|---|
| UI | Option at `page.jsx:1312`. |
| Reader | Exact key with preset `order_essentials`. **0 stored, so every Generate on this preset shows the amber MISS box** (`page.jsx:2554-2570`). |
| Builder | `refresh_bloom_order_cache` takes the preset and would store it (`create_refresh_bloom_order_cache.sql:70-81`). The nightly never asks (default presets, `create_bloom_order_cache.sql:397`). |
| Recipe | `v_preset_essentials` (`recipe:478`) becomes `%24`. HERO to max (`:681`). CORE that is KVI or on a geared promo gets its normal depth, every other CORE the **min band** (`:683-686`, reason text `:693`). No slow candidate (`:738`). Resolved quantity is the normal pack count (`:838`). Demand uses the short windows and the typed 15, 24, 25 build days, because `%10` is not standard (`:625-631`, `:639-641`, `:430-431`). |
| **Changes the order as labelled today?** | **Not on the desk** (nothing stored). In the engine it changes the order but **not as ruled**. R11 and the 12-07 ruling say only KVI, HERO and promo. Two places still give other CORE lines a pack: the min-band target (`:686`), and the 3-unit floor, whose candidates include CORE (`tf_cand`, `:778`). Build days are typed. |
| Read-back test | **T-ESS**, after the build. Expect 0 leaked lines. |

```sql
-- T-ESS: after the build, non-KVI, non-promo CORE lines carry 0 packs on Essentials
select c.store_code, c.route_key,
  count(*) filter (where l.suggested_packs > 0 and l.range_state = 'CORE'
                     and coalesce(l.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT')
                     and not l.promo_active) as leaked_core_lines,
  round(sum(l.suggested_packs * l.pack_cost)) as essentials_value
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'order_essentials' and not c.fit_to_budget
  and c.generated_at > now() - interval '30 hours'
  and coalesce(l.line_kind,'') not in ('covered','unordered')
group by 1, 2 order by 1, 2;
```

### 2.3 Catch-up

| | |
|---|---|
| UI | Option at `page.jsx:1313`. **The live desk does not force Fit on.** The old Recipe form did (`:827`, text `:837`). |
| Reader | Exact key with preset `catch_up` and whatever `fitToBudget` holds. 0 stored. |
| Builder | As Essentials. |
| Recipe | `v_preset_catchup` (`recipe:479`) becomes `%11`. CORE target is max band (`:682`). HERO is filled first, CORE ranks by KVI priority then GMROI rank (`:854-862`). The walk stops at the first of 21 store days (`%27`) or the weekly budget `%14` (`:880-892`). `fit_applied = fit OR catch-up` and the quantity ignores the fit flag (`:919-922`). |
| **Changes the order as labelled today?** | **Not on the desk** (nothing stored). In the engine the Fit switch is decoration for this preset: fit off and fit on give the same quantities. A stored fit-off header would duplicate the fit-on one. |
| Read-back test | **T-CU**. Expect reasons `catchup_priority_fill` and `catchup_below_cutoff` only, HERO whole. |

```sql
-- T-CU: catch-up reasons and value per desk (one stored variant, fit on)
select c.store_code, c.route_key, l.budget_fit_reason,
       count(*) as lines, round(sum(l.suggested_packs * l.pack_cost)) as value
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'catch_up' and c.generated_at > now() - interval '30 hours'
  and coalesce(l.line_kind,'') not in ('covered','unordered')
group by 1, 2, 3 order by 1, 2, 3;
```

### 2.4 Minimum versus Build mode

There is **no selector** for this. Mode is set per line, and the desk shows it only in the hover story ("(build mode)", `recipe:692-695`, `page.jsx:1415`). "Labelled" means the stored `mode` column and that story.

| | |
|---|---|
| Rule in the recipe | MONTH_END lines are `build` when the delivery day of month lies between the start and end days (`recipe:639`). EARLY_MONTH lines are `build` when the delivery day is 25 or later (`:640`). Everything else is `minimum` (`:641`). The delivery day is `EXTRACT(DAY FROM p_delivery_date)` (`:425`). |
| What build changes | CORE depth goes to the max band (`:688`). In standard the demand window switches from stable 56 days to the short tier windows (`:625-631`). The ENG-229 round-up applies only in minimum mode (`:730`). |
| Start and end days | Derived only for standard on DC_AMBIENT and DC_TOPS: the two last delivery weekdays before day 25 (`:430-446`). **Not** gated by `cycle_weeks`. Every other desk and preset uses the typed 15 and 24. |
| EARLY_MONTH | Typed 25 everywhere. The calendar file measured this wrong in 12 of 12 months at 80175 by 2 to 8 days, mean 5.417 (`create_calendar_events.sql:17-21`, one store, one published year). |
| Pension | Not a build window anywhere. |
| **Changes the order as labelled today?** | **It changes the order, but not as ruled.** Labels say "build" on typed days. Archetype itself is still a day-of-month bucket (`create_l2_rhythm_profile.sql:133-149`, ENG-077). That stays out of this item and is named in section 9. |
| Read-back test | **T-BUILD**: one stored build delivery and one stored minimum delivery per DC desk. Needs the delivery-date work in section 3.5. |

```sql
-- T-BUILD: mode and value by archetype on each stored delivery
select c.store_code, c.route_key, c.delivery_date, l.archetype, l.mode,
       count(*) as lines, round(sum(l.suggested_packs * l.pack_cost)) as value
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.route_key in ('DC_AMBIENT','DC_TOPS')
  and c.generated_at > now() - interval '30 hours' and l.line_kind = 'ordered'
  and l.archetype in ('MONTH_END','EARLY_MONTH')
group by 1, 2, 3, 4, 5 order by 1, 2, 3, 4, 5;
```

### 2.5 Normal versus Geared

| | |
|---|---|
| UI | Control at `page.jsx:2449-2450`. `lineQty` (`:70-74`): a promo line takes `geared_packs` or `normal_packs` by basis. Any other line takes `suggested_packs`. Generate seeds it (`:2018-2020`). The switch re-seeds untouched lines (`:2142-2150`). Per-row N and G select at `:1563-1571`. |
| Stored columns | `normal_packs = normal_packs_calc` (`recipe:953`). `geared_packs` is the geared count, or the normal count on a closing-week promo line (`:956`). Both are **before the fit**. `suggested_packs` is after the fit (`:957`). |
| **Changes the order as labelled today?** | **Yes for the basis, no for the fit on promo lines.** Under either basis a promo line shows a pre-fit number, so the Fit switch never moves a promo line on the desk. The engine fits it (`final_packs`, `:921-926`) and the desk ignores that. The Running total (`:2132`) and the Fit strip (`:2525`) therefore leave promo lines out of the fit. This is a gap in R5, not a ruled behaviour. It is a pivot (section 7, Q10). |
| Read-back test | **T-GEARED** gives the page total to the rand for both bases. **T-FITPROMO** counts promo lines where the fit moves the engine's number and not the desk's. |

```sql
-- T-GEARED: the page total (page.jsx:70-74, 2132) for Normal and for Geared, per stored variant
select c.store_code, c.route_key, c.preset, c.fit_to_budget,
  round(sum(case when l.promo_active then l.normal_packs else l.suggested_packs end * l.pack_cost), 2) as page_total_normal,
  round(sum(case when l.promo_active then coalesce(l.geared_packs, l.normal_packs) else l.suggested_packs end * l.pack_cost), 2) as page_total_geared
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.generated_at > now() - interval '30 hours' and coalesce(l.line_kind,'') not in ('covered','unordered')
group by 1, 2, 3, 4 order by 1, 2, 3, 4;
```

```sql
-- T-FITPROMO: promo lines where the fit changes the engine's number (the desk shows the pre-fit number either way)
select c0.store_code, c0.route_key,
  count(*) filter (where l1.promo_active) as promo_lines,
  count(*) filter (where l1.promo_active and l1.suggested_packs <> l0.suggested_packs) as promo_fit_moves_engine,
  count(*) filter (where not l1.promo_active and l1.suggested_packs <> l0.suggested_packs) as other_fit_moves
from bloom_order_cache c0
join bloom_order_cache c1 on c1.store_code = c0.store_code and c1.route_key = c0.route_key
  and c1.delivery_date = c0.delivery_date and c1.next_delivery = c0.next_delivery
  and c1.preset = c0.preset and c1.fit_to_budget and not c0.fit_to_budget
join bloom_order_cache_line l0 on l0.cache_id = c0.cache_id
join bloom_order_cache_line l1 on l1.cache_id = c1.cache_id and l1.product_code = l0.product_code
where c0.preset = 'standard' and c0.generated_at > now() - interval '30 hours'
  and l0.line_kind = 'ordered' and l1.line_kind = 'ordered'
group by 1, 2 order by 4 desc limit 15;
```

### 2.6 Fit to budget

| | |
|---|---|
| UI | Switch at `page.jsx:2454`, default On (`:1589`). It picks the stored header (`:1971`). Fit strip `:2524-2526`, over-rail notice `:2530-2539`, no-ledger-row warning `:2541-2548`. |
| Recipe | `%13` fit, `%14` the remaining need of the budget weeks the delivery covers (`recipe:485-490`, item 2). HERO and KVI whole, one-pack floors kept, the rest funded in GMROI order until the money is gone (`:893-936`). |
| Builder | Stores both fits for every desk (`create_bloom_order_cache.sql:422`). |
| **Changes the order as labelled today?** | **Yes at the stored level.** Gaps: (a) promo lines on screen (section 2.5), (b) Catch-up ignores it (2.3), (c) a desk with no ledger row prices against R0 and the fit trims everything (`recipe:475`, warning at `page.jsx:2544-2546`, read 18 lists them), (d) protected lines can exceed the need, the open item 2 question in `HANDOVER-CURRENT.md:54`. |
| Read-back test | T-FITPROMO above, and the item 2 read-back for (d). |

### 2.7 Delivery date

| | |
|---|---|
| UI | A free date input (`page.jsx:2435`) and a second one for the following delivery (`:2440`). Both start from `rpc_bloom_next_deliveries` (`:1701-1707`). |
| Reader | **Exact pair or MISS** (`create_bloom_order_cache.sql:283-287`). The MISS lists up to 12 cached pairs from yesterday on (`:288-297`). |
| Builder | **One pair per desk per night.** `p_drops` defaults to 1 and the loop passes NULL dates, so `drop_n` is never used (`create_bloom_order_cache.sql:397`, `:424`, `:431-436`). The comment says later drops are "not requested". |
| What the date drives in the recipe | Build state (`:425`, `:639-640`), promo membership and gearing (`:665`, `:675`), counted in-transit (`:722`), the budget week (`:458`), the drop gap `v_lead = next - delivery` (`:450`). The days from the stock reading to the truck are **not** modelled (item 3b, written and not applied). |
| **Changes the order as labelled today?** | **Only for the one stored pair.** Any other date returns the amber MISS. The picker is a free date, so the label promises more than it delivers. |
| Read-back test | **T-DATE** after multi-drop storage (section 3.5). |

```sql
-- T-DATE: each stored delivery, its lead and its budget week
select c.store_code, c.route_key, c.delivery_date, c.next_delivery, c.preset, c.fit_to_budget,
       bool_and(l.lead_days_used = c.next_delivery - c.delivery_date) as lead_equals_drop_gap,
       min(l.budget_week_source) as week_source, min(l.budget_week_start) as week_start
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.generated_at > now() - interval '30 hours' and l.line_kind = 'ordered'
group by 1, 2, 3, 4, 5, 6 order by 1, 2, 3, 5, 6;
```

### 2.8 The acceptance matrix (R5: one DC and one direct desk per store)

Pick the desks with read 11. Then, per desk, per stored variant, this one query is the value change by name.

```sql
-- T-MATRIX: value and lines by preset and fit, one row per stored variant
select c.store_code, c.route_key, c.delivery_date, c.preset, c.fit_to_budget,
       count(*) filter (where l.suggested_packs > 0) as lines,
       round(sum(l.suggested_packs * l.pack_cost)) as value
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.generated_at > now() - interval '30 hours'
  and (c.store_code, c.route_key) in (/* the ten desks from read 11 */ ('10116','DC_AMBIENT'))
  and coalesce(l.line_kind,'') not in ('covered','unordered')
group by 1, 2, 3, 4, 5 order by 1, 2, 3, 4, 5;
```

Then read the same desks in Pieter's Chrome as page text (R31, click by DOM, restore his filters). The Running total on the page must equal `page_total_normal` or `page_total_geared` from T-GEARED to the rand.

---

## 3. Part 2: store Order Essentials and Catch-up nightly for every desk

### 3.1 What changes

| # | Object | Change | Anchor in the live body (take it from `pg_get_functiondef`) | Count |
|---|---|---|---|---|
| J-1 | `refresh_bloom_order_cache_all` | Catch-up gets one fit only. Add to the loop filter: `AND (pr.preset <> 'catch_up' OR f.fit)`. Signature `(text[], text[], integer)` does not change. | `     WHERE p_routes IS NULL OR d.route_key = ANY(p_routes)` (repo copy `create_bloom_order_cache.sql:425`) | 1 |
| J-2 | cron | **A new job**, not a wider job 26. Name `bloom-order-cache-presets`, command `SELECT public.refresh_bloom_order_cache_all(NULL, ARRAY['order_essentials','catch_up']);`. Copy job 26's ceiling pattern from read 1. | n/a | n/a |
| J-3 | `rpc_bloom_stored_overview` | Catch-up has one stored variant, so its card loop must not ask for fit off. `FOREACH v_fit IN ARRAY (CASE WHEN v_preset = 'catch_up' THEN ARRAY[true] ELSE ARRAY[false, true] END) LOOP`. The function already takes `p_preset` (`create_rpc_bloom_stored_overview.sql:36`). | `  FOREACH v_fit IN ARRAY ARRAY[false, true] LOOP` (`:85`) | 1 |
| U-1 | `page.jsx` | Pass `p_preset` to the overview (`:1793-1796`) and add `preset` to the effect dependencies (`:1806`). | `p_delivery_date: deliveryDate, p_next_delivery: nextDeliveryDate,\n    }).then(({ data, error: err }) => {\n      if (cancelled) return\n      setStoredOverviewLoading(false)` | 1 |
| U-2 | `page.jsx` | Choosing Catch-up sets Fit On and locks the switch with a note, as the old form did (`:827`, `:837`). | `<SegmentedControl size="sm" value={preset} onChange={setPreset} options={DESK_PRESET_OPTIONS} />` (`:2445`) | 1 |
| U-3 | `page.jsx` and the reader | The MISS text says "The nightly rebuild runs 01:30 SAST" (`page.jsx:2567`, `create_bloom_order_cache.sql:335`). Say the second job's time for the two presets. | the two strings | 1 each |
| U-4 | `StoredOverview.jsx` | Drop "get no card until they are stored" (`:11-12`, `:180`). | the two comments | 1 each |
| B-1 | `refresh_bloom_order_cache`, STEP 3b | Append the E1 unordered rows on preset standard only. They are the same on every variant and the reader withholds them (`bloom035_e1_cache_rows.sql:84-103`). Add `AND COALESCE(p_preset,'standard') = 'standard'` to the STEP 3b select. My default. It saves rows (section 3.2). | `   WHERE rp.store_code = p_store_code AND rp.desk_route_key = p_route AND rp.state = 'DESK'` (`bloom035_e1_cache_rows.sql:55`) | 1 |

**Nothing changes in the recipe for part 2.** The reader needs no change: it already takes `p_preset`.

### 3.2 Row count and run time

**Combinations.** Tonight: 280 (140 desks x 2 fits, `HANDOVER-CURRENT.md:62`). With Essentials (2 fits) and Catch-up (1): +280 +140, **700 combinations, 2.5 times tonight's.** The 280 is the size of the R22 fingerprint set. The desk list should be about 140 to 143: 20 hand-typed desks, 119 derived desks (`HANDOVER-CURRENT.md:54`), 2 catch-all desks, and DC_FRESH once job 26 builds it. I did not reconcile the exact figure. Read 5 counts it live.

**Measured, and its scope.** On 19-08 a DC combination cost 21.2 seconds (10 DC combinations, 212,334 ms) and one direct desk of 24 lines cost 7.5 seconds. The 40-combination run was about 7.3 minutes (`create_bloom_order_cache.sql:383-389`). Those are two August observations on a smaller pool. They are not a law for today.

**Estimate, labelled as one.** With about 12 DC combinations at 21 to 44 seconds and about 268 others at about 7.5 seconds, tonight's job 26 is **about 36 to 46 minutes**. Three presets in one job: **about 90 to 115 minutes.** Read 2 and read 3 replace this guess with last night's span and per-class time. A cost that grows with the combination count assumes the same per-call cost on every preset. The recipe runs the same CTE chain for each preset, so I expect that, and the dry run in 3.4 measures it.

**Rows.** Ordered rows were about 3,489 across 20 desks per variant on 02-09 (`create_rpc_bloom_order_recipe.sql:70-75`). The E1 unordered rows were about 12,589 across all stores on 13-10 (RULED-ALREADY R7). So one variant is **tens of thousands of rows, not millions**, and the unordered rows dominate. With B-1 the three new variants add ordered and hidden rows only. Without B-1 they repeat 12.6k rows each. Read 6 gives the table size and the retention.

### 3.3 The risk to the 23:30 UTC window

1. **One transaction.** `refresh_bloom_order_cache_all` is one function call, so one transaction. A ceiling hit late in a 100-minute run rolls back the whole night, standard sheets included. A second job keeps the standard sheets safe. The ceiling that binds is the one on the cron command or the role. The `SET LOCAL statement_timeout` inside the functions (`create_bloom_order_cache.sql:106`, `:411`, `recipe:359`) does not bind (CC memory note reference_pg_bound_and_estimate_traps: an in-body SET LOCAL is decorative, proven on 23 functions).
2. **Start time of the second job.** Put it after job 26 ends, with a gap. Rule: start = the later of 01:30 UTC and (job 26 start + measured span from read 2 + 30 minutes). Today that points at 01:30 UTC (03:30 SAST), after the closed window of 22:00 to 03:00. If the second job runs about an hour, the two presets land at about 04:30 to 05:00 SAST. Confirm that is before the buyers open the desk. I do not know their start time.
3. **Neighbours.** Job 54 (desks, fresh desk, placement) runs 23:00 UTC and feeds STEP 3b (`HANDOVER-CURRENT.md:61`). Job 10 (sparkline) has 423 s against a 600 s ceiling (`SB-PM-CLOSE...md:201`). Neither may overlap job 26. Read 1 shows the real minutes.
4. **Delete cost.** Each combination deletes its old header and the cascade removes its lines (the DELETE at `create_bloom_order_cache.sql:123-126`, `ON DELETE CASCADE` at `:73`). 700 deletes of sheets of that size write a lot of dead rows. Read 6 sizes the table. If it is large, vacuum pressure is the next risk. I have not measured it.
5. **Failure of one preset on one desk type.** Essentials and Catch-up have never run on DC_FRESH, DIRECT_CATCHALL or a derived DIRECT_S desk. The per-desk EXCEPTION block keeps the night alive and records the error (`create_bloom_order_cache.sql:443-449`). The dry run in 3.4 finds it first.
6. **Option, not a need:** a PROCEDURE that commits after each desk. It gives partial progress on a failure. It is a new object with its own name, so no overload risk. Skip it unless read 2 shows the two jobs together near their ceilings.

### 3.4 Steps

1. Re-sync the cache builder and `_all` sources from live (hash-gated). Read 0 first, overloads first.
2. Write J-1 to J-3, U-1 to U-4 and B-1 as asserted replaces. One count assertion per anchor.
3. In the 20:00 to 22:00 window, dry-run each preset on four desks: one DC, one brand desk, DIRECT_CATCHALL, one derived DIRECT_S. Call `refresh_bloom_order_cache(store, route, NULL, NULL, 'order_essentials', true, 'item4_dryrun')` and the same for `'catch_up'`. These write real header and line rows, so tag the source and delete those headers after the read, so the desk never serves half a set of presets. Note the time of each call. Stop by 21:45 so nothing runs at 22:00. Jobs 72 to 76 already use the window (`HANDOVER-CURRENT.md:61`), so stagger.
4. Apply J-1 to J-3 and B-1 outside 22:00 to 03:00 and outside job 26. Schedule J-2.
5. Next morning: read 4 (the presets are stored), T-ESS before the 4b change (record the leaked count as the BEFORE), T-CU, T-MATRIX.
6. Push the UI commit. Read it back in Chrome.

---

### 3.5 The delivery date selector needs more than one stored delivery

This is part of "every selector works" and it is the largest cost lever, so it is its own section.

- **Today** one pair per desk (2.7).
- **What it needs.** `refresh_bloom_order_cache_all` must pass the n-th pair to `refresh_bloom_order_cache` for drop n. The builder already accepts explicit dates (`create_refresh_bloom_order_cache.sql:55-60`).
- **The pair walk.** One home: a function `rpc_bloom_delivery_pairs(store, route, n)`. Drop 1 is the pair `rpc_bloom_next_deliveries` offers. Drop k+1 continues from delivery k with the same weekday and cycle-week test (`create_rpc_bloom_next_deliveries.sql:76-94`). Nothing hand-typed.
- **Cost.** Linear in n. At n = 2 the standard job doubles. Read 20 gives the deliveries per week per desk (a DC desk may deliver up to six days).
- **What the stored orders mean.** Each stored delivery is the order to place for that delivery on today's stock, as if it were the first order. Two stored drops are not additive. The weekly verdict (item 9) already adds later drops (`create_rpc_bloom_stored_overview.sql:179-198`). That interplay is item 9's, and I name it so nobody reads two drops as one purchase.
- **Dependency.** The delivery-date read-back is honest only after item 3b, which models the days to the truck.
- **PM rules the number of drops** (Q9). Default: 2 (this delivery and the one after), derived from the calendar, not typed per desk.

---

## 4. Part 3: the pension build

### 4.1 Where the income dates are

| Fact | Where | Rows today |
|---|---|---|
| Pension window | `public.calendar_events`, columns `event_type`, `event_stream`, `event_date`, `is_non_trading` (`create_calendar_events.sql:25-44`). Rows with `event_type = 'SASSA_PAYMENT'`, streams OLDER_PERSONS, DISABILITY, CHILDREN and one REVIEWS row (`:81-106`). | 37 rows, 02-04-2026 to 04-03-2027 (SB-AUD-RHYTHM-001 section 4, read 03-09). Read 8 re-counts. |
| Window start | The earliest `event_date` of the calendar month. For November 2026 that is OLDER_PERSONS 03-11-2026, then DISABILITY 04-11, CHILDREN 05-11 (`create_calendar_events.sql:91`). | |
| Public holidays | The same table, `is_non_trading = true`, 12 rows, 2026 only (`:63-76`). | None for 2027. |
| Payday (the 25th) | **Not in the table.** The `event_type` list allows `PAYDAY` (`:39`) and no rows exist. The 25th lives only as `forge_config month_end_build_anchor_dom` (`2026-08-13_bloom_recipe_eng083_v16.sql:33-36`). | 0 rows. Read 8 confirms. |
| Route delivery days | `supplier_calendar`: `delivery_dows` (ISO weekday array), `cycle_weeks`, `cycle_anchor_week_start`, `order_cutoff_days` (read at `recipe:418`, `rpc_bloom_next_deliveries:59-62`). | One row per desk. |

### 4.2 How the last delivery before a window is derived

`rpc_bloom_next_deliveries` already does it for the next window (`:115-127`): start at window start minus one day, walk back one day at a time to the first date whose ISO weekday is in `delivery_dows` and whose cycle week passes the test (`:121-124`). It stops after 60 days. It answers only for the window after the anchor, so the recipe cannot call it for an arbitrary delivery date.

**The generalised rule, in one new read function** `rpc_income_build_state(p_store_code, p_route, p_delivery_date)`:

1. **Deliveries.** The route's delivery dates in a band of +-45 days around the delivery date: weekday in `delivery_dows` and the same cycle-week test as `rpc_bloom_next_deliveries:117-124`.
2. **Pension window.** For each calendar month, W = the earliest `SASSA_PAYMENT` date. The next window after the delivery date D is the smallest W with W > D.
3. **Payday.** P = the 25th of the month, moved back to the nearest earlier day that is not a Saturday, a Sunday or `is_non_trading`. The next P with P > D. R2 tested the weekend move only (Q16 asks about a holiday).
4. **Build deliveries.** For a window start X, the last N deliveries strictly before X are the build deliveries (N from `forge_config income_build_drops`, default 2, see Q8). D is a build delivery when it is among them.
5. **First minimum delivery.** The first delivery after the last build delivery. It gets mode minimum. No other rule (Pieter: "the first minimum band", and BLOOM-035 4b: the order after the build has "no rule of its own").
6. **Return** `payday_build`, `pension_build`, `first_minimum`, the dates used, `pension_kept` and a `state` string.

**Worked example (my reading, derive it live with read 10).** 25-10-2026 is a Sunday. The payday moves to Friday 23-10-2026. The old typed rule counts days of month below 25, so a Saturday delivery on 24-10 counts as a build day. The derived rule needs the delivery strictly before 23-10. The pension window for November starts Tuesday 03-11-2026. The last delivery before it is Monday 02-11 if the desk delivers on Mondays. The old typed rule builds EARLY_MONTH lines on every delivery from the 25th, so about a week earlier than the new rule.

### 4.3 What replaces the typed day 25

| Typed source | Becomes |
|---|---|
| `month_end_build_anchor_dom` read in the recipe (`:432-433`) | Stays in `forge_config` as the **input of the payday loader only**. The recipe stops reading it. Retire the recipe read with a date and a successor (R28). |
| `p_early_month_build_start_day` default 25 (`:328`, `:363`) and the 15 and 24 fallbacks (`:361-362`) | Stay in the signature (no overload risk) and become unused. The two outside callers that pass 15, 24, 25 keep working, ignored. Say so in the header. |
| The derive block (`:430-446`, 17 lines) | One call: `SELECT payday_build, pension_build INTO v_pay_build, v_pen_build FROM rpc_income_build_state(p_store_code, p_route, p_delivery_date)`. For **every preset and every route that has a calendar row**. This also fixes the missing `cycle_weeks` test. |
| Four conditions (`:626`, `:627`, `:639`, `:640`) | MONTH_END lines read `v_pay_build`. EARLY_MONTH lines read `v_pen_build` where the store keeps the pension cycle, otherwise `v_pay_build` (Q7). |
| Loaded dates | **A loader** `refresh_calendar_paydays(p_from, p_to)` writes `PAYDAY` rows into `calendar_events` (scope country, source text naming the rule and R2's weekend test). Canon section 16.2 says dates are loaded, never coded, and a row without a source is not loaded (`create_calendar_events.sql:22`). It is idempotent. Run it for 01-2025 to 12-2027. |

### 4.4 Stores where R2 shows no uplift

R2 (RULED-ALREADY lines 125-137, 6 cycles, 04-2026 to 09-2026): pension days 0 to 3 were up in 6 of 6 at 10116, 6 of 6 at 80175, 5 of 6 at 80579, 3 of 6 at 21355 and 2 of 6 at 80176. Brief: "kept only where its cycles show an uptick (today 10116, 80175 and 80579)".

- **The flag is not mine to invent.** It comes from item 3's rhythm index, per store, re-tested as cycles accrue and never typed. Item 3 names the table. I call it `pension_kept` here. Until item 3 lands, `rpc_income_build_state` returns `pension_kept = false` with state `PENSION_FLAG_MISSING`. It never guesses.
- **At a kept store:** EARLY_MONTH lines build on the pension build delivery. MONTH_END lines build on the payday build delivery.
- **At a store without the uplift:** there is no pension build. The month is one U from payday to the first week of the next month at all five stores (RULED-ALREADY line 140). My default is that EARLY_MONTH lines build on the payday build delivery there. The other reading is no build at all for them, which removes a build they get today. **Q7 is a pivot.**
- **When the calendar runs out.** The SASSA rows end 04-03-2027. Past that, `state = 'income calendar ends 2027-03-02 ...'`, `pension_build = false`, and the desk strip already says "Pension timing unavailable" (`page.jsx:2509-2514`). The payday cycle still works, because the loader needs no outside schedule. PM owns the 2027/28 load (Q14).

### 4.5 The order after the build

No rule of its own (BLOOM-035 4b). It comes out smallest when item 3 scales the covered days. **Interplay to watch, not decided here.** After item 3 the minimum band already carries the week's index. Build mode then takes the max band and the short demand window on top. That may count the uplift twice. Default: ENG-083's build depth stays as ruled. The read-back says whether the first delivery after the build at 10116 is the lowest of the month (Q15).

### 4.6 Read-back

1. `rpc_income_build_state` for the five DC desks and one direct desk per store over 01-10-2026 to 31-12-2026: one row per delivery, old rule and new rule side by side. A SQL for this goes with the apply file.
2. A pg_temp copy of the new recipe run for the next 14 drops at 10116 and 80175 DC. The diff against live must sit only on MONTH_END and EARLY_MONTH lines on the dates where the old and new rules disagree.
3. T-BUILD on the first natural build delivery (the one on or before Thursday 22-10-2026 for payday if the desk delivers that day, and the one on or before Monday 02-11-2026 for the pension window). Read 10 gives the actual dates.

---

## 5. Part 4: item 4b, depth by class

### 5.1 The class fact (one home)

**Why a table.** The long tail needs a ranking per store and desk, derived nightly (R21). A recipe or a card that ranks it again is a second home (R33). So: one table, one refresh function, three readers (recipe, stock state, cache builder).

**Table** `public.l2_order_class` (store_code, route_key, product_code) primary key. Columns: `order_class`, `class_reason`, `places` (the desk's long-tail size), `place_rank`, `takes_place`, `fill_source`, `gmroi`, `soh`, `first_sale_date`, `anchor_date`, `computed_at`. Grants: read for anon and authenticated, **REVOKE ALL FROM PUBLIC, anon, authenticated first, and revoke the default MAINTAIN right** (CC memory note reference_pg_public_grant_revoke_trap: a new public table takes `anon=rm` by default). RLS with one read policy.

**Class codes:** `KVI`, `HERO`, `NEW`, `CORE`, `TAIL`, `LONGTAIL`, `BELOW_GATE`. The code is `LONGTAIL`, not `LONG_TAIL`, because the string `LONG_TAIL` already means a different band in `kvi_band` and in the page (`page.jsx:774`, `:1929`).

**Precedence, first match wins:**

| Order | Class | Rule |
|---|---|---|
| 1 | KVI | `kvi_band` is KVI_CRITICAL or KVI_IMPORTANT |
| 2 | HERO | `range_state = 'HERO'` |
| 3 | NEW | first till sale within `new_line_settling_days` (91) of the store watermark. **Read the test from item 5's definition**, `l2_range_state.first_sale_date`, never a second test (`scratch/plans/item5_new_lines.md` section 3.3 groups A and C, its Q10 and risk 12). |
| 4 | LONGTAIL | in the nightly long-tail set (5.1.1) |
| 5 | TAIL | `range_state = 'CORE'` and `tier = 'BOR'`, not above |
| 6 | CORE | `range_state = 'CORE'` |
| 7 | BELOW_GATE | SLOW, MARKDOWN, DERANGE, VERIFY not in the long tail. No change to their order logic. |

**5.1.1 The long-tail set, per store and desk (R11, Pieter 22:0x).**

- **Places** = the number of NEW lines on the desk (ENG-235: 261 at 10116 DC ambient).
- **Pool** = `l2_population_verdict` rows with `route_key` = the desk. For a DC desk also `department_nr` in the desk's department set, the same pool ENG-235 used (12,876 lines, `BUG-LOG.md:3167`). The department-set helper from item 1b phase 0 is named `bloom_desk_dept_nrs` in `bloom035_1b_dc_fresh_phase0.sql`'s reverse note. I did not read its signature. Read it live.
- **Never in it:** KVI, HERO, NEW.
- **Fill order:**
  1. Lines with no till sale in 91 days that hold stock (`soh > 0`). 207 at 10116 DC ambient.
  2. Selling lines with a GMROI row and a neighbouring EAN, lowest GMROI first. 54 places, cut-off 0.0190.
  3. Single variants last.
- **No place:** lines with no sale and no stock are class LONGTAIL with `takes_place = false`. 6,722 at 10116 DC ambient.
- **No GMROI row:** not ranked.
- **Neighbour test.** Another selling line at the store sharing the first 11 digits of the EAN, from `l2_export_key.export_key` (`BUG-LOG.md:3167`). **Use only real 13-digit keys** (`key_source = 'BRIDGE_EAN13'`, `create_l2_export_key.sql:52`). A manufactured key is the store code and an 8-digit product code (`recipe:940`). Two codes within the same hundred share their first 11 digits. That would create neighbours that do not exist. Read 15 counts the key sources. Q5.
- **Negative GMROI.** 12 selling lines at 10116 carry a negative GMROI, the lowest -6,119, a cost-scale artefact (ENG-235, `BUG-LOG.md:3182`). They would take the first places. Q6.
- **Ties** among non-sellers that hold stock: capital value at cost, highest first (my default, Q4).

**5.1.2 Where it runs.** `refresh_l2_order_class(p_store)`, called **at the top of `refresh_bloom_order_cache_all`** for each active store, before the desk loop. Not inside `refresh_l2_pipeline`. Reason: job 15 failed four times in a row on 13-10 (`BUG-LOG.md:3192`) and changed again today (ENG-236 option H, `create_refresh_l2_pipeline.sql:48-63`). The class reads what the pipeline wrote three hours earlier (population verdict, GMROI, export key, range state, `first_sale_date`). The leg is one scan of the 91 days of till sales per store. Time it in the dry run. Add it to the anchor `  SET LOCAL statement_timeout = '0';   -- a background builder is not on a request thread` (`create_bloom_order_cache.sql:411`, count 1).

**Config.** `temp_floor_units_tail` = 2 (DEMO_CALIBRATION, SEED, UNDERIVED, Pieter 13-10 21:07), a **new key**, so the 3-unit floor for HERO and CORE does not move (Q1). `new_line_settling_days` = 91 comes from item 5. The recipe reads each key and, when the tail key is absent, falls back to `temp_floor_units`. The key exists and holds a value before the recipe reads it (the config-key gate, §0h).

### 5.2 Class by preset: the grid I would build to

| Class | Standard | Essentials | Catch-up |
|---|---|---|---|
| KVI | Next delivery plus 4 or 2 days. Unchanged. | Same depth as Standard. | Ranked first after HERO, to max band. |
| HERO | Max band. | Max band. | Filled first. |
| NEW | Unchanged until item 5. | Min band (item 5 Q5). | Left out of the walk (item 5 Q5). |
| CORE | Min band, max in build mode. Unchanged. | **0** unless promo. | Max band, GMROI order. |
| TAIL | **One case when the position is 2 or fewer, else 0.** The 28-day pack test stays (Q2). | 0. | Same as Standard (Q11). |
| LONGTAIL | 0, on the sheet, no pack test, no floor. | 0. | 0. |
| BELOW_GATE | Unchanged. | Unchanged. | Unchanged. |

### 5.3 The ordered edit list against the recipe

**Rules for every edit.** Asserted replace on `pg_get_functiondef`, one count assertion per anchor, pin on `md5(prosrc)` taken at apply time. Insert after or before an anchor line and never rewrite an anchor that another plan uses (item 5's B-2, B-3, B-5, B-7, `scratch/plans/item5_new_lines.md:129-140`). Recipe output columns do **not** change. The cache table inserts the recipe's 77 columns positionally with `generated_at` as column 80 (`create_bloom_order_cache.sql:139-146`). One more column in the recipe would shift it. The class travels in `mode_reason` and the story, and as a column the builder writes after the recipe (5.4).

Counts below are the occurrences in the repo recipe body (CRLF stripped, md5 equal to the pin). Line numbers are file lines.

| # | Edit | Anchor (exact text) | File line | Count |
|---|---|---|---|---|
| R-1 | Declare `v_tf_tail_units numeric;` | `  v_tf_pack_days numeric;\nBEGIN` | 357-358 | 1 |
| R-2 | Read `temp_floor_units_tail`, fall back to `v_tf_units` when no row | `  IF v_tf_units IS NULL OR v_tf_pack_days IS NULL THEN\n    v_tf_units := -1000000000; v_tf_pack_days := 0;\n  END IF;` | 379-381 | 1 |
| R-3 | Pool carries the class and its reason: end the column list with `, oc.order_class AS order_class, oc.class_reason AS order_class_reason` | `        COALESCE(rop.unit_incommensurable, true) AS unit_incommensurable\n      FROM l2_stock_band b` | 551-552 | 1 |
| R-4 | `LEFT JOIN l2_order_class oc ON oc.store_code = b.store_code AND oc.route_key = %15$L::text AND oc.product_code = b.product_code`. No row means no change. | `      LEFT JOIN l2_bloom_promo_pantry pmp ON pmp.store_code=b.store_code AND pmp.product_code=b.product_code\n      WHERE b.store_code=%1$L` | 562-563 | 1 |
| R-5 | New format argument for the tail units, next free number (33 after 3b, higher after item 3) | after 3b: `v_relevant_min_cover_days, v_tf_units, v_tf_pack_days, v_days_to_truck);`. Before 3b: `v_relevant_min_cover_days, v_tf_units, v_tf_pack_days);` | 982 | 1 |
| R-6a | **Need is 0** for TAIL, LONGTAIL and, in Essentials, CORE that is not KVI, not on promo and not NEW. Add a `WHEN ... THEN 0` line **after** the guard line and keep the guard line text whole. TAIL lines on promo are exempt (Q3). "Promo" means `promo_active` (Q18). | `(CASE WHEN t.range_state NOT IN ('HERO','CORE') THEN 0` | 714 | 1 |
| R-6b | The same for the geared (promo) branch | `(CASE WHEN wg.range_state NOT IN ('HERO','CORE') THEN 0` | 810 | 1 |
| R-7 | `min_presence_forced0` must not fire for TAIL or LONGTAIL (it is independent of the pack count, and the flag keeps a row on the sheet): `AND COALESCE(m.order_class,'') NOT IN ('TAIL','LONGTAIL')` | `((m.mp_life OR (m.slow_candidate AND m.pack_relevant)) AND m.first_pack_over_ceiling) AS min_presence_forced0,` | 750 | 1 |
| R-8 | LONGTAIL gets no 60-day pack test and no keep-or-delist flag: add `AND COALESCE(p.order_class,'') <> 'LONGTAIL'` before `) AS slow_candidate,` | `AND NOT %24$L::boolean AND NOT %11$L::boolean) AS slow_candidate,` | 738 | 1 |
| R-9 | The floor: units by class, no floor for LONGTAIL, none for non-KVI non-promo non-NEW CORE in Essentials. Replace the one line with three `AND` lines. | `AND c0.proj <= %30$s` | 780 | 1 |
| R-10 | Only if Q2 is answered "no pack test for the tail": `tf_pack_hit` and `tf_delist` skip the test when `d.order_class = 'TAIL'`. Default: **not edited.** | the two lines `COALESCE(d.tf_cand AND d.ps / NULLIF(d.ros_final,0) <= %31$s, false) AS tf_pack_hit,` and `... >  %31$s, false) AS tf_delist` | 774, 775 | 1 each |
| R-11 | Essentials reason text: `' (essentials: min-band presence only)'` becomes words that say KVI, HERO and promo only | `' (essentials: min-band presence only)'` | 693 | 1 |
| R-12 | Each row's story names its class. Prefix `COALESCE('class ' \|\| w.order_class \|\| ', ', '')` to both branches of the reason, and add the class reason for TAIL and LONGTAIL. `mode_reason` is part of the story already, so **the story format and its argument list stay untouched.** | `'range_state=' \|\| w.range_state` | 692, 696 | **2** |
| R-13 | **Pension build:** replace the derive block with the call to `rpc_income_build_state`, for every preset and route with a calendar row (section 4.3) | the 17-line block starting `  IF p_route IN ('DC_AMBIENT','DC_TOPS') AND COALESCE(p_preset,'standard')='standard'` | 430-446 | 1 |
| R-14 | The four conditions read the two booleans (format arguments after R-5) | `(g.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s)` 626, `(g.archetype = 'EARLY_MONTH' AND %4$s >= %7$s)` 627, `WHEN d.archetype = 'MONTH_END' AND %4$s BETWEEN %5$s AND %6$s THEN 'build'` 639, `WHEN d.archetype = 'EARLY_MONTH' AND %4$s >= %7$s THEN 'build'` 640 | 626, 627, 639, 640 | 1 each as written. The bare fragments `%4$s BETWEEN %5$s AND %6$s` and `%4$s >= %7$s` occur twice each, so do not anchor on them. |
| R-15 | Leave `%5`, `%6`, `%7` and their arguments in place, unused | `COALESCE(v_build_start_dom, p_month_end_build_start_day), COALESCE(v_build_end_dom, p_month_end_build_end_day), p_early_month_build_start_day,` | 977 | 1 |

**Not edited, on purpose:** the signature and `RETURNS TABLE` (77 columns), the two final row filters (`:996`, `:1096`, count 2, item 5's B-8 owns them), `depthed.target_level_v10` (`:681-690`, item 5's B-1 owns line 681), `pack_forced_review` (`:748`, needs a pack count of 1 or more, which R-6a removes), the STEP 1 positional insert.

**Collision table with item 5.** Item 5 anchors on lines 681, 714, 736, 755, 775, 778, 810, 996, 1096. Mine touch 714 and 810 by insertion after the line (their anchor text stays once), 750 and 780 (not theirs), 738 (they leave it alone), 692 and 696 (they leave alone). R-10 would collide on 775, which is why it is off by default. One seat applies both. Whoever applies second re-reads the live body and re-counts.

**Collision with the fresh cover cap.** The untracked draft `sql/bloom035_fresh_cover_cap.sql` (16:34 today, PM section 30) also edits the recipe, on the same pin `f2fb054f`. It rewrites the three-line `CASE WHEN %10$L = 'standard' AND NOT (...) THEN GREATEST(` block at lines 625-628, puts a `WHEN %15$L = 'DC_FRESH' THEN 'minimum'` line above the anchor at 639, and edits `review_days_ot` at 649 (`bloom035_fresh_cover_cap.sql:44-60`). My R-14 anchors are the inner fragments at 626 and 627 and the whole lines 639 and 640. Its edit keeps all four strings, each once, so R-14 still counts 1 after it lands. The reverse also holds: R-13 and R-14 do not touch its anchors. Whichever lands first moves the pin, so take the pin at apply time.

**Why each edit is needed (the chain I traced).** Without R-6a a TAIL line orders at its min band and the floor adds nothing. Without R-7 a TAIL or LONGTAIL line that is below its min band and over the ceiling carries `min_presence_forced` with 0 packs, prints MIN_PRESENCE in the story and stays on the sheet for the wrong reason. Without R-8 a selling LONGTAIL line that is SLOW gets one pack from the 60-day test. Without R-9 the floor tops up an Essentials CORE line and a LONGTAIL line.

### 5.4 The cache builder

Anchors come from the live body. The repo archive copy shows them for orientation (`sql/_archive/refresh_bloom_order_cache_pre_e1.sql`).

| # | Edit | Where | Count |
|---|---|---|---|
| C-1 | **STEP 1b**, right after the positional insert: `UPDATE bloom_order_cache_line SET order_class = oc.order_class, line_kind = CASE WHEN oc.order_class = 'LONGTAIL' THEN 'long_tail' ELSE line_kind END FROM l2_order_class oc WHERE ...`. It must run **before** the `covered` tag, which takes only `line_kind = 'ordered'` (archive `:117-133`) and would otherwise hide a CORE line that became long tail. | after `  GET DIAGNOSTICS v_n = ROW_COUNT;` (archive `:53`) | 1 |
| C-2 | **Column** `order_class text` on `bloom_order_cache_line` (additive, nullable). Appended after the recipe, so it cannot move a quantity. | `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` | n/a |
| C-3 | **STEP 3c**: append the long-tail rows the recipe did not return, as `line_kind = 'long_tail'`, quantity 0, with the class reason. Place-takers always. The no-place rows per Q12. Use `NOT EXISTS` against the sheet as STEP 3 does (archive `:106-107`). | next to E1's STEP 3b, before `v_ms := ...` | 1 |
| C-4 | **Header counts:** add the long-tail count to `line_count`, and keep it out of the withheld counts, so `served = line_count` holds (`create_bloom_order_cache.sql:314-319`). | the E1 line `SET line_count = v_n + v_appended + v_unord,` | 1 |
| C-5 | `rpc_bloom_order_cached` | **No change for the place-takers.** The reader withholds only `covered` and `unordered` (E1 `bloom035_e1_cache_rows.sql:84-103`), so `long_tail` rows are served. **If Q12 stores the no-place lines as withheld rows,** give them their own `line_kind` (`long_tail_idle`) and add it to the two reader filters next to `'covered'` and `'unordered'` (the E1 anchors, count 2). | 2 only if Q12 says so |

### 5.5 Stock-now card and the desk words

| # | Edit | Anchor | Count |
|---|---|---|---|
| S-1 | `rpc_bloom_stock_state`: four groups. KVI to KVI, `LONGTAIL` to LONG_TAIL, `TAIL` and `BELOW_GATE` to TAIL, the rest to CORE, with the old `kvi_band` test as the fallback when a line has no class row. | the `CASE` at `create_rpc_bloom_stock_state.sql:144-148` and the join at `:151-153` | 1 each |
| U-5 | `page.jsx` `addedByGroup` and the mapping read `l.order_class`, with the fallback | `const addedByGroup = { KVI: 0, CORE: 0, TAIL: 0 }` (`:1924`) and the two lines `:1928-1929` | 1 each |
| U-6 | Show `LONG_TAIL` as "LONG TAIL" in the group card | `{g.group_name}` (`:2621`) | 1 |
| U-7 | A class word beside Tier in the row (optional, a CD question, not mine) | `:1523` | n/a |

The card groups are KVI, CORE, TAIL, LONG TAIL. HERO and NEW sit in CORE, because R11 names four groups (Q13).

### 5.6 Apply in two steps, so the first proves nothing moved

1. **Dormant.** The class table (empty) and the builder edits are already in from step 3 of 6.4. Apply R-1 to R-9, R-11 and R-12. With no class rows the recipe must return the same quantities for Standard as before. R22 on the same evening, because the inputs do not move between 20:00 and 22:15: run the live recipe before and after for the five DC desks and one direct desk per store, fit off and on, 20 calls. Expect 0 differing products. (Essentials and Catch-up are not stored yet, so they have no baseline. They get T-ESS and T-CU instead.)
2. **Live.** Fill the table. Read per class, from the stored sheets of the next night: the lines that moved, the value, and the acceptance below.

The pension edits (R-13 to R-15) are a **separate migration** with its own R22 (4.6), because they move Standard orders on purpose.

### 5.7 Acceptance read-backs (10116, the live desk)

```sql
-- A-KVI: 0 KVI targets changed. Compare KVI lines before and after the class migration (same evening, same inputs).
-- A-TAIL: every tail line at 2 or fewer has 1 case, the rest 0 (Standard, fit off).
select c.store_code, c.route_key,
  count(*) filter (where l.order_class = 'TAIL' and l.projected_soh <= 2 and l.suggested_packs <> 1 and not coalesce(l.keep_or_delist,false)) as tail_low_without_case,
  count(*) filter (where l.order_class = 'TAIL' and l.projected_soh >  2 and l.suggested_packs <> 0 and not l.promo_active) as tail_high_with_qty
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.store_code = '10116' and c.generated_at > now() - interval '30 hours'
group by 1, 2;

-- A-LT: long tail within 10% of the store's new lines, all at 0 suggested, all on the sheet
select c.store_code, c.route_key,
  count(*) filter (where l.line_kind = 'long_tail') as long_tail_rows,
  count(*) filter (where l.line_kind = 'long_tail' and l.suggested_packs > 0) as long_tail_with_qty,
  (select count(*) from l2_order_class o where o.store_code = c.store_code and o.route_key = c.route_key and o.takes_place) as places_taken
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.store_code = '10116' and c.generated_at > now() - interval '30 hours'
group by 1, 2;
```

---

## 6. What is ready, what needs PM, what waits, and the order

### 6.1 Ready to build now (no ruling missing, no wait)

| Step | What | Why it is safe to start |
|---|---|---|
| A-1 | Re-sync the cache builder, `_all`, reader and stored-overview sources from live, hash-gated | Source parity only. The repo copies are stale (section 1, correction 1). |
| A-2 | **Part 2:** J-1 to J-3, B-1, the new job J-2, UI U-1 to U-4. Dry-run four desks. | The recipe already takes both presets (the old Recipe form passes them, `page.jsx:1183-1187`). Additive. Essentials and Catch-up show a MISS today, so storing them cannot make a stored order worse. |
| A-3 | **Class table, refresh function, config keys, dry counts.** Reproduce ENG-235 (261, 207, 54, 0.0190 at 10116 DC ambient). With item 5's groups A and C first (its Q10). | Additive and dormant. PM already accepted the scope (`SB-PM-CLOSE...md:148`). |
| A-4 | **S-1 and U-5, U-6** (stock-now four groups) | Falls back to the old test until class rows exist. |
| A-5 | **The pension helper** `rpc_income_build_state`, the PAYDAY loader and the rows | New objects. The recipe does not call them yet. |
| A-6 | Cache builder C-1 to C-4 | Reads the dormant class table. |

### 6.2 Waits for another item

| Step | Waits for | Why |
|---|---|---|
| B-1 | Items 3 and 3b applied first, and the fresh cover cap if it lands first | One seat on the recipe. R-5's format argument number moves. 3b's story edit and R-12 share the story. Re-take every anchor from the live body after each of them. |
| B-2 | Item 3's `pension_kept` flag | The pension cycle applies only where the rhythm test shows it. |
| B-3 | Item 5 groups A and C (config key and `l2_range_state.first_sale_date`) | One new-line test. 4b never puts a new line in the long tail. |

### 6.3 Needs PM (section 7 has each question and its default)

Pivots, meaning they change what a buyer sees an order do: **Q7, Q8, Q10.** The rest have a default I build on if PM is silent.

### 6.4 The order I would build in

| # | Build | Window | Gate |
|---|---|---|---|
| 1 | A-1 re-sync, then A-2 part 2 (new job, UI) | Write now. Dry-run in 20:00 to 21:45. Apply after job 26 ends, not 22:00 to 03:00. | R22 not needed (new keys only). Read 4 next morning. |
| 2 | A-3 class table, function, keys. Run the dry counts in the window. | 20:00 to 21:45 | Counts match ENG-235 or the difference is named. |
| 3 | A-4, A-6 (stock state, builder, dormant) | After step 2 | R22 as 5.6 step 1 |
| 4 | A-5 helper, loader, rows | Anytime outside the closed window | The old-versus-new date table (4.6 item 1) |
| 5 | **Items 3 and 3b** (not mine, they come first) | Per the PM order | |
| 6 | Recipe migration E: R-1 to R-12 (Essentials, TAIL, LONGTAIL, class words), dormant | 20:00 apply, R22 in the window | 20 calls, 0 diffs |
| 7 | Fill the class table, read A-KVI, A-TAIL, A-LT, T-ESS | Next nights | PM reads 10116 |
| 8 | Recipe migration F: R-13 to R-15 (pension build) | After item 3's flag | 4.6 items 2 and 3 |
| 9 | Part 3.5 multi-drop, if PM rules a number | After step 8 | T-DATE, T-BUILD |
| 10 | Item 5 recipe edits | Per the PM order | `scratch/plans/item5_new_lines.md` |

The instruction is to press on. Steps 1 to 4 need no ruling and do not touch the recipe.

---

## 7. Open questions for PM

Each has the default I build on if PM says nothing. I hold only on a pivot (PM 14-10 08:55).

| Q | Question | Default | Pivot? |
|---|---|---|---|
| Q1 | The floor for the tail: a **new key** `temp_floor_units_tail` = 2, or change `temp_floor_units` from 3 to 2 for everything? The brief says "for the tail". | New key. HERO and CORE keep 3. | No |
| Q2 | Does the 28-day pack test stay on the tail? R11 changes the units, and Pieter's 05-10 floor carries the test. The acceptance ("every tail line with 2 or fewer has 1 case") reads as no exceptions. | The test stays. The acceptance then means "except keep-or-delist lines". Read 17 counts those lines. | No (it follows the 05-10 ruling) |
| Q3 | A tail line on promo: gear as today or one case only? | Exempt promo lines from the tail rule, so gearing is untouched. Read 17 counts them. | No |
| Q4 | If non-sellers holding stock outnumber a desk's places, which fill first? | Highest capital at cost. | No |
| Q5 | The neighbour test on real 13-digit EANs only? | Yes. | No |
| Q6 | Lines with a negative GMROI: ranked first by their artefact, or left out of the fill? | Left out of the fill (a negative GMROI is a cost-scale artefact, ENG-235). Read 16. | No |
| Q7 | **At a store with no pension uplift (21355, 80176), what do EARLY_MONTH lines do?** | Build on the payday build delivery. | **Yes** |
| Q8 | **How many deliveries make a build, for each cycle?** ENG-083 (13-08) made it the last two before the 25th. BLOOM-035 says "the last delivery before each window". | Two for both cycles (`income_build_drops` = 2). | **Yes** |
| Q9 | How many deliveries does the nightly store per desk? | Two. Cost is linear. | No (cost) |
| Q10 | **Should Fit move promo lines on the desk?** Today it never does (2.5). | Leave as is until ruled. Read-back reports the count. | **Yes** |
| Q11 | Does the tail rule hold in Catch-up? | Yes, the class rule is class-wide. | No |
| Q12 | The 6,722 no-place long-tail lines at 10116 DC ambient: stored as sheet rows on every sheet, stored as withheld rows, or only labelled in the class table and found by search? A served sheet of about 8,000 rows is a large payload (the 1,065-line sheet took 3 seconds, `create_bloom_order_cache.sql:12-13`). | Serve the place-takers. Store the no-place lines as withheld rows on standard fit off only. | No |
| Q13 | The card: where do HERO, NEW and BELOW_GATE sit? | HERO and NEW in CORE, BELOW_GATE in TAIL. | No |
| Q14 | Who loads the SASSA 2027/28 schedule (the table ends 04-03-2027) and the 2027 public holidays? | PM, by January. | No |
| Q15 | Build depth after item 3: keep the max band and short window on top of the rhythm index? | Keep as ruled in ENG-083. The read-back tests the "lowest delivery after the build" acceptance. | No |
| Q16 | Payday when the 25th is a public holiday: move back like a weekend? R2 tested the weekend rule only. | Yes. | No |
| Q17 | Do Essentials and Catch-up read the derived build state like Standard? | Yes, one home. It moves their numbers, which are not stored today. | No |
| Q18 | In Essentials, is a "promo line" `promo_active` (includes a closing-week line, ordered at normal quantity) or `promo_geared` (live depth rule, `recipe:684`)? | `promo_active`. | No |

---

## 8. Live reads for the 20:00 to 22:00 SAST window

All read-only. Run the heavy ones before 22:10 so none overlaps the 22:15 pipeline, and set a lock timeout first (ENG-236: a connector query on a matview blocks the refresh). The `set` lines belong in the same call, because each MCP call is a fresh connection. None reads the rows of `l2_stock_position`, `l2_item_classification` or `l2_rate_of_sale`. Read 10 calls `rpc_bloom_next_deliveries`, which calls `rpc_derive_placement_day`. I did not read that function, so run Read 10 desk by desk if it raises.

**Read 0. Pre-flight, overloads and pins (do first).**
```sql
select p.proname, count(*) as overloads, string_agg(md5(p.prosrc) || ':' || length(p.prosrc), ' | ') as md5_len
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('rpc_bloom_order_recipe','refresh_bloom_order_cache','refresh_bloom_order_cache_all','rpc_bloom_order_cached',
                    'rpc_bloom_stock_state','rpc_bloom_stored_overview','refresh_l2_population_verdict','rpc_bloom_next_deliveries','rpc_bloom_desks')
group by 1 order by 1;
```
Answers: one overload each, and is the recipe `f2fb054fbf7f06943171c490abd51b5b:46427`?

**Read 1. The cron jobs.**
```sql
select jobid, jobname, schedule, active, left(command, 500) as command
from cron.job
where jobid in (8, 10, 15, 24, 26, 54, 57) or command ilike '%bloom_order_cache%'
order by jobid;
```
Answers: what job 26 calls, its ceiling, why DC_FRESH is skipped, and the real times of the neighbours.

**Read 2. How long the nightly build took, night by night.**
```sql
select (c.generated_at at time zone 'Africa/Johannesburg')::date as night_sast,
       count(*) as combos, count(distinct (c.store_code, c.route_key)) as desks,
       min(c.generated_at) as first_built, max(c.generated_at) as last_built,
       round(extract(epoch from (max(c.generated_at) - min(c.generated_at))) / 60.0, 1) as span_min,
       round(sum(c.generation_ms) / 60000.0, 1) as recipe_min, sum(c.line_count) as rows_stored
from bloom_order_cache c
where c.source = 'nightly' and c.generated_at > now() - interval '10 days'
group by 1 order by 1 desc;
```
Answers: the real minutes behind my 36 to 46 minute estimate, and the room before job 26's ceiling.

**Read 3. Cost by desk class, last night.**
```sql
select case when c.route_key in ('DC_AMBIENT','DC_TOPS','DC_FRESH') then 'DC'
            when c.route_key = 'DIRECT_CATCHALL' then 'CATCHALL'
            when c.route_key ~ '^DIRECT_S[0-9]+$' then 'DERIVED'
            else 'BRAND_OR_SAB' end as desk_class,
       c.fit_to_budget, count(*) as combos,
       round(avg(c.generation_ms) / 1000.0, 1) as avg_s, round(max(c.generation_ms) / 1000.0, 1) as max_s,
       round(sum(c.generation_ms) / 1000.0) as total_s, sum(c.line_count) as rows_stored
from bloom_order_cache c
where c.source = 'nightly' and c.generated_at > now() - interval '30 hours'
group by 1, 2 order by 1, 2;
```
Answers: per-combination cost for each desk type, so the 2.5 times is a number.

**Read 4. Which presets are stored.**
```sql
select c.preset, c.fit_to_budget, count(*) as headers,
       count(distinct (c.store_code, c.route_key)) as desks, max(c.generated_at) as last_built
from bloom_order_cache c where c.generated_at > now() - interval '48 hours'
group by 1, 2 order by 1, 2;
```
Answers: still 0 Essentials and 0 Catch-up?

**Read 5. The desk count.**
```sql
select count(*) as desks, count(*) filter (where route_key = 'DC_FRESH') as dc_fresh,
       count(*) filter (where is_dc) as dc_desks,
       count(*) filter (where route_key ~ '^DIRECT_S[0-9]+$') as derived_desks
from rpc_bloom_desks();
```
Answers: is it about 140, and does the list include DC_FRESH?

**Read 6. Table size and retention.**
```sql
select c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) as total_size, c.reltuples::bigint as est_rows
from pg_class c
where c.oid in ('public.bloom_order_cache'::regclass, 'public.bloom_order_cache_line'::regclass, 'public.l2_population_verdict'::regclass);
```
```sql
select c.delivery_date, count(*) as headers from bloom_order_cache c group by 1 order by 1 desc limit 12;
```
Answers: how big the stored sheets are, and whether old delivery dates are ever purged.

**Read 7. The forge keys.**
```sql
select config_key, store_format, value_num, scope, effective_from, retired_on
from forge_config
where config_key in ('temp_floor_units','temp_floor_pack_days','temp_floor_units_tail','month_end_build_anchor_dom',
                     'relevant_min_cover_days','new_line_settling_days','income_build_drops')
order by 1;
```
Answers: the live floor values (3 and 28?), and that none of my new keys exists yet.

**Read 8. What is in the income calendar.**
```sql
select event_type, event_stream, count(*) as n, min(event_date) as first_date, max(event_date) as last_date,
       count(*) filter (where is_non_trading) as non_trading
from calendar_events group by 1, 2 order by 1, 2;
```
Answers: any PAYDAY rows, the horizon of the SASSA rows, the holidays held.

**Read 9. Route delivery days.**
```sql
select store_code, route_key, delivery_dows, cycle_weeks, cycle_anchor_week_start, order_cutoff_days
from supplier_calendar
where route_key in ('DC_AMBIENT','DC_TOPS','DC_FRESH','DIRECT_CATCHALL') order by 1, 2;
```
Answers: which weekdays each DC desk delivers on, for the build-date example in 4.2.

**Read 10. The income window and last delivery, by DC desk, today.**
```sql
select v.store_code, v.route_key, nd.delivery_date, nd.following_date, nd.income_window_start,
       nd.last_delivery_before_income, nd.placement_deadline, nd.income_calendar_state
from (select store_code, route_key from supplier_calendar where route_key in ('DC_AMBIENT','DC_TOPS')) v
cross join lateral rpc_bloom_next_deliveries(v.store_code, v.route_key) nd order by 1, 2;
```
Answers: the live "last delivery before pension" per desk, the dates my read-backs in 4.6 target.

**Read 11. The ten read-back desks.**
```sql
select distinct on (store_code) store_code, route_key as direct_desk
from bloom_route_config
where status = 'RULED' and route_key not in ('DIRECT_BEER','DIRECT_CATCHALL') and route_key !~ '^DIRECT_S[0-9]+$'
order by store_code, route_key;
```
Answers: one brand desk per store. Pair each with the store's DC desk from read 9.

**Read 12. Build mode on the stored sheet today.**
```sql
select c.store_code, c.route_key, l.archetype, l.mode, count(*) as lines, round(sum(l.suggested_packs * l.pack_cost)) as value
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.generated_at > now() - interval '30 hours' and l.line_kind = 'ordered'
group by 1, 2, 3, 4 order by 1, 2, 3, 4;
```
Answers: how many lines and how much value sit in build mode now, per archetype. The size of the pension change.

**Read 13. The archetype mix.**
```sql
select store_code, archetype, count(*) as lines from l2_rhythm_profile group by 1, 2 order by 1, 2;
```
Answers: how many EARLY_MONTH and MONTH_END lines each store has (Q7).

**Read 14. Value at stake in the tail rule (stored Standard sheets).**
```sql
select c.store_code, c.route_key,
  count(*) filter (where l.range_state = 'CORE' and l.tier = 'BOR' and coalesce(l.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT')
                     and not coalesce(l.is_bt_hero,false) and l.suggested_packs > 0) as tail_ordered_lines,
  round(sum(l.suggested_packs * l.pack_cost) filter (where l.range_state = 'CORE' and l.tier = 'BOR'
                     and coalesce(l.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT') and not coalesce(l.is_bt_hero,false))) as tail_value,
  round(sum(l.suggested_packs * l.pack_cost) filter (where l.range_state = 'CORE' and l.tier = 'BOR'
                     and coalesce(l.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT') and not coalesce(l.is_bt_hero,false)
                     and l.projected_soh > 2)) as value_that_goes_to_zero
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.generated_at > now() - interval '30 hours'
  and c.route_key in ('DC_AMBIENT','DC_TOPS') and l.line_kind = 'ordered'
group by 1, 2 order by 1, 2;
```
Answers: what the tail rule removes per DC desk, from the stored sheet, with no recipe run. (A rough size: the 3-unit floor and the min-band top-up are mixed in `suggested_packs`.)

**Read 15. Real EANs versus manufactured keys.**
```sql
select store_code, key_source, count(*) as n, count(*) filter (where length(export_key) = 13) as len13
from l2_export_key where store_code in ('10116','80175') group by 1, 2 order by 1, 2;
```
Answers: how many lines have a real 13-digit key (Q5).

**Read 16. Negative GMROI.**
```sql
select store_code, count(*) filter (where gmroi < 0) as negative, count(*) filter (where gmroi is null) as no_gmroi,
       min(gmroi) as lowest, count(*) as rows
from l2_gmroi_profile group by 1 order by 1;
```
Answers: Q6.

**Read 17. Promo and keep-or-delist lines in the tail (stored Standard).**
```sql
select c.store_code, c.route_key,
  count(*) filter (where l.promo_active and l.tier = 'BOR' and l.range_state = 'CORE') as promo_tail_lines,
  count(*) filter (where l.promo_active and l.tier = 'BOR' and l.range_state = 'CORE' and (l.geared_packs > 0 or l.normal_packs > 0)) as promo_tail_ordered,
  count(*) filter (where l.keep_or_delist and l.tier = 'BOR' and l.range_state = 'CORE') as tail_keep_or_delist
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id
where c.preset = 'standard' and not c.fit_to_budget and c.generated_at > now() - interval '30 hours'
  and c.route_key in ('DC_AMBIENT','DC_TOPS')
group by 1, 2 order by 1, 2;
```
Answers: Q2 and Q3 sizes.

**Read 18. Desks priced against no ledger row (stored fit on).**
```sql
select c.store_code, c.route_key, min(l.budget_week_source) as week_source
from bloom_order_cache c join bloom_order_cache_line l on l.cache_id = c.cache_id and l.line_no = 1
where c.preset = 'standard' and c.fit_to_budget and c.generated_at > now() - interval '30 hours'
group by 1, 2 having min(l.budget_week_source) <> 'delivery_week_exact' order by 1, 2;
```
Answers: which desks the Fit switch trims to nothing today (2.6 gap c).

**Read 19. Long-tail sizing at every DC desk (the ENG-235 count, generalised).**
```sql
set statement_timeout = '120s'; set lock_timeout = '5s';
with wm as (
  select store_code, max(sale_date) as w from sigma_sales
  where period_kind = 'T' and txn_kind = 1 and sale_date >= current_date - 30 group by 1),
pool as (
  select v.store_code, v.route_key, v.product_code, v.kvi_band, v.range_state, v.soh
  from l2_population_verdict v
  join bloom_dc_config dc on dc.store_code = v.store_code and dc.status = 'RULED'
  where v.route_key in ('DC_AMBIENT','DC_TOPS') and v.department_nr = any (dc.dc_cycle_dept_nrs)),
sold as (
  select s.store_code, s.product_code from sigma_sales s join wm on wm.store_code = s.store_code
  where s.period_kind = 'T' and s.txn_kind = 1 and s.qty > 0 and s.sale_date > wm.w - 91 and s.sale_date <= wm.w
  group by 1, 2)
select p.store_code, p.route_key, count(*) as pool_lines,
  count(*) filter (where lc.first_sale_date > wm.w - 91) as new_lines_places,
  count(*) filter (where sd.product_code is null and p.soh > 0 and coalesce(lc.first_sale_date, date '1900-01-01') <= wm.w - 91
                     and coalesce(p.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT') and p.range_state <> 'HERO') as nonsellers_with_stock,
  count(*) filter (where sd.product_code is null and coalesce(p.soh,0) <= 0 and coalesce(lc.first_sale_date, date '1900-01-01') <= wm.w - 91
                     and coalesce(p.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT') and p.range_state <> 'HERO') as nonsellers_no_stock,
  count(*) filter (where sd.product_code is not null and coalesce(lc.first_sale_date, date '1900-01-01') <= wm.w - 91
                     and coalesce(p.kvi_band,'') not in ('KVI_CRITICAL','KVI_IMPORTANT') and p.range_state <> 'HERO') as sellers_eligible
from pool p
join wm on wm.store_code = p.store_code
left join sold sd on sd.store_code = p.store_code and sd.product_code = p.product_code
left join sigma_lifecycle lc on lc.store_code = p.store_code and lc.product_code = p.product_code
group by 1, 2 order by 1, 2;
```
Answers: places, non-sellers with stock and sellers per DC desk (do 207 non-sellers cover 261 places at the other desks?). It uses Sigma's `first_sale_date` as a cheap proxy. Item 5's live read 2 decides which first-sale source wins. At 10116 DC ambient expect 261, 207, 6,722 and 5,492 if the proxy equals the till.

**Read 20. Deliveries per week per desk (the cost of storing more than one).**
```sql
select (sc.route_key like 'DC%') as dc_route, count(*) as desks,
       round(avg(cardinality(sc.delivery_dows)::numeric / coalesce(sc.cycle_weeks, 1)), 1) as avg_drops_per_week,
       max(cardinality(sc.delivery_dows)) as max_drops_per_week
from supplier_calendar sc join stores st on st.store_code = sc.store_code and st.is_active
group by 1;
```
Answers: Q9.

**Read 21. The columns I assume on the stock position matview (catalogue only).**
```sql
select a.attname from pg_attribute a
where a.attrelid = 'public.l2_stock_position'::regclass and a.attnum > 0 and not a.attisdropped
  and a.attname in ('tier','first_sale_date','last_sale_date','sales_qty_91d','class') order by 1;
```
Answers: the repo file for `l2_stock_position` is dated 09-06 and may be stale (`information_schema` is blind to matviews, so this reads `pg_attribute`).

---

## 9. Risks and what I did not check

1. **Run time is an estimate** from two August observations. Reads 2 and 3 replace it.
2. **The cron command for job 26 and its ceiling were not read.** The skip of DC_FRESH is unexplained until read 1.
3. **The archetype is still a typed day-of-month bucket** (`create_l2_rhythm_profile.sql:133-149`, `refresh_l2_rhythm_profile` runs before the band), and 89.5% of rows were NO_DATA on 03-09 (SB-AUD-RHYTHM-001 section 5, a one-day read). The pension build moves the build date. It does not fix which lines count as EARLY_MONTH or MONTH_END (ENG-077). Named, not fixed.
4. **`rpc_bloom_delivery_chain` and `rpc_bloom_month_projection`** call the recipe for later drops. They inherit the derived build state. I did not read their bodies.
5. **The department-set helper** from item 1b (`bloom_desk_dept_nrs`) was not read. The class function must mirror the recipe's pool exactly. Compare the class pool with the sheet pool on every desk in the dry run.
6. **The counts in section 5.1.1 are 10116 DC ambient only.** Read 19 gives the other desks.
7. **Calendar horizon:** SASSA to 04-03-2027, holidays 2026 only. The loader needs the 2027 holidays for a correct payday near them.
8. **Single-night and single-store evidence.** The 12-of-12 miss of the typed 25 is one store and one published year. The R2 pension flags are 6 cycles. Neither is a law.
9. **Two stored deliveries are not additive** (3.5). Nobody should add them for a purchase.
10. **The long-tail row volume** (Q12) can swamp the sheet payload. Decide before step C-3.
11. **MARKDOWN lines that sold** (item 5 risk 13) and the weighed-line GMROI artefact are noted in the sibling plan and ENG-235. They touch the long-tail fill (Q6).
