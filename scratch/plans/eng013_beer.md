# ENG-013, the SAB and beer order: status, mechanism, verification, fix

Prepared 14-10-2026 16:25 SAST (system clock) by a read-only seat. No database call was made. Every live fact below is quoted from a named repo or BUG-LOG line. Anything that only the live database can answer sits in section 5 as a query for the 20:00 to 22:00 SAST window.

**Scoped read, flagged.** CLAUDE.md asks for a 25-file recital. I skipped it on the task's instruction (PM-approved scoped start-read, 2026-07-20). Section 9 lists what I read in full, in part, and not at all. Evidence classes follow RULE-BOOK R28 section 5 as I know it from the project instructions. I did not re-read the rule book.

Paths in this file are relative to the worktree unless they start with `Daisy\`. `sql/` means `socialbrand-dashboard\.claude\worktrees\stocktake-count-app-build-6f61e0\sql\`.

## 1. Bottom line

1. **ENG-013 as written does not hold today at 80176 and 80579. It errs high, not low.** The stored fitted order at 80176 is R210,145 against an own need of R33,568 (6.3 times). At 80579 it is R90,020 against R18,970 (4.7 times). Source: `Daisy\BUG-LOG.md:3300-3301`, the 14-10-2026 simulation, one run.
2. **21355 is the one desk that may still be understated, by a different route.** On paper it is right: R14,790 against R16,223 (`BUG-LOG.md:3286`). But the need counts till sales only, and 21355 is the group's SAB buying point. It ships Dice's share by transfer (`Daisy\ORDERING-CANON-BUDGETS.md:104`). The calendar may also give the Friday sheet a lead of 1 day (section 4, M6).
3. **The two-truths part of ENG-013 is still live.** The retired function `rpc_bloom_order_direct_beer` still answers a visible tab on /bloom, "SAB Direct (beer)", on origin/main (`src/app/bloom/page.jsx:3443`, `:3451`, `:628`). Pieter asked on 12-07 to keep that tab until the SAB desk inside Desks passes his own walk (commit `f1a69b8`).
4. **The acceptance in the ruling mixes units and has no live check.** The floor was cost, the ceiling was a pooled row built on "incl-VAT turnover basis" (section 3). I found nothing in the repo that shows it re-run after the 12-07 seed note (`sql/create_order_budget_ledger_sab_weekly_seed.sql:14-16`). The acceptance PM restated on 14-10 ("shown OVER", `Daisy\Bloom\SB-PM-CLOSE_2026-10-14_Platform-Lane-State-and-Next-Moves.md:514`) passes both beer desks while they sit 4.7 to 6.3 times above need.
5. **I cannot say today how far above demonstrated demand 80176 sits.** The only demonstrated figure in the repo is July's R50,009 a week (cost). One query (R10, section 5) gives the answer for all three desks.
6. **The fix is three separate pieces, not one edit.** (a) Retire the legacy path, which is no-regret and gated by Pieter's walk. (b) Settle the 21355 and Dice supply route and the 21355 calendar, which needs PM. (c) Decide whether the rail or the formula is wrong at 80176 and 80579, which the 20:00 reads decide. Section 6 orders the edits. Section 7 lists the rulings.

## 2. Status per beer desk

| Desk | Verdict | Why, in short | What the repo cannot give me |
|---|---|---|---|
| 80176 DIRECT_BEER | **OVERSTATED** against its own rail (6.3 times). Against demonstrated demand: very likely overstated, not measured today | Fit is nearly idle: the protected set is R209,816 of R210,145 (99.8%), so the fit can trim at most R329 (M2). The band aims at 2 x lead + safety days with lead 7 (M1). The order is 2.2% under the whole of July's SAB receipts at 80176, R214,887.49 (`Daisy\BUG-LOG-2026H1.md:74`) | Today's demonstrated weekly cost. The engine's own weekly demand for this pool. `lead_days_used` on the stored sheet. Whether the rail is low (M3). Unit check on `pack_cost` (M4) |
| 80579 DIRECT_BEER | **OVERSTATED** on paper (4.7 times). Possibly **moot**: SAB last delivered at Dice on 27-03-2026 (as of the 11-09 apply, `BUG-LOG.md:1157`) and canon D8 shows Dice fed by S/L transfer from 21355 in the 90 days to 04-09 | Same formula, lead 7. Protected set R88,630 of R90,020 (98.5%). The desk was built on a derived Friday that dates from the months SAB delivered direct (`sql/eng185_dice_sab_desk.sql:5-6`). The first sheet on 18-09 was R64,665.89 (`BUG-LOG.md:1157`), so it grew 39% in under four weeks | Whether SAB delivers to Dice again. Whether the desk can be placed at all. Whether Pieter reopened the door (his standing item "80579 SAB reopen", `BUG-LOG.md:1229`) |
| 21355 DIRECT_BEER | **RIGHT against its rail** (R14,790 against R16,223, protected R14,510). **Probably UNDERSTATED against what the store buys** | The rail counts till sales. In the 90 days to 04-09, 21355 sold 46,213 units and dispatched 59,414 on S/M to Dice (`ORDERING-CANON-BUDGETS.md:104`). July SAB receipts at 21355 were R180,080.87, about R40.7K a week, against a July rail of R11,755 a week (`BUG-LOG-2026H1.md:74`) | The calendar days now. The lead on the stored sheet. The dispatch units in the last 91 days. Whether Dice is supplied by transfer today |

Notes on the evidence:

- The 14-10 numbers are SINGLE-OBSERVATION per desk. One run, the delivery date and stock of that day, committed spend left out (`BUG-LOG.md:3270`). They are a measurement of that day, not a law.
- "Stored today" equals "fitted to own need" on all three beer desks (`BUG-LOG.md:3286`, `:3300`, `:3301`). That shows the new own-need budget changed nothing on them. It does not by itself show the fit is idle. The protected share does (M2).
- The 20:05 SAST read-back (`scratch/readback_item2_own_need.sql`, cron job 72) writes the same comparison from the live recipe into `cc_scratch_b035_rb`. If it has run, R9 reads it.

## 3. Which number is in which unit

Pieter asked for cost against retail, week against delivery cycle, month against week. This is the map. A mismatch between two rows in the same column is a finding.

| Figure | Value | Unit | Scope and date | Source |
|---|---|---|---|---|
| ENG-013 floor, 80176 | R50,009 a week | Cost, last 28 days. Per week | Old merch-group beer pool. Written 11-07 | `BUG-LOG.md:138` |
| Same, retail | R68,722 a week | Retail. The ratio 0.728 fits cost over VAT-inclusive retail (my arithmetic, not a stated basis) | Same | `BUG-LOG.md:138` |
| ENG-013 ceiling, 80176 | R95,500 a week | The direct share of the SB-AP-BUDGET-002 budget. The file calls the whole budget "82% forecast, incl-VAT turnover basis" (line 54) | Pooled DIRECT row, all direct suppliers at 80176. Week of 11-07 | `sql/create_order_budget_ledger_weekly_grain.sql:16-21`, `:54-57`, `:74` |
| SAB weekly seed, 80176 | R77,732.83 a week | "Own weekly figure split by LY beer rhythm". Basis not stated in the file | DIRECT_BEER row. Week of 11-07 | `sql/create_order_budget_ledger_sab_weekly_seed.sql:6-12`, `:32` |
| SAB monthly plan, 80176 | R529,649.47 for October. About R120K a week | Purchases plan per month. Group R1.05M x 50.44% | DIRECT_BEER monthly row | `sql/create_order_budget_ledger.sql:49` |
| Rail (NEEDS), 80176 | R33,568 | Cost. Projected sales x config ratio 1.00. Summed over `ceil(gap / 7)` weeks (1 for a weekly desk) | Pool by supplier account. 14-10 | `BUG-LOG.md:3300`, `sql/create_refresh_order_budget_ledger_needs.sql:57-60`, `:99` |
| Stored fitted order, 80176 | R210,145 | Cost, ex-VAT: `packs x pack_cost` per delivery | One delivery. 14-10 | `BUG-LOG.md:3300`, recipe `:957` |
| July receipts, 80176 | R214,887.49 for the month. About R48.5K a week | Cost, GRV, ex-VAT | Account 590. July 2026 | `BUG-LOG-2026H1.md:74` |
| July receipts, 21355 | R180,080.87 for the month. About R40.7K a week | Same | Account 555. July 2026 | same |
| July rail, 21355 and 80176 | R11,755 and R32,150 a week | Cost, NEEDS | After the ENG-033 re-scope | same |

Three unit mismatches stand out.

- **Flow against position.** The rail is a flow: what the pool will sell in the week. The order is a flow plus a build to a target shelf position. At weekly lead the target is 2 x 7 + safety days (M1). So the order can exceed the rail at steady state and by far more on a first fill. Comparing the two is a category mismatch. "Order at or under need" can only hold when the shelf is already at target.
- **Cost against incl-VAT turnover.** The ENG-013 floor was cost. The R95,500 ceiling came from an incl-VAT turnover plan at 82%. The band was never one unit.
- **Month against week in the legacy tab.** `rpc_bloom_budget_context` returns `direct_beer_row` from the MONTHLY row of the current month (`sql/create_rpc_bloom_budget_context.sql:101-109`). The legacy tab shows that month figure as its gauge against a weekly order (`page.jsx:614-618`, `:649-652`). Its landed leg was retired from the monthly writer (`create_refresh_order_budget_ledger_needs.sql:137-139`), so the gauge may also read stale. Not measured. R7e reads it.

One week-alignment point, minor and not measured. The recipe reads the budget week that contains the delivery date, Saturday to Friday (`create_rpc_bloom_order_recipe.sql:458-476`). A Friday delivery (21355, 80579) is matched to the week it ends, not the week it feeds.

## 4. Mechanisms, with file and line

Evidence classes: DEDUCTIVE is read from code. CONTROLLED carries its n and scope. SINGLE-OBSERVATION is one run. HYPOTHESIS has not been measured. Each item names its falsifier.

**M1. The band aims at 2 x lead + safety days, and the lead is the drop gap. DEDUCTIVE.**
`create_rpc_bloom_order_recipe.sql:450` sets `v_lead` to the gap to the next delivery. `:648` sets `min_band = ros x lead + safety x ros`. `:712` and `:715` set `proj = max(soh,0) - ros x lead + on order` and `need = target - proj`. In minimum mode the target is the min band (`:687-688`). So need = ros x (2 x lead + safety) - soh - on order. The same variable is both the cover and the depletion. `Daisy\Bloom\SB-CC-DESKPARITY-001_Desk-Parity-Table_2026-10-05.md:316` states the result: 14 days plus safety at a weekly desk, 2 days plus safety at 21355 beer (gap 1).
Effect at zero stock: 2.0 weeks of demand with safety 0, 2.29 with safety 2, 2.57 with safety 4. This is arithmetic on the code, not a measurement. A first fill is therefore up to 2.6 weeks of the engine's own weekly demand before pack round-up.
Does it explain 6.3 times? Not alone. R210,145 over 2.57 would need an engine weekly demand near R82K at 80176, against a rail of R33.6K and a July demonstrated R50K. R4 measures that demand directly.
Falsifier: R4 shows `weeks_of_engine_demand_ordered` well above 2.6.
Related: item 3b (`sql/bloom035_item3b_days_to_truck.sql:14-20`) replaces the depletion with days from the stock reading to the truck. It is written, not applied, and simulated at 20:30 (job 73). At lead 7 and a truck 1 to 3 days after the reading it cuts 4 to 6 of 18 days (22 to 33%) at safety 4. That helps. It does not close 6.3 times.

**M2. The fit is idle on every beer desk because the protected set is the whole desk. CONTROLLED, n=3 desks, one run.**
`is_protected` is HERO or KVI critical or important (`create_rpc_bloom_order_recipe.sql:850`). A protected line keeps its full resolved packs (`:896`) and is funded first (`:911-914`). Protected value is 98% to 99.8% of the order on all three beer desks (`BUG-LOG.md:3286`, `:3300`, `:3301`). So `fit_to_budget` on or off gives almost the same sheet: the fit can trim at most 0.2% (80176), 1.5% (80579) or 1.9% (21355). The "ceiling, fit on" of the ENG-013 ruling is not enforced by anything on a beer desk. Canon is as written: the floor layer is "funded first, never trimmed" (`ORDERING-CANON-BUDGETS.md:47`). In minimum mode the CORE floor is the min band, so M1 inflates the floor itself.
What I do not know: why the beer pool is almost all KVI. R6a counts it. PM's own question 3 asks for exactly this reading (`SB-PM-CLOSE_2026-10-14...md:515-517`).
Falsifier: R1 shows `protected_value` well under `order_value` on a beer desk.

**M3. The rail may be low. HYPOTHESIS, with one data point.**
The rail is last year's cost at the same week x rhythm x seasonality x a trend capped to 0.6 to 1.6, summed over the products linked to the SAB account (`sql/create_l2_sales_budget.sql:11-24`, `:105-120`, `:122-138`, `:182-191`). A product with no sales a year ago contributes zero, and the file names that limit itself (`:33-38`). July data point: rail R32,150 a week against receipts of R48.5K a week at 80176 (`BUG-LOG-2026H1.md:74`). The config ratio is 1.00 and the demonstrated purchases to sales-at-cost ratio is 0.954 at 80176 over 91 days (`create_refresh_order_budget_ledger_needs.sql:27-35`).
The rail pool is wider than the recipe pool. The rail takes every active link on the account (`:117-119`). The recipe also drops products the population verdict gave to another desk (`create_rpc_bloom_order_recipe.sql:567`) and range state EXCLUDED (`:564`). So pool scoping can only make the rail higher than the recipe's own demand, never lower. A low rail is therefore LY, rhythm, seasonality, trend or LY-blind lines. R3 splits those.
Falsifier: R3 shows `rail_projection` within 25% of `wk_cost_28d`.

**M4. A unit trap in `pack_cost` is possible. HYPOTHESIS, untested.**
Order value is `packs x pack_cost`, and `pack_cost` is `sigma_supplier_link.list_cost` (`create_rpc_bloom_order_recipe.sql:495`, `:957`). The rail is `sigma_sales.cost_value`. If `list_cost` is per unit on some beer links while `pack_size` is 24, order value is understated by the pack size on those lines. If it carries deposit or duty that `cost_value` does not, it is overstated. SQL-CONVENTIONS asks for one named line reconciled against the receipt record before a derived figure leaves a seat (`Daisy\SQL-CONVENTIONS.md:84-92`). R5 does that.
Falsifier: R5 median ratio on the pack basis sits at 0.9 to 1.1.

**M5. 21355 buys for Dice and the engine does not see it. DEDUCTIVE on the code, CONTROLLED on the size.**
Demand is read from till sales (`sigma_sales`, period kind T, txn kind 1) and the pantry draw leg, which reads movement type K only (`sql/create_l2_bloom_ros_pantry.sql:372-374`). Nothing in the recipe reads a transfer leg. Canon D8 measures 21355 at 105,628 units received, 46,213 sold and 59,414 dispatched on S/M in 90 days to 04-09, "one unit in 105,628" (`ORDERING-CANON-BUDGETS.md:104`). The dispatch rate is 0.4423 at 21355 and 0.5550 at 80579 (`:111`). The rands on S/M and S/L are barred, roughly 12 times (`:106`), so any fix goes in units.
Second effect: `committed` counts every SAB receipt landed at 21355 (`create_refresh_order_budget_ledger_needs.sql:169-187`) against a till-only rail, and the recipe subtracts it (`create_rpc_bloom_order_recipe.sql:485-489`). When SAB has landed that week, the remaining budget is small or negative and the fit has no room beyond the floors.
Falsifier: R3c shows S/M dispatch units near zero in the last 13 weeks.

**M6. The 21355 Friday sheet may carry a lead of 1 day. DEDUCTIVE on the code, calendar state from 05-10.**
On 05-10 the calendar read delivery days 5 and 6, cutoff 1, and the latest cache gap was 1 (`SB-CC-DESKPARITY-001...md:183`). `rpc_bloom_next_deliveries` offers the two next dates, so a Friday first date has Saturday as the following date (`sql/create_rpc_bloom_next_deliveries.sql:76-94`). The recipe takes the gap as the lead. The ledger says SAB delivers to 21355 on Friday, one drop a week: 13 of 15 receipts, Saturday once, Monday once (`BUG-LOG.md:1391`). PM ruled the delivery day must come from the ledger (`BUG-LOG.md:1395-1397`). As of 14-09, steps 1 to 3 of that ruling were not built and the SAB rows were still `floor_attested` (`BUG-LOG.md:1414-1416`). If the row is still {5,6}, the Friday sheet (lead 1) aims at 2 + safety days and the Saturday sheet (lead 6) at 12 + safety days. The sheet the buyer sees depends on the night it was built (`create_bloom_order_cache.sql:431-436` builds one drop from NULL dates).
If the row moved to Friday only, the lead goes from 1 to 7. The aim goes from 6 to 18 days at safety 4, so the sheet triples or more (arithmetic, not measured). That would land near July's R40.7K a week of receipts. I note the match and do not rely on it.
Falsifier: R2 shows `delivery_dows` {5} at 21355, or R1 shows `lead_min` 7.

**M7. Dice has a desk for a door that D8 says is fed by transfer. Open fact.**
`sql/eng185_dice_sab_desk.sql:5-6` derived Friday from receipts that ended 27-03. D8 says Dice's SAB arrives by S/L from 21355 (`ORDERING-CANON-BUDGETS.md:104`). Pieter struck Dice's 9 SAB lines off the DC sheet on 10-09 (`BUG-LOG.md:1105`) and keeps "80579 SAB reopen" as his own call (`:1229`). If SAB does not deliver to Dice, the R90,020 sheet cannot be placed. If it does, then 21355's transfer leg stops and M5 shrinks. Both cannot be true at once. R8 reads the last dates.

**M8. The legacy path is still reachable. DEDUCTIVE.**
`page.jsx:3440-3444` lists `{ value: 'desk', label: 'SAB Direct (beer)' }` and `:3451` renders `DeskMode`. `DeskMode` calls `rpc_bloom_order_direct_beer` (`:628`) and `rpc_bloom_direct_beer_flags` (`:620`). The comment at `:3328-3330` says the tab is "no longer offered in the visible nav". The options list says it is. origin/main at `6fdb8af` still carries both lines. The function still scopes by merch group (`sql/create_rpc_bloom_order_direct_beer.sql:114`, `:173`), covers a flat 7 days (`:229-230`), has no band or KVI floor, and is granted to `anon` and `authenticated` in the repo copy (`:270-271`, live grants unverified, R7a). ENG-033 left `rpc_bloom_direct_beer_flags` on merch groups on purpose and called its scope "PM's to rule" (`BUG-LOG-2026H1.md:74`). This answers the open question in DESKPARITY section 9 ("whether the web app calls rpc_bloom_order_direct_beer"): it does, from the tab.
Falsifier: R7a shows both roles cannot execute.

**M9. The sheet cannot see an order already placed in BEES. DEDUCTIVE.**
SAB orders carry the 1990-01-01 sentinel and Sigma books the order at GRV, so there is no in-transit and no placement date (`sql/create_l2_on_order.sql:36-39`, `BUG-LOG.md:1393`). The recipe's on-order term is therefore 0 for beer. A sheet read after the buyer placed the order shows the full need again. Receipts count in `committed` only after they land.

**M10. No standing alarm covers beer. DEDUCTIVE.**
`DEFECT_SIGNAL` is held on direct desks (`sql/create_rpc_bloom_scenario_overview.sql:37-49`). Its direct-desk fallback benchmark is circular, a trailing 28 days over the order's own products (`:167-181`). Nothing fires if a beer desk runs 6 times high or 3 times low.

## 5. Verification plan, 20:00 to 22:00 SAST only

All statements below are SELECT only. None creates a table, writes a row or changes a setting. I have not run them. A syntax slip is possible, so run each once and read the error rather than the data if it fails.

**Order of work.**

1. 20:00 to 20:04. R1, R1b, R2, R7a, R7b, R7d, R7e. These are light.
2. Do not start R3 to R6 or R10 while the scheduled jobs run: job 72 at 20:05 (read-back, 28 desks), job 73 at 20:30 (item 3b simulation), jobs 74 to 76 at 21:00, 21:15 and 21:20 (`HANDOVER-CURRENT.md:61`). Read R9 after job 73 ends.
3. R3, R4, R5, R6, R8 and R10 after about 21:25 and finish by 21:55. R3c and R8 scan `sigma_movements` for three stores and are the heaviest. R7c calls the legacy function and is moderate. Run it once.
4. If an MCP call fails with a timeout, look at `pg_stat_activity` before re-issuing. Do not run any of this after 22:00.
5. `current_date` is the session date (UTC). At 20:00 to 22:00 SAST it equals the store date.

**R1. What the buyer sees: the latest stored beer sheets, both fit settings.**

```sql
with latest as (
  select distinct on (c.store_code, c.fit_to_budget)
         c.cache_id, c.store_code, c.fit_to_budget, c.delivery_date, c.next_delivery,
         c.generated_at, c.engine_md5
  from bloom_order_cache c
  where c.route_key = 'DIRECT_BEER' and c.preset = 'standard'
  order by c.store_code, c.fit_to_budget, c.generated_at desc)
