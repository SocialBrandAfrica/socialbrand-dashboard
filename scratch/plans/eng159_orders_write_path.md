# ENG-159 build plan: the order submission write path

**Prepared:** 14-10-2026 16:2x SAST (system clock read 16:21 and 16:24, UTC 14:21). Seat: CC, preparation only.
**Status:** nothing built, nothing applied, no database touched, no file edited except this one.
**Repo state read:** worktree `stocktake-count-app-build-6f61e0`, HEAD `6fdb8af`. This branch is 43 commits ahead of `main` (`6a5f87d`). Every line number below is for this HEAD, so they differ from the line numbers in BUG-LOG addendum 1.
**Evidence class:** DEDUCTIVE from the repo and BUG-LOG. Whole population of the files named in section 7. Nothing here was measured on the live database. Every live fact is carried as an exact read in section 8 for the 20:00 window.
**Scoped start-read:** yes. I did not run the 25-file canon recital. Section 7 lists what I read and what I did not.

---

## 0. The short version

1. **No wiring exists.** The only reachable Submit button sets a local flag (`src/app/bloom/page.jsx:3305`). Nothing in `src/` calls `rpc_bloom_submit_order` or `rpc_bloom_order_status`. A grep of `src/`, `scripts/` and `public/` returns zero hits.
2. **The write path fails at four places, in this order.** No `user_profiles` row. Role words that no allowed role matches. A route CHECK that rejects the calendar's keys. A contract that cannot hold the engine figure. Section 1 has the chain with file and line.
3. **It is not a grant or a table problem.** EXECUTE is granted to `authenticated` (`sql/create_rpc_bloom_submit_order.sql:111`). SELECT is granted on both tables (`sql/create_orders_header.sql:62-63`). Both tables exist.
4. **The build is two migrations, one code change and one acceptance walk.** M1 is PM-15 parts 1 and 2 as ruled, plus three small columns that Q10 asks PM to confirm. M1 does not touch the access model. M2 holds the writer, the policies and the profile row. M2 touches the access model, so it waits for PM.
5. **One PM-15 word cannot be built as written.** PM-15 part 2 says `orders.cache_id` references `bloom_order_cache.cache_id`. The nightly builder deletes that exact cache row every night (`sql/create_refresh_bloom_order_cache.sql:70-73`). A hard foreign key would stop the nightly rebuild of every desk that has an order, or erase the link, or erase the order. The default in this plan is a plain `bigint` plus a snapshot of the sheet's facts. Question 3 asks PM.
6. **Do not feed `orders` into `committed_amount` in this build.** The NEEDS refresh already sets it to landed plus in-transit (`sql/create_refresh_order_budget_ledger_needs.sql:136-225`) and the recipe's fit subtracts it (`sql/create_rpc_bloom_order_recipe.sql:485`). Writing orders into it would double count and would move engine quantities.
7. **No API route.** Every Bloom call goes from the browser to PostgREST as the signed-in user. A route would need the middleware changed first, or an expired session would read as a saved order (section 3.4).
8. **What can start today** is in section 3.0. Nothing touches the live database before 20:00 SAST.

---

## 1. The exact failure of the write path today

### 1.1 The chain, in the order a press would hit it

Suppose the button were wired to the writer as it stands. This is what the call meets.

| # | Where | File and line | What happens | Checked how |
|---|---|---|---|---|
| F0 | The button | `src/app/bloom/page.jsx:3305-3307` | `onClick={() => setSubmitted(true)}`. The label flips to "Submitted" and the footer says "Order locked." (`:3295`). No call leaves the browser. | Read. Grep for the RPC names in `src/` returns nothing. |
| F1 | Sign-in | `sql/create_rpc_bloom_submit_order.sql:37-39` | `auth.uid()` is set by the browser session (`src/lib/supabase.js:14`). This step passes. | Read. |
| F2 | Profile lookup | `sql/create_rpc_bloom_submit_order.sql:41-46` | `SELECT role, store_code ... FROM user_profiles WHERE id = v_uid`. With no row it raises `no user_profiles row for this account`. BUG-LOG addendum 1 counted 0 rows against 1 `auth.users` account on 14-09. | The code is read. The row count is not re-measured (read L1). |
| F3 | Role gate | `sql/create_rpc_bloom_submit_order.sql:48-57` | Branches on `branch_manager`, then `admin` and `town_manager`, else raises `unrecognised role`. The table's CHECK allows `owner`, `manager`, `shift_manager`, `store_manager`, `area_manager` (`sql/_archive/mobile_auth_setup.sql:24`). The two sets share no word. A profile row alone does not help. | Both read. The live CHECK is not re-read (read L3). |
| F4 | Route CHECK | `sql/create_orders_header.sql:22` | `CHECK (route_key IN ('DC','DIRECT','DIRECT_BEER'))`. The desk screen sends `desk` from `rpc_bloom_desks`, which returns calendar keys such as `DC_AMBIENT` (`sql/create_rpc_bloom_desks.sql:94-124`). Addendum 2 counted 8 of 9 keys rejected on 20-09. Since then `DC_FRESH` and `DIRECT_CATCHALL` desks exist (`sql/bloom035_1b_dc_fresh_phase0.sql:69-71`, `sql/bloom035_eng202_catchall_desk.sql:60`), so the live number is higher. | Read. Live count in read L8. |
| F5 | The edit is lost | `sql/create_rpc_bloom_submit_order.sql:92` and `sql/create_orders_header.sql:41-56` | The writer keeps only `qty_packs > 0`. `order_items` has no engine column and `orders` has no cache pointer. A removed line leaves no row. A changed line keeps only its final quantity. | Read. |
| F6 | Read-back is blind | `sql/create_orders_header.sql:70-87` | The SELECT policies admit `admin` or `town_manager` or a matching `store_code`. An `owner` or `area_manager` account reads 0 rows and gets no error. | Read. |
| F7 | Status writer | `sql/create_rpc_bloom_order_status.sql:41,59,62` | Same three role words. It fails the same way as the submit writer. | Read. |

**Never run past F2.** DEPLOY-LOG records that the full round trip was never exercised for lack of a seeded profile (`DEPLOY-LOG.md:2718`). So the INSERT section of the writer (`:63-104`) has never executed on the live database. I found no defect in it by reading, but "found none" is not "proven". The rolled-back call in section 5 is the proof.

**What is not the cause.** No missing grant. No missing table. No missing function. BUG-LOG ENG-159's first row says the same (permissions were checked before the claim).

### 1.2 Addendum 1 checked against the repo