select l.store_code, l.fit_to_budget, l.delivery_date, l.next_delivery,
       l.next_delivery - l.delivery_date as gap_days, l.generated_at, left(l.engine_md5, 8) as engine,
       count(*) filter (where x.line_kind = 'ordered' and x.suggested_packs > 0) as lines_ordering,
       round(sum(x.value) filter (where x.line_kind = 'ordered' and x.suggested_packs > 0)) as order_value,
       round(sum(x.value) filter (where x.suggested_packs > 0 and x.budget_fit_reason = 'protected_kvi_hero')) as protected_value,
       count(*) filter (where x.suggested_packs > 0 and x.kvi_band in ('KVI_CRITICAL', 'KVI_IMPORTANT')) as kvi_lines,
       min(x.lead_days_used) as lead_min, max(x.lead_days_used) as lead_max,
       min(x.budget_week_start) as budget_week, min(x.budget_week_source) as week_source
from latest l
join bloom_order_cache_line x on x.cache_id = l.cache_id
group by l.store_code, l.fit_to_budget, l.delivery_date, l.next_delivery, l.generated_at, l.engine_md5
order by l.store_code, l.fit_to_budget;
```

Reading it. `protected_value` only fills on the fit-true rows. If `order_value` is equal on fit true and false, the fit is idle (M2). `lead_min` and `lead_max` are the lead the sheet used: expect 7 at 80176 and 80579, and 1 or 6 at 21355 if the calendar is still {5,6} (M6). `week_source` other than `delivery_week_exact` means the ledger row was missing.

**R1b. Is the stored sheet on the live recipe.**

```sql
select * from rpc_bloom_order_cache_status(null, 'DIRECT_BEER');
```

```sql
select md5(p.prosrc) as prosrc_md5, length(p.prosrc) as prosrc_chars
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname = 'rpc_bloom_order_recipe';
```

Reading it. `engine_current` false means the sheet is older than the recipe. The repo recipe I read hashes to `f2fb054fbf7f06943171c490abd51b5b` over 46,427 chars. I computed that from `sql/create_rpc_bloom_order_recipe.sql`, body between `AS $function$` and the closing `$function$`, line endings normalised to LF. The second query must return the same pair. If it does not, the recipe moved after the 14-10 15:30 re-sync and every line number in this file is stale.

**R2. The calendar, the config and the offered dates.**

```sql
select sc.store_code, sc.route_key, sc.delivery_dows, sc.order_cutoff_days, sc.cycle_weeks,
       left(sc.order_cutoff_basis, 90) as cutoff_basis, sc.updated_at