| Addendum 1 says | Repo says at HEAD `6fdb8af` | Verdict |
|---|---|---|
| Three `Submit order` buttons are local flags. DC sheet at 3433, others at 1316 and 3602. | The live Desks sheet is at `page.jsx:3305` (`setSubmitted(true)`). The other two are at `:1267` (RecipeMode, `onSubmit={() => setPhase('C')}`) and `:3474` (the old DC mode, same call). The line numbers moved because the file shrank. | **Holds, with one correction.** The third button is the old DC mode, not a "direct-beer sheet". The reachable beer screen (`DeskMode`) has only "Export CSV" (`:754`) and no Submit. |
| Only the first is reachable | Nav offers only `desks` and `desk` (`:3440-3444`). `appMode` starts at `desks` (`:3331`). RecipeMode is "NOT reachable" by its own comment (`:1176-1179`). The old DC mode has no nav entry. | **Holds.** One live Submit button, not three. |
| Nothing in `src/` calls the two RPCs | Grep of `src/`, `scripts/`, `public/`, `package.json`: zero hits. In `sql/` only the three defining files name them. | **Holds.** |
| `user_profiles` holds 0 rows, nothing writes it | The only `INSERT INTO user_profiles` in the repo sits inside a comment block in `sql/_archive/mobile_auth_setup.sql:78-99`. No trigger or function writes it in any repo file. | **Holds for the repo.** The live trigger list is read L9. The row count is read L1. |
| The dashboard treats the row as optional (`src/app/page.jsx:1279`) | Now `src/app/page.jsx:1456-1473`. A missing row becomes a synthetic `owner` profile. `memory/auth_phase1_super_admin.md:11-12` records the 2026-05-24 decision. | **Holds.** Line moved. |
| Writers branch on `branch_manager`, `admin`, `town_manager` and the CHECK allows five other words | `create_rpc_bloom_submit_order.sql:48,53,56`, `create_rpc_bloom_order_status.sql:41,59,62`, `create_orders_header.sql:75,85`. CHECK words in `mobile_auth_setup.sql:24`. The three writer words appear nowhere else in the repo except `DEPLOY-LOG.md` and the policies file. | **Holds.** |
| `orders.route_key` CHECK allows 3 keys and 8 of 9 calendar keys fail | `create_orders_header.sql:22`. | **Holds.** Count is now stale (F4). |
| The writer keeps only `qty_packs > 0` and carries no engine figure and no cache | `create_rpc_bloom_submit_order.sql:92`, `create_orders_header.sql:41-56`. | **Holds.** |
| `orders` and `order_items` hold 0 rows, `n_tup_ins` 0 | Not checkable without the database. | **Read L1 and L2.** |

### 1.3 What addenda 1 and 2 did not name

These are new findings from reading the screen and the cache. Each changes the build.

1. **The sheet's date, preset and fit inputs do not reset the sheet.** `generated` is cleared only on a store or desk change (`page.jsx:1674`, `:1724`) and at the start of Generate (`:1942` clears `submitted` only). The two date inputs (`:2435`, `:2440`), the preset control (`:2445`) and the fit control (`:2454`) change state and leave the old sheet on screen. A press that sends the input boxes would record the wrong date against another date's lines. **Rule:** the press sends the sheet's own identity, taken at Generate from the cache header, never the input boxes.
2. **The cache id is already on every served line.** The reader returns `to_jsonb(l)` of `bloom_order_cache_line` (`sql/create_bloom_order_cache.sql:316-319`), and that table carries `cache_id` (`:73`). So the page can read `cache_id` from a served line today, and the reader needs no patch. It does not return `engine_md5`, so the writer looks that up by `cache_id`.
3. **The nightly builder deletes and re-inserts the sheet.** `sql/create_refresh_bloom_order_cache.sql:70-73` deletes the row for the same store, route, delivery, next delivery, preset and fit, then inserts a new one with a new `cache_id`. The lines table cascades (`create_bloom_order_cache.sql:73`). The repo copy of this function is behind live (it lacks the E1 step 3b that `sql/bloom035_e1_cache_rows.sql` added), but the E1 patch does not touch the DELETE. Read L7 confirms the live body.
4. **The lock is cosmetic.** After "Submitted" only Import and Submit are disabled (`:3302`, `:3305`). The quantity inputs stay editable (`:1555-1562`). A buyer can edit after the press and export a file that differs from the recorded order. The record must equal the export (R22).
5. **No duplicate guard.** The only unique index is on `order_items` (`create_orders_header.sql:57`). Two presses make two orders. So does a retry after a dropped connection.
6. **A cancel path exists in the database but not on the screen.** `rpc_bloom_order_status` can cancel (`create_rpc_bloom_order_status.sql:50-65`). A wrong press cannot be undone from the page.
7. **`create_orders_header.sql:16` is `DROP TABLE IF EXISTS public.orders CASCADE`.** Re-running that source file after rows exist erases `orders` and `order_items`. It needs a refusing guard or retirement with lineage at the re-sync (R28).
8. **The pre-build gate.** `package.json` runs `scripts/rls-guard-gate.mjs` before every build. It fails the build on a NEW or CHANGED silent read site (`sql/create_rpc_forge_rls_guard.sql:73-98`). After the policy rewrite `authenticated` must still hold a policy on both tables, or the next deploy stops.
9. **A third reader gap.** With RLS on, a signed-in account without a profile reads `orders` as empty with no error. The guard names this as its limit (`create_rpc_forge_rls_guard.sql:27-28`). The page must read orders only through a published function that raises, never from the table.

---

## 2. What PM-15 requires, as tests

Source: BUG-LOG ENG-159 addendum 2 (`BUG-LOG.md:2212-2238`) with addendum 1 proposals 1 to 5 (`:1852-1857`). Test ids are mine. A test passes or fails on a query or a page read.

### Route, by reference to the calendar (PM-15 part 1)

| Id | Rule | Test |
|---|---|---|
| RT-1 | The typed CHECK on `orders.route_key` is gone. | `pg_constraint` for `public.orders` holds no CHECK whose definition names `route_key`. |
| RT-2 | `(store_code, route_key)` is a foreign key to `supplier_calendar (store_code, route_key)`. | `pg_constraint` shows `contype='f'`, `confrelid = supplier_calendar`, `conkey` = those two columns. The calendar's primary key is the same two columns (read L3). |
| RT-3 | Every desk the screen can offer is accepted. | For each row of `rpc_bloom_desks()` that has an open sheet, a rolled-back writer call with that desk's `cache_id` reaches the INSERT with no route error. Expected 0 rejected of N. |
| RT-4 | A route that is not on that store's calendar is refused by the foreign key, and no row is written. | The writer checks the sheet before the INSERT, so a bad route stops there with a different message. Test the constraint itself: a direct INSERT as the owner inside a rolled-back block with `('10116','NOT_A_ROUTE')` raises `23503`. Second probe: `80579` with `DIRECT_BEER`, which canon A1 says is deliberately absent (`create_rpc_bloom_desks.sql:28-33`). |
| RT-5 | A desk born tomorrow works with no edit to `orders` or the writer (the store-number-six test, R25 section 6). | Inside a rolled-back block insert one calendar row and one `bloom_order_cache` header row for a new route, then call the writer for it. Expect success. |
| RT-6 | The writer body holds no typed route list. | `pg_get_functiondef` of the writer contains none of `DC_AMBIENT`, `DC_TOPS`, `DC_FRESH`, `DIRECT_`. Count is 0. |

### A line persists where the engine or the buyer is above zero (PM-15 part 2)

| Id | Rule | Test |
|---|---|---|
| LN-1 | A line persists if and only if `engine_packs > 0 OR qty_packs > 0`. | Probe with four lines: (e5,q5) (e5,q0) (e0,q3) (e0,q0). Expect 3 rows. The (0,0) line is absent. |
| LN-2 | A removal persists as `qty_packs = 0` with its engine figure. | The (e5,q0) row exists with `engine_packs=5`, `qty_packs=0`, `line_value=0`. |
| LN-3 | An addition persists with `engine_packs = 0`. | The (e0,q3) row exists. |
| LN-4 | `qty_packs >= 0` stays. A negative is refused with a plain message, not a raw cast error. | Probe with `qty_packs = -1` raises. |
| LN-5 | `orders.line_count` is the number of lines with `qty_packs > 0`. `total_value` is the sum of `line_value`. Both are computed from the stored rows. | After the probe: `line_count = count(*) filter (where qty_packs>0)` and `total_value = sum(line_value)` on `order_items`. |
| LN-6 | The header carries the sheet: `cache_id`, its `engine_md5` and `generated_at` as at the press. | Header columns are populated and equal the `bloom_order_cache` row while it exists. |
| LN-7 | The three counts are readable from the two columns. Added is `engine=0, qty>0`. Increased is `engine>0, qty>engine`. Decreased is `engine>0, 0<qty<engine`. Removed is `engine>0, qty=0`. | One query on `order_items` returns the four counts. They equal the counts the page computed from its own state (walk step W2 and W4). |

### The success state is the RPC's return (PM-15 part 3, addendum 1 item 4)

| Id | Rule | Test |
|---|---|---|
| OK-1 | `setSubmitted(true)` runs only after the awaited RPC returns a row with a non-null `order_id`. | Code review: one `setSubmitted(true)` in the submit path and it sits after the check. Grep proves it. |
| OK-2 | On any error the sheet stays unlocked and the RPC's message shows on the page. | Walk step W3a injects one failed request. The footer shows the message, the button is live again and no row exists at source. |
| OK-3 | The returned total equals the screen's Running total to the cent. A difference shows loudly and is not hidden. | Walk step W3 compares the two. |
| OK-4 | After a recorded order the quantity inputs and Import are locked, so the export equals the record. | Walk step W5: inputs read-only. |
| OK-5 | The buttons stay unwired until M1, M2 and the profile row are applied and proven. | Deploy order in section 3.6. |

### The access model (addendum 1 item 1, PM-15 homework note)

| Id | Rule | Test |
|---|---|---|
| AX-1 | Every role word in the writers, the helper and the policies is a member of `user_profiles_role_check`. | Query: words in the function bodies and `pg_policies` for `orders` and `order_items` minus the CHECK's set is empty. The words `admin`, `town_manager`, `branch_manager` occur 0 times. |
| AX-2 | The account that presses can write. | Rolled-back call as Pieter's uid returns a row. |
| AX-3 | A role that may not place orders is refused, and a store-tier role is refused for another store. | Rolled-back probes as a `shift_manager` and as a `store_manager` of a different store. Both raise. |
| AX-4 | The account that wrote the order can read it back through the policy and the reader function. | Rolled-back call, then SELECT as the same claims inside the block returns the row. |

---

## 3. The build, as ordered edits

### 3.0 What can start today, and what waits