from supplier_calendar sc
where sc.route_key = 'DIRECT_BEER'
order by sc.store_code;
```

```sql
select rc.store_code, rc.route_key, rc.status, rc.direct_supplier_nrs, rc.merch_group_nrs,
       rc.direct_cycle_weeks, left(rc.notes, 160) as notes_head
from bloom_route_config rc
where rc.route_key = 'DIRECT_BEER'
order by rc.store_code;
```

```sql
select '21355' as store_code, d.delivery_date, d.following_date, d.following_date - d.delivery_date as gap_days
  from rpc_bloom_next_deliveries('21355', 'DIRECT_BEER') d
union all
select '80176', d.delivery_date, d.following_date, d.following_date - d.delivery_date
  from rpc_bloom_next_deliveries('80176', 'DIRECT_BEER') d
union all
select '80579', d.delivery_date, d.following_date, d.following_date - d.delivery_date
  from rpc_bloom_next_deliveries('80579', 'DIRECT_BEER') d;
```

Reading it. At 21355, `delivery_dows` {5,6} with a `floor_attested` basis confirms M6. A `gap_days` of 1 on the next offered pair confirms the lead. Expect {2} at 80176 and {5} at 80579.

**R3a. Demonstrated weekly cost over the SAB account pool, and the trend inputs.**

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
tw as (select ((now() at time zone 'Africa/Johannesburg')::date - ((extract(isodow from (now() at time zone 'Africa/Johannesburg')::date)::int + 1) % 7)) as this_week)
select p.store_code, wm.wm as sales_watermark, count(distinct p.product_code) as pool_products_with_sales,
       round(sum(s.cost_value) filter (where s.sale_date > wm.wm - 28 and s.sale_date <= wm.wm) / 4.0) as wk_cost_28d,
       round(sum(s.cost_value) filter (where s.sale_date > wm.wm - 56 and s.sale_date <= wm.wm) / 8.0) as wk_cost_56d,
       round(sum(s.cost_value) filter (where s.sale_date > wm.wm - 91 and s.sale_date <= wm.wm) / 13.0) as wk_cost_91d,
       round(sum(s.cost_value) filter (where s.sale_date >= tw.this_week - 364 and s.sale_date < tw.this_week - 357)) as ly_cost_this_budget_week,
       round(sum(s.cost_value) filter (where s.sale_date > wm.wm - 56 and s.sale_date <= wm.wm)) as cost_trailing_56d,
       round(sum(s.cost_value) filter (where s.sale_date > wm.wm - 420 and s.sale_date <= wm.wm - 364)) as cost_ly_trailing_56d,
       round((sum(s.cost_value) filter (where s.sale_date > wm.wm - 56 and s.sale_date <= wm.wm))
             / nullif(sum(s.cost_value) filter (where s.sale_date > wm.wm - 420 and s.sale_date <= wm.wm - 364), 0), 3) as raw_trend_before_cap
from pool p
join wm on wm.store_code = p.store_code
cross join tw
join sigma_sales s on s.store_code = p.store_code and s.product_code = p.product_code
  and s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 420 and s.sale_date <= wm.wm
group by p.store_code, wm.wm
order by p.store_code;
```