Everything below is a file in the repo until the 20:00 window. Nothing runs on the live database before 20:00 (Pieter's rule 14-10, `scratch/README.md:5`).

**Can start now, no ruling needed:**
- Write `sql/eng159_m1_orders_contract.sql` (PM-15 parts 1 and 2, as ruled).
- Write the pure helper `src/app/bloom/orderRecord.js` (build the line array, compare totals).
- Write the page changes C1 to C7 against a branch. They stay unmerged.
- Write the proof probes (section 5) as files in `scratch/`.
- Run `next build` locally. The prebuild gate needs the live public key. Run it only after 20:00.

**Waits for PM:**
- M2 apply: the role map (Q1), the duplicate rule (Q5), the profile row (Q2).
- The `cache_id` foreign key wording (Q3). M1 is written with the plain column default and can be switched in one line.

**Holds on Pieter's word:** the profile row's role word, and which real order is the first press.

### 3.1 M1: `sql/eng159_m1_orders_contract.sql` (ruled, no access change)

Apply in the 20:00 to 22:00 window. The pipeline job was scheduled at 20:15 UTC, which is 22:15 SAST (`create_bloom_order_cache.sql:465-466`, an August comment, so confirm the schedule in read L12 first). Set `lock_timeout = '5s'` so a lock the pipeline holds makes it fail fast and not queue (same precedent as `bloom035_1b_dc_fresh_phase0.sql:64`).

Pre-flight inside the file, each one a `RAISE EXCEPTION` if false, so nothing applies on a wrong assumption:
1. `orders` and `order_items` hold 0 rows.
2. Exactly one CHECK on `orders` names `route_key`. Find it by definition, not by assumed name.
3. `supplier_calendar`'s primary key is `(store_code, route_key)`.
4. `pg_proc` holds exactly one `rpc_bloom_submit_order`.

Edits, in order:

```sql
-- 1. drop the typed list (PM-15 part 1)
DO $drop$ DECLARE c text; BEGIN
  SELECT conname INTO STRICT c FROM pg_constraint
   WHERE conrelid = 'public.orders'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) ~ 'route_key';
  EXECUTE format('ALTER TABLE public.orders DROP CONSTRAINT %I', c);
END $drop$;

-- 2. route by reference to the calendar
ALTER TABLE public.orders ADD CONSTRAINT orders_store_route_fk
  FOREIGN KEY (store_code, route_key)
  REFERENCES public.supplier_calendar (store_code, route_key);

-- 3. the sheet the press came from (PM-15 part 2). Plain column, see Q3.
ALTER TABLE public.orders
  ADD COLUMN cache_id           bigint,
  ADD COLUMN cache_generated_at timestamptz,
  ADD COLUMN engine_md5         text,
  ADD COLUMN fit_to_budget      boolean,
  ADD COLUMN basis              text CONSTRAINT orders_basis_ck CHECK (basis IN ('normal','geared'));

-- 4. the engine's figure beside the buyer's
ALTER TABLE public.order_items
  ADD COLUMN engine_packs integer NOT NULL DEFAULT 0
      CONSTRAINT order_items_engine_packs_ck CHECK (engine_packs >= 0),
  ADD COLUMN line_kind    text;   -- provenance copied from the sheet, no CHECK, no typed list

COMMENT ON COLUMN ... ;           -- one per new column, with the rule that defines it
SELECT pg_notify('pgrst', 'reload schema');
```

Notes:
- `source` and `status` stay typed. PM-15 says they are our vocabularies.
- `fit_to_budget`, `basis` and `line_kind` go beyond the ruling. They are small and they make the stored sheet readable once its cache row is gone. Q10 asks PM to confirm them.
- The foreign key has one side effect: a calendar row that has an order cannot be deleted. The REVERSE steps in `bloom035_eng202_catchall_desk.sql:22-23` and `bloom035_1b_dc_fresh_phase1.sql:23` delete calendar rows. They would fail once an order exists for that route. That is the point of the constraint, but name it in DEPLOY-LOG.
- Calendar writers all use `INSERT ... ON CONFLICT DO UPDATE` in the files I read (`bloom035_eng202_catchall_desk.sql:118-130`, `create_refresh_supplier_calendar.sql:41,51`). None deletes. Read L9 checks the live bodies for a `DELETE FROM supplier_calendar`.
- REVERSE: drop the four header columns and two line columns, drop the FK, re-add `CHECK (route_key IN ('DC','DIRECT','DIRECT_BEER'))` (only valid while no row has another key).

### 3.2 M2: `sql/eng159_m2_writer_policies.sql` (touches the access model, PM first)

**Pins.** Before replacing anything, assert the live md5 of `rpc_bloom_submit_order`, `rpc_bloom_order_status` and the two policies' definitions equals the repo source. Pins come from read L6. Hash-gate against the repo files, normalised on both sides.

**Overload trap.** The writer's signature changes, so `CREATE OR REPLACE` would leave the old seven-argument function standing. Drop it first, in the same transaction, then assert `pg_proc` holds one. The old call and the new call must not both be resolvable.

**New objects and replaced objects, in order:**

| # | Object | Signature or change | Why |
|---|---|---|---|
| 1 | `public.bloom_order_role_rule(p_role text)` | `RETURNS TABLE(visibility text, can_submit boolean, self_confirms boolean)`, `LANGUAGE sql IMMUTABLE`. One row per allowed role, no row for an unknown word. EXECUTE to `authenticated` only. | One home for the role map. The writer, the status function, the reader and both policies call it (R30 addendum 3: a rule with two homes drifts). **Access model: PM.** |
| 2 | `public.rpc_bloom_submit_order` | `(p_store_code text, p_route_key text, p_delivery_date date, p_next_delivery_date date, p_source text, p_preset text, p_lines jsonb, p_cache_id bigint, p_basis text DEFAULT NULL)` returns `(order_id uuid, status text, total_value numeric, line_count integer, persisted_line_count integer, added_count integer, increased_count integer, decreased_count integer, removed_count integer)`. SECURITY DEFINER, `SET search_path = public`. `REVOKE ALL FROM PUBLIC`, `REVOKE ... FROM anon`, `GRANT EXECUTE TO authenticated`. | The writer. Steps below. |
| 3 | `public.rpc_bloom_order_status` | Same signature `(uuid, text, text)`. Role tests move to the helper. | F7. |
| 4 | Policies `orders_select_by_role`, `order_items_select_by_role` | Drop and recreate. `visibility = 'ALL'` or `up.store_code = orders.store_code`. Still `TO authenticated`. | F6. **Access model: PM.** |
| 5 | `uq_orders_one_active_drop` | `CREATE UNIQUE INDEX ... ON public.orders (store_code, route_key, delivery_date) WHERE status <> 'cancelled'` | Q5. Default on. |
| 6 | `public.rpc_bloom_order_get(p_store_code text, p_route text, p_delivery_date date)` | `RETURNS jsonb`, `STABLE SECURITY DEFINER`. Returns the active order for that drop with status, total, line counts, who (yes or no for "you"), when, cache id. Raises for a caller with no profile. EXECUTE to `authenticated` only. | The page reads through a function, never the table (R30 section 1). It answers the 01-09 open question: is the locked state stored anywhere. |

**The writer's steps.** Each failure is a `RAISE EXCEPTION` with a plain sentence. The page shows that sentence.

1. `auth.uid()` is not null, else `not authenticated`.
2. A `user_profiles` row exists, else `no user_profiles row for this account` (kept word for word).
3. The role is in `bloom_order_role_rule` and `can_submit`, else `role % may not place orders`.
4. A store-tier role must have `user_profiles.store_code = p_store_code`, else a plain refusal.
5. The sheet exists. Look up `bloom_order_cache` by `p_cache_id`. If missing: `The stored sheet this order came from has been rebuilt. Generate again, then Import your file.` Its `store_code`, `route_key`, `delivery_date` must equal the arguments. `next_delivery` equals `p_next_delivery_date`. `preset` equals `coalesce(p_preset,'standard')`. Any difference raises and names the field. This closes finding 1.3 (1) on the server side too.
6. `p_lines` is a non-empty array. Every line has a `product_code`. `qty_packs` and `engine_packs` are whole numbers at or above 0. No product appears twice. Else a plain message that names the line.
7. Insert the header with `status` from `self_confirms` (`confirmed` or `draft`). Copy `cache_generated_at`, `engine_md5`, `fit_to_budget` from the sheet header. Store `basis`. A unique violation on `uq_orders_one_active_drop` is caught and re-raised as `An order for this drop is already recorded (status %, placed %). Cancel it first.`
8. Insert the lines where `engine_packs > 0 OR qty_packs > 0`. `line_value = qty_packs * coalesce(pack_cost,0)` computed here, never taken from the client.
9. If no line has `qty_packs > 0`, raise `nothing to order` and the header rolls back.
10. Set `total_value` and `line_count` from the stored rows. Return the row with the four counts.

**Build trap.** The names `order_id`, `status`, `total_value` and `line_count` are plpgsql variables inside this body because of `RETURNS TABLE`. Qualify every table column with an alias. The existing body already qualifies `order_items.order_id` (`create_rpc_bloom_submit_order.sql:101`). Do the same everywhere.

**Proposed role map, for PM to rule (Q1):**

| Role word | Visibility | Can submit | On submit |
|---|---|---|---|
| `owner` | all stores | yes | `confirmed` |
| `area_manager` | all stores | yes | `confirmed` |
| `store_manager` | own store | yes | `draft` |
| `manager` | own store | yes | `draft` |
| `shift_manager` | own store | no | not allowed |

Why this map. `owner` and `area_manager` take the place of `admin` and `town_manager`. `store_manager` and `manager` take the place of `branch_manager`. SB-VIS-001 section 6 (`SB-VIS-001_Product_Vision_and_Philosophy.md:81-83`) makes the shift manager read-only, so `shift_manager` cannot submit. `owner` and `manager` are not in SB-VIS-001's three tiers. They are the Phase 1 words (`sql/_archive/mobile_auth_setup.sql:24`, `memory/auth_phase1_super_admin.md`). Mapping `owner` to the top tier and `manager` to the store tier is my reading. PM confirms.

Because `owner` and `area_manager` get the same rights, the build does not wait on which of the two words Pieter's own row carries.

**The profile row (separate file, on Pieter's word).** `sql/eng159_m2b_profile_seed.sql` inserts one row into `user_profiles` for Pieter's account: `id` from `auth.users` (read L11), `email`, `full_name`, `store_code NULL`, the role word he chooses, `client_id` from `clients` (read L11). It is a write to a security table. It needs his word and PM's note. **Rejected alternative:** treating a missing profile as `owner` on writes, as the dashboard does (`src/app/page.jsx:1473`). That would let any Google account that can sign in place an order.

### 3.3 Code: `src/app/bloom/page.jsx` and one new module

Edits, in order. All in `OrderDesksMode` (`:1578-3314`) unless stated.

| # | Edit | Anchor |
|---|---|---|
| C1 | New state beside `submitted`: `submitting`, `placed` (the RPC's row), `submitError`, `existingOrder`, `sheet` (identity). Reset them wherever `setSubmitted(false)` is reset. | `:1598`, resets at `:1674`, `:1724`, `:1942` |
| C2 | At the HIT branch capture the sheet identity: `cacheId` from `payload.lines.find(l => l.cache_id != null)?.cache_id`, `deliveryDate` and `nextDelivery` from `payload.delivery_date` and `payload.next_delivery`, `preset`, `fitToBudget`, `generatedAt`. If there is no `cacheId`, the Submit button is disabled with the reason on screen. | `:2001-2007` |
| C3 | `submitOrder()`. Builds lines from `lines`, `qty`, and `lineQty(l, basis)` as the engine figure (the one JS home for the rule, `:70-74`). Calls `supabase.rpc('rpc_bloom_submit_order', {...})` with the sheet's dates, never the input boxes. Sets `submitted` only after a row with an `order_id` returns (OK-1). Compares the returned total with `total` to the cent and shows any difference (OK-3). On error sets `submitError` and leaves the sheet live (OK-2). After any failure it calls the reader to say whether an order now exists. | beside `exportTlx`, `:2244` |
| C4 | Reader effect: on store, desk, delivery date and `generated`, call `rpc_bloom_order_get`. Show "An order for this drop is already recorded" and disable Submit with that reason. | after the budget effects, `:1772` |
| C5 | Footer: busy label while `submitting`. The error line. After success the text is built from the return: order number (first 8 characters), status, line count, total. "Order locked." as a bare string goes. A "Cancel this order" control calls `rpc_bloom_order_status` with `cancelled` and a reason, then unlocks. Q6. | `:3292-3309` |
| C6 | Lock the grid after success: pass `locked` to `DeskOrderRow`, make the number input and the Normal/Geared select read-only, ignore `onQty` while locked (OK-4). | `:1383`, `:1555-1571`, `:2035` |
| C7 | Correct the two stale comments. The header says "no such RPC exists yet" (`:17-18`) and the manual-line note says persistence is out of scope (`:2061-2064`). | named lines |

**New module `src/app/bloom/orderRecord.js`.** Two pure functions: `buildOrderLines(lines, qty, engineQty)` and `reconcile(returnedRow, screenTotal)`. Pure so they can be checked with `node --test` without a browser. There is no test runner in `package.json`, so this is an option and not a requirement.

**What stays untouched.**
- `RecipeMode` (`:1118`) and the old DC mode (`:3354-3481`) keep their local-flag buttons. Both are unreachable. They carry no `cache_id`, so they cannot satisfy the contract. UX-003 keeps hidden modes (`page.jsx:1287-1289`). Q12 asks PM whether to retire them.
- `DeskMode` (the reachable beer screen) has no Submit and gets none.
- The exports (CSV, TLX, promo sheet) are unchanged.

### 3.4 No API route

The Bloom screen has no API route today. Every call is `supabase.rpc(...)` from the browser with the user's session (`page.jsx` passim, `src/lib/supabase.js:14`). The writer is SECURITY DEFINER and tests `auth.uid()` itself, so the browser call is safe and complete.

A route would add risk. `src/middleware.js:50-55` answers an expired session with JSON 401 only for `/api/stocktake/`. Any other path gets a redirect to the login page, which a `fetch` reads as a 200 page of HTML. The middleware's own comment names the result: an expired session looks like a saved count. A Bloom route would need that branch extended first. A direct RPC call returns a real error object instead.

If PM wants a route anyway (to hide the raw raise text, as `src/lib/stocktake/server.js:50-96` does for the count app), the pattern is there and the middleware branch is the first edit. I do not recommend it for this ship.

### 3.5 Records owed with the build

- `DB-SCHEMA.md:462-473`: rewrite the `orders` and `order_items` section. Retire "only `qty_packs > 0` lines persist" (`:471`), the route list (`:468`) and the role sentence (`:469`) with date and successor (R28).
- `sql/create_orders_header.sql`: add a refusing guard at `:16` or retire the file with lineage. Re-sync `create_rpc_bloom_submit_order.sql` and `create_rpc_bloom_order_status.sql` from live after apply, hash-gated.
- `DEPLOY-LOG.md`: one entry for M1, one for M2, one for the first press.
- `BUG-LOG.md`: ENG-159 addendum 3 (CC): built, applied, proven, with the counts. Status moves only after the walk.
- `ORDERING-CANON-REGISTERS` section H18: the ledger line for PM-15 is PM's to write. CC supplies the apply stamps.
- `Forge/SB-CC-ORDER-001` item 4: status.
- HANDOVER-CURRENT: CC's own block only. Read then Edit. Never Write.

### 3.6 Order of work and windows

| Step | When | What | Gate |
|---|---|---|---|
| 1 | Today, now to 20:00 | Write M1, M2, the helper, page changes C1 to C7, the probe files. Repo only. | `next build` is not run before 20:00 (the prebuild gate reads the live database). |
| 2 | 20:00, first minutes | Run reads L1 to L18. Pin the live bodies. | The pins equal the repo sources. |
| 3 | 20:00 to 22:00 | Apply M1. Re-run the constraint read. | RT-1, RT-2. |
| 4 | Same window, after PM's role ruling and Pieter's word | Apply M2, then the profile row. Run the rolled-back probes P1 to P12 (section 5.1). | RT-3 to RT-6, LN-1 to LN-5, AX-1 to AX-4. |
| 5 | Same window | `select * from rpc_forge_rls_guard_summary()`. Expect gate PASS, 0 new. | The build gate. |
| 6 | After the probes pass | Merge and deploy the page (apply, then merge, as `Bloom/CHANGELOG.md:20` records). Check the Vercel result through the GitHub commit-status API (gh is absent). | Build green. |
| 7 | Same window if time allows, else the next one | R31 walk (section 5.2) and the first real press. | OK-1 to OK-4, LN-6, LN-7. |
| 8 | Never | Between 22:00 and 03:00. Never on an order morning. Read L16 for which desks have a drop close. | Pieter's rules. |

If step 4 cannot finish in the window, apply nothing from M2. M1 alone is safe: the old writer is unreachable and fails at F2 as before.

---

## 4. What the order record carries

The stocktake and the ledger do not read `orders` today. I grepped `src/app/stocktake`, `src/lib/stocktake`, `src/app/api` and `sql/eng241_stocktake_count_app_core.sql`. The count app's delivery-day rule reads `supplier_calendar` (`eng241_stocktake_count_app_core.sql:976`). The ledger's committed figure reads Sigma, not `orders`. So these are the facts a later reader needs, and this build makes sure they are there.

| Fact a reader needs | Where it lives after the build | Notes |
|---|---|---|
| **Committed amount** | `orders.total_value`, at cost, equal to `sum(order_items.line_value)` (LN-5). Per line: `line_value`. | Same basis as the sheet's Running total. |
| **Expected landing date** | `orders.delivery_date`, taken from the sheet's own cache header. | `l2_on_order` calls the same fact `expected_landing_date` (`create_refresh_l2_on_order.sql:203-212`). A reader aliases it. No separate column in this build. Q13 asks whether promo lines can land on another date. |
| Following delivery (cover horizon) | `orders.next_delivery_date` | |
| When it was placed | `orders.created_at`, and `confirmed_at` for a self-confirmed order | BLOOM-032 Phase 4 wants a desk order counted from that moment (`SB-CC-BLOOM-032 ... v1.3:143`). |
| Which desk | `orders.store_code`, `orders.route_key` (a calendar key by foreign key) | The ledger route is derived from the route by the ledger's own mapping. That mapping already has five copies (`bloom035_eng202_catchall_desk.sql:171-220` patched five objects). A later reader must call one home and add no sixth copy. |
| What was ordered | `order_items.product_code`, `ean`, `description`, `pack_size`, `pack_cost`, `qty_packs`. Units are `qty_packs * pack_size`. | `ean` and `product_code` are the match keys for Sigma's order, the receipt and the sales (BLOOM-032 Phase 1 item 4). |
| What the engine proposed | `order_items.engine_packs` | Defined in Q4. |
| The sheet | `orders.cache_id`, `cache_generated_at`, `engine_md5`, `preset`, `fit_to_budget`, `basis` | Makes the stored figure interpretable after the cache row is gone. |
| Who and what state | `submitted_by`, `confirmed_by`, `status`, `source` | `status` values are `draft`, `confirmed`, `exported`, `delivered`, `cancelled`. Q9 asks which count as placed. |
| Why a line is there | `order_items.line_kind` (`ordered`, `hidden`, `manual`) and `story` | A manual line is the buyer's own number. |

**Two things this build must not do.**
1. Write `orders` into `order_budget_ledger.committed_amount`. It is already landed plus in-transit from Sigma. The recipe's fit reads `budget_amount - committed_amount`. A second source would double count when the Sigma order appears, and it would move engine quantities. PM-15 says no engine object or quantity moves (`BUG-LOG.md:2238`).
2. Change `refresh_l2_on_order`. A desk order counting as on order until Sigma's copy appears is BLOOM-032 Phase 1 item 3 and Phase 4 (`SB-CC-BLOOM-032 ... v1.3:86,143`). It needs the match in item 4 to avoid double counting. It is a later ship.

**Denominator note.** ENG-156 reported "1,066 untouched of 1,323". Lines where engine and buyer are both zero never persist, so an "untouched share" cannot be rebuilt from the stored rows. Added, increased, decreased and removed can.

---

## 5. Acceptance

### 5.1 R22 on the database, before the page ships (rolled back, as the account)

Run in the window. These write and roll back. They are not live reads. Template, using the pattern from the memory notes (set the claims, `SET LOCAL ROLE`, call, raise the result so everything rolls back):

```sql
DO $probe$
DECLARE r record;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '<PIETER_UID>', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT * INTO r FROM public.rpc_bloom_submit_order(
    '<store>', '<route>', '<delivery>'::date, '<next>'::date, 'desk', NULL,
    '[{"product_code":1,"qty_packs":5,"engine_packs":5,"pack_cost":10,"pack_size":6},
      {"product_code":2,"qty_packs":0,"engine_packs":5,"pack_cost":10,"pack_size":6},
      {"product_code":3,"qty_packs":3,"engine_packs":0,"pack_cost":10,"pack_size":6},
      {"product_code":4,"qty_packs":0,"engine_packs":0,"pack_cost":10,"pack_size":6}]'::jsonb,
    <cache_id>, 'normal');
  RAISE EXCEPTION 'ROLLED BACK: % %', r,
    (SELECT json_agg(oi ORDER BY product_code) FROM public.order_items oi WHERE oi.order_id = r.order_id);
END $probe$;
```

| Probe | Does | Expected |
|---|---|---|
| P1 | The template above | 3 rows. Removal row `q0 e5`. Addition row `e0 q3`. `line_count 2`, `total_value 80`, counts added 1, increased 0, decreased 0, removed 1. |
| P2 | Every `rpc_bloom_desks()` desk that has an open sheet, one probe each with its own `cache_id` | 0 route errors of N (RT-3). |
| P3 | Direct INSERT into `orders` as the owner with a route not on the calendar | `23503`, no row (RT-4). |
| P4 | Direct INSERT with `80579` and `DIRECT_BEER` | `23503`. |
| P5 | Inside the block: insert a calendar row and a `bloom_order_cache` header row for a new route, then call the writer | Success (RT-5). |
| P6 | Claims of a `shift_manager` (profile row inserted inside the block) | Raises `may not place orders` (AX-3). |
| P7 | Claims of a `store_manager` for another store | Raises (AX-3). |
| P8 | Claims with no profile row | Raises `no user_profiles row` word for word. |
| P9 | Dates in the call differ from the sheet header | Raises and names the field. |
| P10 | `cache_id` that does not exist | Raises the rebuilt-sheet sentence. |
| P11 | The same call twice in one block | Second raises the duplicate sentence (Q5 default). |
| P12 | `qty_packs = -1`, and a duplicate product | Both raise with a plain message (LN-4). |
| P13 | Writer body scan | RT-6 and AX-1 return 0. |

### 5.2 R31 on the live app, signed-in Chrome

The walk is read-only on Pieter's data except the one press. Read the DOM, never OCR. Click by DOM element, not by `ref_N` (it mis-registers on this dashboard). Note his filters first and restore them after. Window: after the probes pass, 20:00 to 22:00 or 03:00 to 07:00, never on an order morning. The press writes a row the app cannot delete, so Pieter chooses which order it is (Q14).

| Step | Action | Record | Pass if |
|---|---|---|---|
| W0 | Open `https://orders.socialbrand.africa`. Confirm the signed-in account. Read the Vercel result for the deployed commit. | Account, commit hash. | Build green, page loads. |
| W1 | Pick the store and the smallest desk (read L14). Press Generate. Read the DOM. | Header dates, "Precomputed order built ..." text, Running total, line count. In the network tab: the `rpc_bloom_order_cached` response, its `generated_at`, and the `cache_id` on a line. | `cache_id` present. |
| W2 | Edit three lines: add one pool line (it arrives as MANUAL), raise one engine line by 1, set one engine line to 0. | Screen-side counts: added 1, increased 1, removed 1. New Running total. | Total moved as expected. |
| W2b | Change the Delivery date input to another date without regenerating. | The page's own header date. | The sheet still reads the old date (finding 1.3 (1)). |
| W3a | Failure display, before the real press. With the page's JavaScript console, wrap `window.fetch` so the next request whose URL contains `rpc_bloom_submit_order` rejects once. Press Submit order. Then restore `fetch`. | The footer message. A read at source of `orders` for this drop. | The footer shows an error sentence. The button is live again and the grid is not locked (OK-2). `orders` holds 0 rows for this drop. The page then asks the reader whether an order exists and says none does. |
| W3 | Press Submit order for real. Read the network request and the footer. | Request body size in bytes, status code, elapsed ms. Footer text. Returned total and line count. | The footer is built from the return. The returned total equals the Running total to the cent (OK-3). The button was busy, then locked (OK-1). |
| W4 | Read back at source (a read-only query, run by the build session). | `orders` row: store, route, delivery date, next, status, total, line count, `submitted_by`, `cache_id`, `engine_md5`, `preset`, `fit_to_budget`, `basis`. `order_items`: rows, rows with `qty>0`, `sum(line_value)`, and the four counts from `engine_packs` and `qty_packs`. | The row's `delivery_date` is the sheet's date and not the edited input (W2b). Header total equals the screen. Counts are 1, 1, 0, 1 (added, increased, decreased, removed) plus the untouched lines. The MANUAL line has `engine_packs 0` and `line_kind 'manual'`. The zeroed line has `qty 0` and its engine figure (LN-1 to LN-3, LN-5, LN-7). |
| W5 | Try to edit a quantity and press Import. | Input state. | Inputs read-only, Import disabled (OK-4). |
| W6 | Reload the page. Pick the same desk. | The banner from `rpc_bloom_order_get`. | It shows the recorded order's status and total. Submit is disabled with the reason. This closes the 01-09 question. |
| W7 | Duplicate refusal at the database. The page blocks a second press, so this is the probe P11 and a read at source. | `orders` count for the drop. | Count is 1 after the probe. |
| W8 | Read `read_console_messages` with errors only. | Console. | No errors. |
| W9 | If this was a test press: cancel it through `rpc_bloom_order_status` with the reason "ENG-159 R31 walk". If it was a real order: leave it. | Final status. | The cancelled row stays as evidence. |
| W10 | Restore Pieter's filters. Close the tab. | | |

**ENG-156 pair.** PM-15 asks the acceptance of part 2 to reproduce the 175 / 48 / 34 pair from the two columns. Those figures describe Pieter's 03-09 order, which was never recorded, so no rows exist for it. The test that can pass is W4: the four counts from the two columns equal the counts the page computed from its own state, and the engine side equals the cache sheet while that row lives. Q7 asks PM to accept this wording.

---

## 6. Open questions for PM

Ranked by what they block. Each carries the default CC builds on if PM does not answer. Pieter's rule is hold only on a pivot, so the build proceeds on the default and PM can overrule before M2 applies.

**Blocks M2 and the page (access model):**

1. **Role map.** Is the table in section 3.2 the rule? That means who may submit, who self-confirms, who is read-only, who sees all stores, who may confirm and cancel. *Default:* the table as written. `shift_manager` cannot submit. Store tier submits as `draft`. Store tier may cancel only its own drafts, as the existing status function does.
2. **Pieter's profile row.** Which word, `area_manager` or `owner`, and the `client_id`. BLOOM-032 v1.3 section 5 (`:176`) records `area_manager` but calls it "the PM's reading of those three rulings", and HANDOVER-CURRENT line 300 still carries P-9 as asked of him. *Default:* the build does not depend on it, because both words get the top tier. The seed row waits for his one word.
3. **`cache_id`: foreign key or plain column.** PM-15 part 2 says "references". The nightly builder deletes the sheet row and inserts a new one every night. With `NO ACTION` the delete fails and that desk is not rebuilt (the nightly loop catches the error per desk, `create_bloom_order_cache.sql:443-449`, so it would show only in the run detail). With `SET NULL` the link dies at 01:30. With `CASCADE` the order dies. *Default:* plain `bigint`, plus `cache_generated_at` and `engine_md5` copied at the press. The writer verifies the sheet exists at the press. The foreign key goes in when BLOOM-032 Phase 1 item 1 (keep every nightly version) lands. Say if PM wants the foreign key sooner and accepts the builder change that needs.
4. **What `engine_packs` is.** The page's seed figure under the basis on screen, `lineQty(line, basis)` (`page.jsx:70-74`), or the engine's raw `suggested_packs`? They differ on promo lines: ENG-156 found 243 against 116 on one line, because `suggested_packs` is the geared figure and the desk's basis was Normal. *Default:* the figure the buyer's screen was seeded with under the basis at the press, with `basis` stored on the header so it can be read back. The raw figures stay in the cache while it lives.

**Blocks nothing, changes behaviour:**

5. **One active order per drop.** A second press for the same store, route and delivery date is refused while the first is not cancelled. A top-up order for the same drop would need a cancel first. *Default:* refuse, with the message and the cancel path. The risk it removes is a double press or a retry after a dropped connection.
6. **A cancel control in this ship.** Without it a wrong press cannot be undone from the page. *Default:* include "Cancel this order" in the footer (C5), using the existing status function.
7. **Acceptance wording for the ENG-156 pair.** See section 5.2 last paragraph. *Default:* the W4 wording.
8. **`orders.source` for the Desks screen.** The typed values are `dc`, `desk`, `recipe`. *Default:* `desk`. A new value would be a vocabulary ruling.
9. **Which statuses count as placed** for the ledger, on-order and stocktake readers, and whether the export buttons should move `confirmed` to `exported`. *Default:* nothing reads yet. Export does not change status in this build.
10. **Three small additions beyond the ruling.** `orders.fit_to_budget`, `orders.basis` and `order_items.line_kind`. *Default:* include them. `line_count` means lines with `qty_packs > 0`, and the return adds the persisted count.
11. **The Replit app (SB-RA-BLOOM-001).** `DB-SCHEMA.md:463` says the writer exists for it. It is not in this repo. If it calls the seven-argument writer, the signature change breaks it. *Default:* assume no live caller (BUG-LOG says zero consumers, and `n_tup_ins` was 0). Read L10 shows function call counts if tracking is on. Pieter confirms.
12. **The two unreachable Submit buttons and the beer screen.** `RecipeMode` (`:1267`) and the old DC mode (`:3474`) cannot carry a `cache_id`. `DeskMode` has no Submit. Addendum 1 and PM-15 speak of "three buttons". *Default:* wire the one reachable button, leave the two hidden ones as they are, and add no Submit to `DeskMode`. Retiring them is Pieter's (UX-003).
13. **Promo lines and the landing date.** On a DC desk the promo lines ride a separate sheet. Do they land on the same truck as the rest, so `delivery_date` serves them? *Default:* yes. If no, each line needs its own expected landing date and the contract grows a column.
14. **The first press.** Which real order, or a test press that is then cancelled (the cancelled row stays for good). *Default:* Pieter picks. Not on an order morning.
15. **An interim label.** BUG-LOG ENG-159's first row says the app must not say "Submitted" until the path works. The label still says it (`:3306`). *Default:* leave it, since PM-15 says the buttons stay unwired and the build is days away. A text-only edit is available if PM wants it now.

---

## 7. What I read and what I did not

**Scoped start-read.** PM-approved 2026-07-20 for a focused read-only task. I did not run the canon recital in CLAUDE.md.

**Read in full:**
- `BUG-LOG.md` rows at lines 302 (ENG-153), 305 (ENG-159), 307 (ENG-156), and the ranges 1829-1858 (addendum 1) and 2212-2241 (addendum 2). A grep for "ENG-159 addendum" finds exactly two headers (1829, 2212). There is no later addendum.
- `src/app/bloom/page.jsx` (1 to 3484), `src/middleware.js`, `src/lib/supabase.js`, `src/lib/appNames.js`, `src/app/bloom/layout.jsx`, `src/lib/stocktake/server.js`, `src/app/api/stocktake/generate/route.js`, `scripts/rls-guard-gate.mjs`, `scratch/README.md`.
- `sql/create_orders_header.sql`, `create_rpc_bloom_submit_order.sql`, `create_rpc_bloom_order_status.sql`, `create_user_profiles_policies.sql`, `sb_sch_001_step9_user_profiles.sql`, `_archive/mobile_auth_setup.sql`, `create_supplier_calendar.sql`, `create_supplier_calendar_cycle_grain.sql`, `create_bloom_order_cache.sql`, `create_refresh_bloom_order_cache.sql`, `bloom035_e1_readers.sql`, `bloom035_e1_cache_rows.sql`, `create_rpc_bloom_next_deliveries.sql`, `create_rpc_bloom_desks.sql`, `create_rpc_bloom_budget_context.sql`, `create_order_budget_ledger.sql`, `create_order_budget_ledger_weekly_grain.sql`, `create_rpc_forge_rls_guard.sql`.
- `SB-CC-BLOOM-032 ... v1.3` lines 70 to 197 and `memory/auth_phase1_super_admin.md`.

**Read in part:**
- `sql/create_refresh_order_budget_ledger.sql` (1-90), `create_refresh_order_budget_ledger_needs.sql` (100-240), `bloom035_1b_dc_fresh_phase0.sql` (20-100), `bloom035_eng202_catchall_desk.sql` (56-146), `create_rpc_bloom_order_recipe.sql` (476-491).
- By grep with line numbers only: `create_refresh_l2_on_order.sql`, `eng241_stocktake_count_app_core.sql`, `DEPLOY-LOG.md`, `DB-SCHEMA.md` (462-471 read), `HANDOVER-CURRENT.md` (line 300 read), `Bloom/CHANGELOG.md` (line 20 read), `Forge/SB-CC-ORDER-001` (line 100 read), `SB-VIS-001` (lines 81-83), `SB-RA-BLOOM-001-BUILD-BRIEF.md` (line 136), `Forge/SB-CC-STOCKTAKE-001` (grep).

**Not read, and so not relied on:** RULE-BOOK itself (rule numbers R22, R25, R28, R30, R32 are quoted as BUG-LOG and code comments cite them), ORDERING-CANON and its REGISTERS (section H18 line 110 seen by grep only), the other canon files, the memory feedback files beyond the index lines in the session context, the bodies of `rpc_bloom_order_recipe`, `refresh_l2_on_order`, `rpc_bloom_stored_overview`, and any live object body. The repo copy of `refresh_bloom_order_cache` is behind live (it lacks E1 step 3b), so read L7 and L6 decide.

**Measurement limits (R28 section 5).** "0 rows" for `user_profiles`, `orders` and `order_items` is BUG-LOG's count of 14-09 and 20-09, not mine. "8 of 9 keys" is PM's count of 20-09. Both are one observation on one day. Read L1, L2 and L8 replace them with today's.

---

## 8. Live reads for the 20:00 window

All read-only. Run in order. Each states the question it answers.

**L1. Are the tables still empty, and is there still one account and no profile?**
```sql
select 'orders' as t, count(*) as n from public.orders
union all select 'order_items', count(*) from public.order_items
union all select 'user_profiles', count(*) from public.user_profiles
union all select 'auth.users', count(*) from auth.users;
```

**L2. Has an insert ever been attempted on either table?**
```sql
select relname, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup,
       (select stats_reset from pg_stat_database where datname = current_database()) as stats_reset
from pg_stat_user_tables
where schemaname = 'public' and relname in ('orders','order_items','user_profiles');
```

**L3. What are the live constraints? (the route CHECK's real name, the role CHECK's words, the calendar's primary key)**
```sql
select conrelid::regclass::text as tbl, conname, contype, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid in ('public.orders'::regclass, 'public.order_items'::regclass,
                   'public.user_profiles'::regclass, 'public.supplier_calendar'::regclass)
order by 1, 2;
```

**L4. What are the live columns of the three tables?**
```sql
select table_name, ordinal_position as pos, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name in ('orders','order_items','user_profiles')
order by table_name, ordinal_position;
```

**L5. What are the live policies, grants, RLS flags and owners?**
```sql
select tablename, policyname, cmd, roles::text as roles, qual, with_check
from pg_policies
where schemaname = 'public' and tablename in ('orders','order_items','user_profiles')
order by 1, 2;

select c.relname, c.relrowsecurity, c.relforcerowsecurity,
       pg_get_userbyid(c.relowner) as owner, c.relacl::text as acl
from pg_class c
where c.oid in ('public.orders'::regclass, 'public.order_items'::regclass, 'public.user_profiles'::regclass);
```

**L6. Pins: signatures, overload count, owner, grants and body hashes of every function the build replaces or reads.**
```sql
select p.oid::regprocedure::text as signature, p.prosecdef as definer,
       pg_get_userbyid(p.proowner) as owner,
       length(pg_get_functiondef(p.oid)) as def_len,
       md5(pg_get_functiondef(p.oid)) as def_md5, md5(p.prosrc) as src_md5,
       p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('rpc_bloom_submit_order','rpc_bloom_order_status','rpc_bloom_order_cached',
                    'refresh_bloom_order_cache','refresh_bloom_order_cache_all','rpc_bloom_desks')
order by 1;
```

**L7. Does the live nightly builder still delete the sheet row, and does anything else point at that table?**
```sql
select position('DELETE FROM public.bloom_order_cache' in
       pg_get_functiondef('public.refresh_bloom_order_cache(text,text,date,date,text,boolean,text)'::regprocedure)) as delete_at_char;

select conrelid::regclass::text as child, conname, pg_get_constraintdef(oid) as def
from pg_constraint where confrelid = 'public.bloom_order_cache'::regclass;

select count(*) filter (where delivery_date <  current_date) as past_sheets,
       count(*) filter (where delivery_date >= current_date) as open_sheets,
       min(delivery_date) as oldest_drop, max(delivery_date) as newest_drop,
       min(cache_id) as min_id, max(cache_id) as max_id
from public.bloom_order_cache;
```

**L8. Which route keys does the calendar hold now, and does the screen offer one desk per calendar row?**
```sql
select route_key, count(*) as desks, string_agg(store_code, ',' order by store_code) as stores
from public.supplier_calendar group by 1 order by 1;

select (select count(*) from public.supplier_calendar) as calendar_rows,
       (select count(*) from public.rpc_bloom_desks()) as desks_offered;
```

**L9. What depends on `orders`, `order_items` and `auth.users`, and does anything delete calendar rows?**
```sql
select distinct c.relname::text as dependent_view, c.relkind
from pg_depend d join pg_rewrite r on r.oid = d.objid join pg_class c on c.oid = r.ev_class
where d.refobjid in ('public.orders'::regclass, 'public.order_items'::regclass)
  and c.oid not in ('public.orders'::regclass, 'public.order_items'::regclass);

select p.oid::regprocedure::text as function_mentioning
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.prosrc ~* '\morder_items\M' or p.prosrc ~* '(from|join|into|update)\s+(public\.)?orders\M')
order by 1;

select p.oid::regprocedure::text as deletes_calendar_rows
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosrc ~* '(delete\s+from|truncate)\s+(table\s+)?(public\.)?supplier_calendar\M';

select tgrelid::regclass::text as on_table, tgname, pg_get_triggerdef(oid) as def
from pg_trigger
where not tgisinternal
  and tgrelid in ('public.orders'::regclass, 'public.order_items'::regclass, 'auth.users'::regclass);
```

**L10. Is anything calling the two writers (cron, other functions, call counts)?**
```sql
select jobid, jobname, schedule, left(command, 160) as command
from cron.job
where command ilike '%rpc_bloom_submit_order%' or command ilike '%rpc_bloom_order_status%';

select p.oid::regprocedure::text as caller
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosrc ilike '%rpc_bloom_submit_order%'
  and p.proname <> 'rpc_bloom_submit_order';

select current_setting('track_functions') as track_functions;
select funcname, calls from pg_stat_user_functions
where funcname in ('rpc_bloom_submit_order','rpc_bloom_order_status');
```

**L11. Inputs for the profile row: the account and the client.**
```sql
select id, email, created_at, last_sign_in_at, raw_app_meta_data->>'provider' as provider
from auth.users order by created_at;

select to_jsonb(c) as client_row from public.clients c limit 5;
```

**L12. Is `committed_amount` populated today, and which jobs run when? (the second query lists every cron job, so the pipeline's schedule and the ledger refresh are both visible)**
```sql
select store_code, route_key, year_month, budget_amount, committed_amount, landed_amount
from public.order_budget_ledger
where grain = 'weekly' and year_month between current_date - 14 and current_date + 14
order by store_code, route_key, year_month limit 80;

select jobid, jobname, schedule, left(command, 100) as command from cron.job order by jobid;
```

**L13. The build gate's standing before the change.**
```sql
select * from public.rpc_forge_rls_guard_summary();
select object_name, reader_role, site_class, silent, verdict
from public.rpc_forge_rls_guard()
where object_name in ('orders','order_items','user_profiles','supplier_calendar',
                      'bloom_order_cache','bloom_order_cache_line')
order by 1, 2;
```

**L14. Which sheets are smallest, for the walk?**
```sql
select cache_id, store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget,
       line_count, ordered_line_count, generated_at
from public.bloom_order_cache
where delivery_date >= current_date
order by ordered_line_count nulls last, line_count limit 15;
```

**L15. Do the sheets behind the ENG-156 pair still exist?**
```sql
select cache_id, store_code, route_key, delivery_date, next_delivery, preset, fit_to_budget, generated_at
from public.bloom_order_cache where cache_id in (265, 555);
```

**L16. Which desks have a drop close, so the walk avoids an order morning? (direct desks only give a clean figure, DC desks read the ledger's placement day)**
```sql
select d.store_code, d.route_key, d.is_dc, nd.delivery_date, nd.following_date,
       d.order_cutoff_days, (nd.delivery_date - d.order_cutoff_days) as approx_place_by_direct_only
from public.rpc_bloom_desks() d
cross join lateral public.rpc_bloom_next_deliveries(d.store_code, d.route_key) nd
order by nd.delivery_date, d.store_code, d.route_key;
```

**L17. Is anything holding a long lock that would make M1 queue?**
```sql
select pid, state, now() - query_start as running, wait_event_type, left(query, 100) as query
from pg_stat_activity
where state <> 'idle' and pid <> pg_backend_pid() and now() - query_start > interval '30 seconds'
order by running desc;
```

**L18. The clock, for every stamp.**
```sql
select now() at time zone 'Africa/Johannesburg' as sast_now, now() as utc_now, current_setting('TimeZone') as db_timezone;
```