Reading it. `wk_cost_28d` is the ENG-013 floor on today's date, in the unit of the original claim (cost, per week, over the account pool). `ly_cost_this_budget_week` should equal `ly_base_cost` in R3b to the rand, for the budget week that contains today. A gap means the pool or the sales moved since the last refresh. The trend the rail uses is anchored on the budget week, not the watermark, so `raw_trend_before_cap` is close to `trend_factor` and not identical. A raw trend outside 0.6 to 1.6 means the cap binds.

**R3b. The rail and the ledger side by side, this budget week and the next four.**

```sql
with tw as (select ((now() at time zone 'Africa/Johannesburg')::date - ((extract(isodow from (now() at time zone 'Africa/Johannesburg')::date)::int + 1) % 7)) as this_week)
select sb.store_code, sb.budget_week_start,
       round(sb.ly_base_cost) as ly_base_cost, sb.trend_factor,
       round(sb.rhythm_seasonality_projected_cost) as before_trend, round(sb.projected_sales_cost) as rail_projection,
       sb.products_in_pool, sb.products_with_ly_history, sb.anchor_date,
       round(l.budget_amount) as ledger_budget, round(l.committed_amount) as ledger_committed,
       round(l.landed_amount) as ledger_landed, coalesce(l.budget_manual_override, false) as manual_override
from tw
join l2_sales_budget sb on sb.route_key = 'DIRECT_BEER' and sb.budget_week_start between tw.this_week - 14 and tw.this_week + 28
left join order_budget_ledger l on l.store_code = sb.store_code and l.route_key = 'DIRECT_BEER'
  and l.grain = 'weekly' and l.year_month = sb.budget_week_start
order by sb.store_code, sb.budget_week_start;
```

Reading it. Compare `rail_projection` for `this_week` with `wk_cost_28d` from R3a. Under 75% means the rail is low (M3). A low `products_with_ly_history` against `products_in_pool` means LY-blind lines. `manual_override` true means NEEDS never wrote that row. `ledger_committed` above `ledger_budget` at 21355 shows the second effect in M5.

**R3c. Receipts, dispatches and transfers in, by budget week, last 9 weeks.**

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)),
tw as (select ((now() at time zone 'Africa/Johannesburg')::date - ((extract(isodow from (now() at time zone 'Africa/Johannesburg')::date)::int + 1) % 7)) as this_week)
select m.store_code,
       (m.movement_date - ((extract(isodow from m.movement_date)::int + 1) % 7)) as budget_week,
       round(sum(m.cost_value) filter (where m.movement_type in ('R', 'W') and m.supplier_nr = any (cfg.direct_supplier_nrs))) as sab_grv_cost,
       sum(m.qty) filter (where m.movement_type in ('R', 'W') and m.supplier_nr = any (cfg.direct_supplier_nrs)) as sab_grv_units,
       sum(abs(m.qty)) filter (where m.movement_type = 'S' and m.movement_process = 'M') as dispatch_units_s_m,
       sum(abs(m.qty)) filter (where m.movement_type = 'S' and m.movement_process = 'L') as transfer_in_units_s_l
from sigma_movements m
join cfg on cfg.store_code = m.store_code
cross join tw
where m.store_code in ('21355', '80176', '80579')
  and m.movement_date >= tw.this_week - 63
  and ((m.movement_type in ('R', 'W') and m.supplier_nr = any (cfg.direct_supplier_nrs))
    or (m.movement_type = 'S' and m.movement_process in ('M', 'L')
        and m.product_code in (select p.product_code from pool p where p.store_code = m.store_code)))
group by m.store_code, 2
order by m.store_code, 2;
```

Reading it. Units, never rands, for the S legs (canon D8). At 21355 the ratio `dispatch_units_s_m / sab_grv_units` over the weeks is the dispatch rate (D8 measured 0.4423 at 04-09). `sab_grv_cost` per week at 21355 against the rail in R3b is the M5 size. At 80579 an empty `sab_grv_*` with filled `transfer_in_units_s_l` confirms M7.

**R4. Decompose the stored unfitted order of each beer desk.**

```sql
with latest as (
  select distinct on (c.store_code) c.cache_id, c.store_code, c.delivery_date, c.next_delivery
  from bloom_order_cache c
  where c.route_key = 'DIRECT_BEER' and c.preset = 'standard' and c.fit_to_budget = false
  order by c.store_code, c.generated_at desc),
l as (
  select la.delivery_date as cache_delivery, la.next_delivery as cache_next, x.*
  from latest la
  join bloom_order_cache_line x on x.cache_id = la.cache_id
  where x.line_kind = 'ordered' and x.suggested_packs > 0),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
raw as (
  select s.store_code, s.product_code, sum(s.qty) / 56.0 as raw56
  from sigma_sales s
  join wm on wm.store_code = s.store_code
  where s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 56 and s.sale_date <= wm.wm
    and s.store_code in ('21355', '80176', '80579')
    and s.product_code in (select product_code from l)
  group by s.store_code, s.product_code)
select l.store_code, count(*) as lines, min(l.cache_delivery) as delivery, min(l.cache_next) as next_delivery,
       round(sum(l.value)) as order_value,
       round(sum(l.need_units * l.pack_cost / nullif(l.pack_size, 0))) as unrounded_need_value,
       round(sum(l.rhythm_adjusted_demand * 7 * l.pack_cost / nullif(l.pack_size, 0))) as engine_weekly_cost_demand,
       round(sum(coalesce(r.raw56, 0) * 7 * l.pack_cost / nullif(l.pack_size, 0))) as raw56_weekly_cost_demand,
       round(sum(l.value) / nullif(sum(l.rhythm_adjusted_demand * 7 * l.pack_cost / nullif(l.pack_size, 0)), 0), 2) as weeks_of_engine_demand_ordered,
       count(*) filter (where l.soh <= 0) as lines_soh_zero,
       count(*) filter (where l.count_first) as lines_count_first,
       count(*) filter (where l.min_presence_forced) as lines_min_presence,
       count(*) filter (where l.story like '%TEMP_FLOOR%') as lines_temp_floor,
       count(*) filter (where l.demand_source = 'family_draw') as lines_family_draw,
       count(*) filter (where l.kvi_band in ('KVI_CRITICAL', 'KVI_IMPORTANT')) as lines_kvi,
       round(sum(l.value) filter (where l.kvi_band in ('KVI_CRITICAL', 'KVI_IMPORTANT'))) as kvi_value,
       round(sum(l.value) filter (where l.range_state = 'HERO')) as hero_value,
       min(l.lead_days_used) as lead_min, max(l.lead_days_used) as lead_max,
       round((percentile_cont(0.5) within group (order by (l.soh + l.suggested_packs * l.pack_size) / nullif(l.rhythm_adjusted_demand, 0)))::numeric, 1) as median_days_cover_after_order
from l
left join raw r on r.store_code = l.store_code and r.product_code = l.product_code
group by l.store_code
order by l.store_code;
```

Reading it. This is the diagnostic that splits M1 from the rest.

- `weeks_of_engine_demand_ordered` of 2.0 to 2.6 means the formula alone explains the order (M1). Above 3 means stock, round-up and floors add to it.
- `engine_weekly_cost_demand` against `wk_cost_28d` (R3a). A ratio above 1.3 means the engine's rates are inflated against the till. Under 0.8 means the engine sees less than the till.
- `engine_weekly_cost_demand` against `raw56_weekly_cost_demand`. A ratio above 1.3 means corrections or family draw lift the rate. The pantry caps correction at 2.0 times raw (`corrected_ros_cap_multiple`, DESKPARITY line 211) and the recipe takes the larger of scan and draw (`create_rpc_bloom_order_recipe.sql:625-632`).
- `unrounded_need_value` against `order_value` is the pack round-up and minimum presence effect.
- `median_days_cover_after_order` against 14 plus safety tells the same story per line.

**R5. Unit check on `pack_cost`, and one named line.**

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
lnk as (
  select distinct on (sl.store_code, sl.product_code)
         sl.store_code, sl.product_code, greatest(coalesce(sl.pack_size, 1), 1) as ps, sl.list_cost
  from sigma_supplier_link sl
  join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs)
  where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)
  order by sl.store_code, sl.product_code, sl.cost_date desc nulls last),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
sold_cost as (
  select s.store_code, s.product_code, sum(s.cost_value) / nullif(sum(s.qty), 0) as sale_cost_per_unit
  from sigma_sales s
  join wm on wm.store_code = s.store_code
  where s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 91 and s.sale_date <= wm.wm
    and s.store_code in ('21355', '80176', '80579')
  group by s.store_code, s.product_code
  having sum(s.qty) > 0)
select l.store_code, count(*) as lines_compared,
       round((percentile_cont(0.5) within group (order by (l.list_cost / l.ps) / u.sale_cost_per_unit))::numeric, 3) as median_ratio_pack_basis,
       round((percentile_cont(0.5) within group (order by l.list_cost / u.sale_cost_per_unit))::numeric, 3) as median_ratio_unit_basis,
       count(*) filter (where (l.list_cost / l.ps) / u.sale_cost_per_unit between 0.9 and 1.1) as within_10pct_pack_basis,
       count(*) filter (where l.list_cost / u.sale_cost_per_unit between 0.9 and 1.1) as within_10pct_unit_basis
from lnk l
join sold_cost u on u.store_code = l.store_code and u.product_code = l.product_code
where l.list_cost > 0 and u.sale_cost_per_unit > 0
group by l.store_code
order by l.store_code;
```

```sql
with top as (
  select l.store_code, l.product_code, l.description, l.pack_size, l.pack_cost, l.suggested_packs, l.value
  from bloom_order_cache_line l
  where l.cache_id = (select c.cache_id from bloom_order_cache c
                       where c.store_code = '80176' and c.route_key = 'DIRECT_BEER' and c.preset = 'standard' and c.fit_to_budget = false
                       order by c.generated_at desc limit 1)
    and l.line_kind = 'ordered' and l.suggested_packs > 0
  order by l.value desc limit 3)
select t.*, lr.movement_date as last_grv_date,
       round(lr.cost_value / nullif(lr.qty, 0), 4) as last_receipt_cost_per_unit,
       round(t.pack_cost / nullif(t.pack_size, 0), 4) as engine_cost_per_unit
from top t
left join lateral (select m.movement_date, m.cost_value, m.qty from sigma_movements m
                    where m.store_code = t.store_code and m.product_code = t.product_code and m.movement_type in ('R', 'W')
                    order by m.movement_date desc limit 1) lr on true;
```

Reading it. A median ratio on the pack basis near 1.0 means `list_cost` is per pack and the order value is in the same unit as the rail. A median near 1.0 on the unit basis means `list_cost` is per unit and the order value is wrong by the pack size. Anything else points at deposit, duty or VAT. The named-line query gives one receipt to hold against the engine's cost per unit (SQL-CONVENTIONS, one named line).

**R6. Why the protected set is the whole desk, whether the pools agree, and the doors.**

R6a, KVI mix of the pool:

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date))
select b.store_code, b.kvi_band, count(*) as pool_lines
from l2_stock_band b
join pool p on p.store_code = b.store_code and p.product_code = b.product_code
group by b.store_code, b.kvi_band
order by b.store_code, b.kvi_band;
```

R6b, rail pool against recipe pool, and pantry coverage:

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
c56 as (
  select s.store_code, s.product_code, sum(s.cost_value) as cost56
  from sigma_sales s join wm on wm.store_code = s.store_code
  where s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 56 and s.sale_date <= wm.wm
    and s.store_code in ('21355', '80176', '80579')
  group by s.store_code, s.product_code),
flags as (
  select p.store_code, p.product_code,
         exists (select 1 from l2_population_verdict v where v.store_code = p.store_code and v.product_code = p.product_code
                  and v.route_overlap and v.route_key is distinct from 'DIRECT_BEER') as verdict_elsewhere,
         exists (select 1 from l2_range_state r where r.store_code = p.store_code and r.product_code = p.product_code
                  and r.range_state = 'EXCLUDED') as range_excluded,
         exists (select 1 from l2_bloom_ros_pantry rop where rop.store_code = p.store_code and rop.product_code = p.product_code) as has_pantry_row
  from pool p)
select f.store_code, count(*) as pool_products,
       count(*) filter (where f.verdict_elsewhere) as in_rail_not_in_recipe_verdict,
       count(*) filter (where f.range_excluded) as in_rail_not_in_recipe_excluded,
       round(sum(c.cost56)) as cost56_pool,
       round(sum(c.cost56) filter (where f.verdict_elsewhere or f.range_excluded)) as cost56_of_those_two_groups,
       count(*) filter (where not f.has_pantry_row) as no_pantry_row
from flags f
left join c56 c on c.store_code = f.store_code and c.product_code = f.product_code
group by f.store_code
order by f.store_code;
```

R6c, the doors (lines that sold in 91 days, sit at or under zero stock, and are not ordering on the sheet):

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
snap as (select store_code, max(snapshot_date) as d from l2_soh_daily where store_code in ('21355', '80176', '80579') group by store_code),
soh as (select se.store_code, se.product_code, se.soh_effective from v_l2_soh_effective se join snap on snap.store_code = se.store_code and se.snapshot_date = snap.d),
sold as (
  select s.store_code, s.product_code, sum(s.qty) as q91
  from sigma_sales s join wm on wm.store_code = s.store_code
  where s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 91 and s.sale_date <= wm.wm
    and s.store_code in ('21355', '80176', '80579')
  group by s.store_code, s.product_code),
latest as (
  select distinct on (c.store_code) c.cache_id, c.store_code
  from bloom_order_cache c
  where c.route_key = 'DIRECT_BEER' and c.preset = 'standard' and c.fit_to_budget = false
  order by c.store_code, c.generated_at desc),
onsheet as (
  select la.store_code, x.product_code
  from latest la join bloom_order_cache_line x on x.cache_id = la.cache_id
  where x.line_kind = 'ordered' and x.suggested_packs > 0)
select p.store_code,
       count(*) filter (where coalesce(so.soh_effective, 0) <= 0 and coalesce(sd.q91, 0) > 0) as sold_91d_and_out_of_stock,
       count(*) filter (where coalesce(so.soh_effective, 0) <= 0 and coalesce(sd.q91, 0) > 0 and os.product_code is null) as of_those_not_ordering_on_sheet,
       count(*) filter (where coalesce(sd.q91, 0) > 0) as sold_91d
from pool p
left join soh so on so.store_code = p.store_code and so.product_code = p.product_code
left join sold sd on sd.store_code = p.store_code and sd.product_code = p.product_code
left join onsheet os on os.store_code = p.store_code and os.product_code = p.product_code
group by p.store_code
order by p.store_code;
```

Reading it. R6a shows how much of the pool is KVI. A pool that is nearly all KVI explains M2. In R6b, `in_rail_not_in_recipe_*` counts products the rail prices that the recipe never orders, so they inflate the rail. A rail that is low despite those lines is a real low rail. `no_pantry_row` counts lines with no corrected or draw rate. R6c counts the doors: lines that sold in 91 days, are at or under zero stock, and are not on the ordering sheet. "Doors visible" is part of the ENG-013 acceptance.

**R7. The legacy path.** Five reads, run one at a time.

R7a, grants:

```sql
select has_function_privilege('anon', 'public.rpc_bloom_order_direct_beer(text,date,date,date,date,integer)', 'EXECUTE') as anon_exec,
       has_function_privilege('authenticated', 'public.rpc_bloom_order_direct_beer(text,date,date,date,date,integer)', 'EXECUTE') as auth_exec;
```

R7b, call counts:

```sql
select current_setting('track_functions') as track_functions,
       (select count(*) from pg_stat_user_functions where funcname in ('rpc_bloom_order_direct_beer', 'rpc_bloom_direct_beer_flags')) as tracked_rows,
       (select coalesce(sum(calls), 0) from pg_stat_user_functions where funcname in ('rpc_bloom_order_direct_beer', 'rpc_bloom_direct_beer_flags')) as calls_since_stats_reset;
```

R7c, what the legacy function proposes today at 80176, against the sheet in R1:

```sql
with d as (
  select c.delivery_date, c.next_delivery from bloom_order_cache c
  where c.store_code = '80176' and c.route_key = 'DIRECT_BEER' and c.preset = 'standard' and c.fit_to_budget = false
  order by c.generated_at desc limit 1)
select count(*) filter (where o.suggested_packs > 0) as legacy_lines, round(sum(o.value)) as legacy_value
from d, rpc_bloom_order_direct_beer('80176', d.delivery_date, d.next_delivery) o;
```

R7d, overload check before any revoke:

```sql
select proname, pg_get_function_arguments(oid) as args from pg_proc where proname = 'rpc_bloom_order_direct_beer';
```

R7e, the monthly gauge the legacy tab draws:

```sql
select store_code, route_key, grain, year_month, round(budget_amount) as budget_amount, round(landed_amount) as landed_amount,
       round(sales_actual) as sales_actual, updated_at
from order_budget_ledger
where route_key = 'DIRECT_BEER' and grain = 'monthly' and year_month = date_trunc('month', current_date)::date
order by store_code;
```

Reading it. R7a false and false means no caller can reach the legacy function. An R7b with `track_functions` set to none and zero tracked rows means untracked, not unused. R7c gives today's legacy value at 80176 next to the R1 sheet value. In July the pair was R20,937 against R107,616. R7d must show one overload before any revoke. R7e shows the monthly gauge the legacy tab would draw.

**R8. Is the Dice door open, and does 21355 still ship to Dice?** Last dates and 90-day sums for each leg, per store.

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date))
select m.store_code, m.movement_type || '/' || coalesce(m.movement_process, '') as leg,
       max(m.movement_date) as last_date,
       count(distinct m.movement_date) filter (where m.movement_date > current_date - 90) as days_in_90d,
       round(sum(m.cost_value) filter (where m.movement_date > current_date - 90)) as cost_90d,
       sum(abs(m.qty)) filter (where m.movement_date > current_date - 90) as units_90d
from sigma_movements m
join cfg on cfg.store_code = m.store_code
where m.store_code in ('21355', '80176', '80579')
  and m.movement_date > current_date - 400
  and ((m.movement_type in ('R', 'W') and m.supplier_nr = any (cfg.direct_supplier_nrs))
    or (m.movement_type = 'S' and m.movement_process in ('M', 'L')
        and m.product_code in (select p.product_code from pool p where p.store_code = m.store_code)))
group by m.store_code, 2
order by m.store_code, 2;
```

Reading it. The legs are `R/W` (SAB GRV on the account), `S/M` (dispatch out) and `S/L` (transfer in). Use units for the S legs, never the rands (canon D8). A last `R/W` date at 80579 of 27-03-2026 with `S/L` active in the last 90 days confirms M7. An `S/M` leg at 21355 with a date inside the last 90 days confirms M5 is still live. No `S/M` rows means Dice has been cut loose and M5 is closed.

**R9. The scratch read-backs, if they ran and still exist.** Three reads, one at a time. If a table is gone, skip it.

R9a, the item 2 read-back (job 72, 20:05):

```sql
select * from cc_scratch_b035_rb where route_key = 'DIRECT_BEER' order by store_code;
```

R9b, the item 3b simulation (job 73, 20:30):

```sql
select * from cc_scratch_b035_sim3b where route_key = 'DIRECT_BEER' order by store_code;
```

R9c, the pre-apply simulation behind the R1 figures:

```sql
select * from cc_scratch_b035_sim3 where route_key = 'DIRECT_BEER' order by store_code;
```

Reading it. R9a gives the live recipe against the own need after the item 2 apply, with the unfitted value as control. R9b gives the item 3b effect on each beer desk (`old_value`, `new_value`, `days_to_truck`, `drop_gap`). R9c is the source of the R1 figures in section 2.

**R10. The acceptance comparator, one row per desk.**

```sql
with cfg as (select rc.store_code, rc.direct_supplier_nrs from bloom_route_config rc where rc.route_key = 'DIRECT_BEER' and rc.status = 'RULED'),
pool as (select distinct sl.store_code, sl.product_code from sigma_supplier_link sl join cfg on cfg.store_code = sl.store_code and sl.supplier_nr = any (cfg.direct_supplier_nrs) where coalesce(sl.status, '') <> 'S' and (sl.valid_to is null or sl.valid_to >= current_date)),
wm as (select store_code, max(sale_date) as wm from sigma_sales where period_kind = 'T' and txn_kind = 1 and store_code in ('21355', '80176', '80579') group by store_code),
dem as (
  select p.store_code, sum(s.cost_value) / 4.0 as demonstrated_wk
  from pool p
  join wm on wm.store_code = p.store_code
  join sigma_sales s on s.store_code = p.store_code and s.product_code = p.product_code
    and s.period_kind = 'T' and s.txn_kind = 1 and s.sale_date > wm.wm - 28 and s.sale_date <= wm.wm
  group by p.store_code),
fitc as (
  select distinct on (c.store_code) c.cache_id, c.store_code, c.delivery_date, c.next_delivery
  from bloom_order_cache c
  where c.route_key = 'DIRECT_BEER' and c.preset = 'standard' and c.fit_to_budget = true
  order by c.store_code, c.generated_at desc),
ord as (
  select f.store_code, f.delivery_date, f.next_delivery,
         sum(x.value) filter (where x.suggested_packs > 0) as order_value,
         sum(x.value) filter (where x.suggested_packs > 0 and x.budget_fit_reason = 'protected_kvi_hero') as protected_value
  from fitc f
  join bloom_order_cache_line x on x.cache_id = f.cache_id and x.line_kind = 'ordered'
  group by f.store_code, f.delivery_date, f.next_delivery),
led as (
  select l.store_code, sum(l.budget_amount) as ledger_budget, sum(l.committed_amount) as ledger_committed
  from order_budget_ledger l
  join ord o on o.store_code = l.store_code
  where l.route_key = 'DIRECT_BEER' and l.grain = 'weekly'
    and l.year_month >= (o.delivery_date - ((extract(isodow from o.delivery_date)::int + 1) % 7))
    and l.year_month < (o.delivery_date - ((extract(isodow from o.delivery_date)::int + 1) % 7))
                       + 7 * greatest(1, ceil((o.next_delivery - o.delivery_date) / 7.0))::int
  group by l.store_code)
select o.store_code, o.delivery_date, o.next_delivery,
       round(o.order_value) as order_value, round(o.protected_value) as protected_value,
       round(d.demonstrated_wk) as floor_demonstrated_28d_wk,
       round(l.ledger_budget) as ledger_budget_gross, round(l.ledger_budget - l.ledger_committed) as ceiling_ledger_remaining,
       case when o.order_value > l.ledger_budget - l.ledger_committed then 'ABOVE_CEILING'
            when o.order_value < d.demonstrated_wk then 'BELOW_FLOOR' else 'IN_BAND' end as acceptance,
       round(o.order_value / nullif(d.demonstrated_wk, 0), 2) as order_over_demonstrated,
       round(o.order_value / nullif(l.ledger_budget, 0), 2) as order_over_rail
from ord o
left join dem d on d.store_code = o.store_code
left join led l on l.store_code = o.store_code
order by o.store_code;
```

Reading it. This is the ENG-013 acceptance as PM wrote it: weekly desk value between the demonstrated 28-day cost demand and the route budget. If `ceiling_ledger_remaining` is below `floor_demonstrated_28d_wk`, the band is inverted and no order can pass. That alone would show the rail is wrong, not the order. `order_over_demonstrated` is the number to take to Pieter.

**How the reads decide the fix.**

| What R3, R4 and R5 show | Case | Meaning |
|---|---|---|
| Engine demand near `wk_cost_28d`, rail under 75% of it, order 2.0 to 2.6 weeks of engine demand | A | Rail low and the formula high. Both parts apply (E2, E5) |
| Engine demand over 1.3 times `wk_cost_28d` | B | Rates inflated. Read the pantry correction and family draw before anything else |
| Engine demand, rail and demonstrated all within 25% and the order 2.0 to 2.6 weeks | C | Formula only. Item 3b trims a third. The rest is the band formula ruling (Pieter's options a, b, c, `BUG-LOG.md:2729` as cited in DESKPARITY section 7.5) |
| R5 ratio far from 1.0 on the pack basis | D | A unit error in `pack_cost`. Fix the link cost basis first |
| `weeks_of_engine_demand_ordered` above 3 with many zero-stock or `count_first` lines | E | Stock position or count problem. Read the lines before the rule |

## 6. Fix design, in order

Nothing here is applied. Each edit waits for the 20:00 reads and, where noted, a PM ruling. The build lane is the builder's. `src/app/bloom/` is the builder's alone (`SB-PM-CLOSE...md:66`). Every migration follows the project pre-flight: overload check first, `md5(prosrc)` pin with asserted replaces, grants named, apply outside 22:00 to 03:00.

**E1. Retire the legacy path. No-regret. Gate: Pieter's walk of the SAB desk inside Desks (commit `f1a69b8`).**

- `src/app/bloom/page.jsx:3443`: remove the `desk` option. `:3451`: remove the render line. Keep `DeskMode` (`:586-785`) in the file with a lineage comment (`retired_on`, `superseded_by`, R28) or delete it on PM's yes.
- New file `sql/eng013_revoke_legacy_direct_beer.sql`: R7d must show one overload. `REVOKE EXECUTE ... FROM PUBLIC`, then `FROM anon, authenticated` by name. Keep the function and its COMMENT. Never drop (R28). Update the header of `sql/create_rpc_bloom_order_direct_beer.sql:1-9`.
- `rpc_bloom_direct_beer_flags` (`page.jsx:620`) has no other caller. Leave it live until PM rules its scope (ENG-033 named gap).
- Test: R7a returns false and false. The nav shows one beer entry. The build passes. Size small, risk low.

**E2. Item 3b, already written (`sql/bloom035_item3b_days_to_truck.sql`).** No new edit. The 20:30 simulation gives the beer effect in R9b. Expected, not measured: a cut of about 22 to 33% at the two weekly beer desks. It will not close 4.7 to 6.3 times alone.

**E3. 21355 calendar and lead. Only if R2 confirms {5,6} with a `floor_attested` basis.** Build steps 1 and 2 of ENG-110 add.2 as PM specified (`BUG-LOG.md:1395-1397`).
- Remove the ENG-160 skip in `refresh_supplier_calendar_cutoff` and the verbatim `delivery_dows` keep in `refresh_supplier_calendar` (REGISTERS section H1). The source file is `sql/eng160_attested_cutoff_survives_rederivation.sql`.
- Delivery day reads `invoice_date` where it is a real date, `grv_date` as fallback. PM's falsifier: 21355 SAB comes out Friday, 80176 Tuesday.
- R22 per store in rands on the two SAB desks, before and after, as `lead_days_used`, lines and value. No recipe edit.
- This moves the 21355 sheet up by 3 times or more if the lead goes 1 to 7 (M6). It needs PM's go. Open question 5.

**E4. Buying-point demand at 21355. Only after PM answers questions 1 and 2. Design sketch, needs its own brief.**
- The test already exists in canon D8: dispatch units over GRV units, with a config threshold (`ORDERING-CANON-BUDGETS.md:111`). No store list.
- Where a store passes the test for a supplier, the desk's demand adds the dispatch units per day for the pool products. The natural home is the pantry as an appended column, after the compute (the append-after-compute pattern). The anchor is `sql/create_l2_bloom_ros_pantry.sql:366-376`, which reads K only. The recipe reads the new column at `create_rpc_bloom_order_recipe.sql:625-632`.
- The rail needs the same leg, in units times cost per unit, never the S/M rand (D8, about 12 times). Anchor `sql/create_l2_sales_budget.sql:140-192`.
- Hazards. Double count with the Dice desk (M7). R22 across 21355 and 80579 together: the two desks must sum to one SAB need. Rand on S legs barred.

**E5. The rail. Only if R3b and R10 show the rail under demonstrated demand, and PM allows.** Options, each a NEEDS-canon change:
- (a) a trailing-sales fallback for LY-blind lines (the named limit at `create_l2_sales_budget.sql:33-38`)
- (b) a floor at trailing demonstrated demand for DIRECT_BEER only
- (c) both.
Anchor `create_l2_sales_budget.sql:182-191`. Use the pinned asserted-replace pattern of `sql/bloom035_item2_fit_own_need.sql:31-49`. R22 the ledger fingerprint at all five stores, because `refresh_l2_sales_budget` writes every route (`:241-256`). Do not touch the ratio config key (`purchases_to_sales_ratio_cost_basis`, 1.00) without PM.

**E6. A standing check instead of a one-off read. Proposal.** Save R10 as a read-only function or add a direct-desk basis to `rpc_bloom_stored_overview`. The benchmark for direct desks is not ruled (`create_rpc_bloom_scenario_overview.sql:37-49`), so this waits on question 3.

**E7. Close the row.** `BUG-LOG.md:138` is 95 days old by the calendar (11-07 to 14-10) and still reads "OPEN, CC, before Monday". After the reads, add an "ENG-013 addendum 1" block (none exists today) with the per-desk verdict and R10 table. Link it from the row.

**Do not do.**
- Do not trim the protected set to fit the rail. Canon funds the floor first and PM item 3 ruled "a reading, not a ruling yet" (`SB-PM-CLOSE...md:515`).
- Do not re-add merch-group scope to the beer pool. ENG-033 retired it on Pieter's ruling.
- Do not run R3 to R6 or R10 before 20:00 or after 22:00.
- Do not apply anything between 22:00 and 03:00.

## 7. Open questions for PM

1. **How does Dice get SAB today?** By supplier delivery to Dice, or by transfer from 21355? If by transfer, is the Dice desk R90,020 a sheet nobody can place? Should it be held? This is Pieter's "80579 SAB reopen".
2. **For a buying-point desk, is demand sales plus transfers out?** If yes, the ENG-013 floor at 21355 must be restated as till plus dispatch, and E4 needs a brief.
3. **Does the restated acceptance ("shown OVER") stand for beer?** It passes 80176 and 80579 at 6.3 and 4.7 times the rail. I suggest a hard flag for any desk whose order is above N times its rail, with N to be ruled. It also needs a ruled benchmark for direct desks, because `DEFECT_SIGNAL` is held there.
4. **Which of Pieter's options (a), (b) or (c) is the minimum band?** Item 3b fixes the depletion half only. The band's own use of the drop gap as cover and review is still unruled (DESKPARITY section 7.5).
5. **21355 delivery days: Friday only, per the ledger, or Friday and Saturday, per Pieter on 01-09?** May CC build ENG-110 add.2 steps 1 and 2? If the row is still {5,6} it moves the 21355 sheet up by 3 times or more.
6. **May the rail have a floor at trailing demonstrated demand for DIRECT_BEER?** Or a trailing fallback for LY-blind lines? The ratio is 1.00 by config and the demonstrated ratio is 0.954 at 80176.
7. **When does the "SAB Direct (beer)" tab retire?** Pieter's walk is the stated gate. Who books it? And what happens to `rpc_bloom_direct_beer_flags` and its merch-group scope?
8. **Pieter's own eye on 80176.** Does R210,145 look like a month of SAB to him? July receipts were R214,887.49. His floor judgment is the cheapest test of direction and it can be done before 20:00.
9. **What closes ENG-013?** My suggestion: (1) the legacy tab is gone, (2) R10 is in band, or shown OVER with the cause named per desk, (3) the 21355 floor is restated and the Dice route is ruled. PM owns the wording.

## 8. What I could not settle from the repo

- Today's demonstrated weekly cost at all three desks. R3a.
- The engine's own weekly demand for the pool. R4.
- Whether the rail is low or the order is high at 80176. R3b and R4 together.
- The calendar and the lead on the cached sheets. R1 and R2.
- The live grants and any use of the legacy function. R7.
- Whether `list_cost` is per pack or per unit on beer links. R5.
- Whether SAB delivers to Dice. R8.

## 9. What I read

Read in full:
- `sql/create_rpc_bloom_order_recipe.sql` (1,100 lines). `md5(prosrc)` of its body is `f2fb054f...` / 46,427 chars, equal to the pin in `sql/bloom035_item3b_days_to_truck.sql:45`.
- `sql/bloom035_item2_fit_own_need.sql`, `sql/bloom035_item3b_days_to_truck.sql`, `sql/create_l2_sales_budget.sql`, `sql/create_refresh_order_budget_ledger_needs.sql`, `sql/create_rpc_bloom_order_direct_beer.sql`, `sql/create_rpc_bloom_budget_context.sql`, `sql/create_order_budget_ledger.sql`, `sql/create_order_budget_ledger_sab_weekly_seed.sql`, `sql/create_order_budget_ledger_weekly_grain.sql`, `sql/eng185_dice_sab_desk.sql`, `sql/create_rpc_bloom_next_deliveries.sql`.
- `scratch/README.md`, `scratch/readback_item2_own_need.sql`, `scratch/sim_item2_route_grain.sql`, `scratch/sim_item3b_days_to_truck.sql`.
- `Daisy\Bloom\SB-CC-DESKPARITY-001_Desk-Parity-Table_2026-10-05.md`, `Daisy\SQL-CONVENTIONS.md`, `Daisy\BUG-LOG-2026H1.md` line 74 (the ENG-033 row).

Read in part:
- `Daisy\BUG-LOG.md`: rows and lines 138, 209, 249, 251, 424, 1100-1107, 1140-1161, 1340-1416, 3240-3314.
- `Daisy\ORDERING-CANON-BUDGETS.md`: lines 46-50 and 96-120 (D8). Section D1 to D7 and D9 onward not read in full.
- `Daisy\Bloom\SB-PM-CLOSE_2026-10-14_Platform-Lane-State-and-Next-Moves.md`: lines 54-67 and 508-519 only.
- `Daisy\HANDOVER-CURRENT.md`: lines 50-65, 77, 101.
- `sql/create_bloom_order_cache.sql` (lines 56-96, 395-464), `sql/create_l2_on_order.sql` (20-60), `sql/create_bloom_route_config_cadence_rederive.sql` (1-80), `sql/create_rpc_bloom_scenario_overview.sql` (1-60, 150-250), `sql/create_l2_bloom_ros_pantry.sql` (360-390).
- `src/app/bloom/page.jsx`: lines 40-80, 410-440, 505-535, 586-670, 3319-3459, and greps. Not the rest.
- `Daisy\PIETERSTYLE.md`: lines 1-140.
- git: `f1a69b8` message and `origin/main` at `6fdb8af` for the tab.

Not read:
- `Daisy\RULE-BOOK.md` (R28 section 5 and R22 taken from the project instructions), `ORDERING-CANON.md` in full, `ORDERING-CANON-REGISTERS.md`, `ORDERING-CANON-LEDGER.md`, `DB-SCHEMA.md`, `PROJECT-LEXICON.md`, `FILE-GOVERNANCE.md`, `NORTH_STAR.md` and the rest of the 25-file start-load.
- `sql/create_refresh_order_budget_ledger.sql`, `sql/create_rpc_bloom_direct_beer_flags.sql`, `sql/create_rpc_bloom_delivery_budget.sql`, `refresh_bloom_order_cache` body in full, `rpc_bloom_order_cached`, `rpc_bloom_stored_overview`, `refresh_supplier_calendar*`, `rpc_derive_*`.
- BUG-LOG rows ENG-117, ENG-025, ENG-048 (they mention DIRECT_BEER in passing), ENG-110 add.3 beyond line 1416, and any BUG-LOG text written after the 14-10 15:3x handover block.
- Anything on the live database. The calendar rows, grants, caches and ledger rows are quoted from repo files and BUG-LOG, and are as old as those files.
