-- create_l2_population_verdict.sql
--
-- public.l2_population_verdict -- THE CROSS-APP POPULATION FACT (SB-CC-BLOOM-026 §12 /
-- SB-CC-BLOOM-027 §3.2). One row per (client, store, product): the standing population
-- state with its reason, so Bloom, Forge, Pulse and Capital Tied stop re-implementing
-- one rule (R33 clause 3, R32).
-- Created live 2026-08-19 (migration bloom026_l2_population_verdict_table,
-- 20260819193718). cost_demand_28d and cost_demand_anchor_date were added later for
-- ENG-106 leg (a). The WRITER has had a source file all along
-- (sql/create_refresh_l2_population_verdict.sql). The TABLE never did, so a rebuild
-- from this repo did not produce it. That is BUG-LOG ENG-175 half (a), and this file
-- closes it.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog on 2026-09-10
-- (pg_attribute, pg_attrdef, pg_constraint, pg_index, pg_policy, relacl,
-- obj_description, col_description). Before commit it was gated against live: the same
-- DDL built into pg_temp returned identical column, constraint and index signatures,
-- and every COMMENT body below hashes to its live comment. Re-applying this file to
-- the live database is a no-op.
--
-- ROWS ARE NOT CARRIED: the writer rebuilds them nightly. Live at capture: 36,793 rows
-- across 5 stores, 63,643,648 bytes.
--
-- WRITER: refresh_l2_population_verdict(), called inside refresh_l2_pipeline (pg_cron
--   job 15, 22:15 SAST).
-- READERS, verified at source on 2026-09-10: rpc_bloom_stock_state,
--   rpc_bloom_pool_search, refresh_bloom_order_cache and the view
--   v_bloom_availability_by_tier. rpc_bloom_hidden_demand and rpc_bloom_link_verify
--   STILL do not read it, which is the open R33 duplication the table COMMENT records.
--   Owner CC.
--
-- THE COMMENTS ARE REPRODUCED VERBATIM, stale parts included. The table COMMENT's
-- status block is dated 2026-08-24 and quotes that day's state split, which moves
-- nightly. Correcting it is a separate change with its own R28 lineage, never a silent
-- rewrite inside a source-parity pass.
--
-- ACCESS, live: RLS ENABLED with one open read policy for anon and authenticated.
-- The PK is client_id-leading, so the (store_code, product_code) secondary index exists
-- on purpose for two-key joins (canon §17, the l2_on_order precedent). The `m`
-- (MAINTAIN) privilege on anon and authenticated comes from the platform's default
-- privileges and is reproduced, not granted, here. Live ACL at capture:
--   {postgres=arwdDxtm/postgres,anon=rm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}

CREATE TABLE IF NOT EXISTS public.l2_population_verdict (
  client_id                  text        NOT NULL DEFAULT 'socialbrand'::text,
  store_code                 text        NOT NULL,
  product_code               bigint      NOT NULL,
  description                text,
  dept_name                  text,
  department_nr              smallint,
  route_key                  text,
  is_dc                      boolean,
  route_overlap              boolean     NOT NULL DEFAULT false,
  population_state           text        NOT NULL,
  state_reason               text        NOT NULL,
  flag_hidden_seller         boolean     NOT NULL DEFAULT false,
  flag_new_range             boolean     NOT NULL DEFAULT false,
  flag_dormant_empty         boolean     NOT NULL DEFAULT false,
  flag_phantom_claims_stock  boolean     NOT NULL DEFAULT false,
  flag_link_lapsed           boolean     NOT NULL DEFAULT false,
  flag_verify_link_pack      boolean     NOT NULL DEFAULT false,
  flag_cost_unpriced         boolean     NOT NULL DEFAULT false,
  soh                        numeric,
  soh_date                   date,
  range_state                text,
  kvi_band                   text,
  tier                       text,
  passes_life_gate           boolean,
  rate_raw_56d               numeric,
  rate_corrected_56d         numeric,
  rate_published_56d         numeric,
  rate_guard_56d             text,
  days_removed_56d           smallint,
  observable_days            smallint,
  observable_share           numeric,
  chosen_supplier_nr         bigint,
  chosen_pack_size           smallint,
  chosen_pack_cost           numeric,
  chosen_unit_cost           numeric,
  chosen_is_zero_cost        boolean,
  candidate_links            integer,
  distinct_packs             integer,
  receipting_suppliers       integer,
  zero_cost_links            integer,
  unit_cost_spread_pct       numeric,
  cost_basis                 text,
  first_receipt_date         date,
  last_sale_date             date,
  never_sold                 boolean,
  link_valid_to              date,
  engine_version             text        NOT NULL,
  computed_at                timestamptz NOT NULL DEFAULT now(),
  cost_demand_28d            numeric,
  cost_demand_anchor_date    date,
  CONSTRAINT l2_population_verdict_pkey PRIMARY KEY (client_id, store_code, product_code),
  CONSTRAINT l2_population_verdict_state_ck CHECK (population_state = ANY (ARRAY['HIDDEN_SELLER_SUPPRESSED'::text, 'PHANTOM_CLAIMS_STOCK'::text, 'LINK_LAPSED_UNDER_DEMAND'::text, 'NEW_RANGE'::text, 'DORMANT_EMPTY'::text, 'VERIFY_LINK_OR_PACK'::text, 'COST_UNPRICED'::text, 'COVERED_TRUSTED_RATE'::text, 'SLOW_BELOW_GATE'::text]))
);

CREATE INDEX IF NOT EXISTS l2_population_verdict_store_product_idx ON public.l2_population_verdict USING btree (store_code, product_code);
CREATE INDEX IF NOT EXISTS l2_population_verdict_desk_idx ON public.l2_population_verdict USING btree (store_code, route_key, population_state);
CREATE INDEX IF NOT EXISTS l2_population_verdict_state_idx ON public.l2_population_verdict USING btree (store_code, population_state);

COMMENT ON TABLE public.l2_population_verdict IS $c$GRADE: VERDICT. The standing population state per line with its reason. One home for the rule Bloom, Forge, Pulse and Capital Tied read.
SB-CC-BLOOM-026 SS12 / SB-CC-BLOOM-027 SS3.2. ONE L2 fact per (client, store, product): the standing population state with its reason, for Bloom, Forge, Pulse and Capital Tied (R33 clause 3, R32).

*** STATUS 2026-08-24 11:54 SAST: POPULATED AND WIRED. 36526 rows across 5 stores. SAFE TO READ. ***
Refreshed nightly inside refresh_l2_pipeline (pg_cron job 15, 22:15 SAST).
State split at this stamp: SLOW_BELOW_GATE 22785, COVERED_TRUSTED_RATE 9326, NEW_RANGE 1584, HIDDEN_SELLER_SUPPRESSED 1367, COST_UNPRICED 580, VERIFY_LINK_OR_PACK 504, DORMANT_EMPTY 313, PHANTOM_CLAIMS_STOCK 67

R28 LINEAGE -- the prior stamp is RETIRED, not deleted. It read "STATUS 2026-08-20 08:5x SAST:
BUILT, R22 GREEN, DELIBERATELY EMPTY. DO NOT READ YET." and "Nothing is wired: NOT in
refresh_l2_pipeline, neither reader repointed." retired_on 2026-08-24. Both halves were true
when written and the FIRST half stopped being true when the NEW_RANGE fix landed and the table
was populated and wired. The comment was not moved with it, so this object described itself as
empty while holding tens of thousands of rows -- the l2_last_counted / l2_soh_daily class
(object live, paper behind), this time on the object own COMMENT and not only in a document.
Corrected by CC.

THE DEFECT THAT HELD IT EMPTY IS CLOSED. NEW_RANGE was over-inclusive at 8,387 on 80175 alone
because a line that never sold and was NEVER RECEIVED read as new; that is a catalogue stub.
Shipped fix: never_sold AND (first_receipt <= 120d OR sigma_articles.created_date <= 120d).
Measured now: NEW_RANGE = 1584 group-wide across all five stores.
sigma_supplier_link.cost_date stays TESTED AND REJECTED as the ranging signal (3,121 of 8,512
stubs re-costed inside 120d because the DC re-prices routinely, SSA5 7d).

STILL OPEN, and it is why this fact moves no live number yet: NEITHER READER IS REPOINTED.
rpc_bloom_hidden_demand and rpc_bloom_link_verify still carry their own hoisted gate and do not
read this table (verified at source 2026-08-24 11:54 SAST: strpos = 0 in both bodies). Until they are repointed as
thin jsonb reads with the ENG-093 wrap, the duplication R33 forbids is still live and this fact
is a second implementation of it rather than the one home. Owner CC.

R22 GREEN at build, reader vs fact, all 7 desks at 80175:
  rpc_bloom_hidden_demand  DC_AMBIENT 417/417, COCACOLA 22/22, CLOVER 25/25, SIMBA 9/9,
                           DANONE 10/10, NATBRANDS 4/4, MONDELEZ 10/10
  rpc_bloom_link_verify    DC_AMBIENT 144/144
The hoisted gate reproduces both readers exactly. That is what makes the repoint safe.

SCOPE NOTE: pool-scoped never-sold-holding-stock at 80175 is 47 against SS2b 67. That is SS10
coming true, not a defect: SS2b was run on class NORMAL across all departments and SS10 states
the pool-scoped figure is smaller and must be said honestly.

BOUNDARY: this fact carries the STANDING state. Whether a line was ORDERED is per
(delivery_date, preset) and lives in bloom_order_cache_line as a join, never a column here.$c$;

COMMENT ON COLUMN public.l2_population_verdict.population_state IS $c$First-match-wins headline over the flags (SS2: one pass, first match wins). Use the flag_* booleans when you need the independent conditions -- one line can be a hidden seller AND priced off a zero-cost link.$c$;

COMMENT ON COLUMN public.l2_population_verdict.observable_share IS $c$Observable days over window. Carried so an estimate travels with its basis (R28 SS5): a corrected rate resting on six observable days shows it rather than reading as measured.$c$;

COMMENT ON COLUMN public.l2_population_verdict.chosen_supplier_nr IS $c$The link the RECIPE would price off, reproduced including the store-local 1339 literal so the fact describes the order the buyer sees. ORDERING-CANON SSH8 v1.5: the recipe is not changed and the literal is a named SS0h debt. Do not re-pick here.$c$;

COMMENT ON COLUMN public.l2_population_verdict.cost_demand_28d IS $c$ENG-106 leg (a). This LINE own 28-day cost demand off sigma_sales (period_kind T, txn_kind 1), pool-scoped. NEVER sum these for a route total - that is the benchmark and it lives in rpc_bloom_route_benchmark (leg b). Divide by 28 for daily, by 4 for weekly.$c$;

COMMENT ON COLUMN public.l2_population_verdict.cost_demand_anchor_date IS $c$ENG-106 leg (a) / SSD6.1 clause 2 v1.13. The LEDGER WATERMARK the 28-day window was anchored on. Never CURRENT_DATE. Stored so the number can be reproduced at the same anchor and a stale anchor is visible rather than silent.$c$;

ALTER TABLE public.l2_population_verdict ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_population_verdict_read ON public.l2_population_verdict;
CREATE POLICY l2_population_verdict_read ON public.l2_population_verdict FOR SELECT TO authenticated, anon USING (true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.l2_population_verdict FROM anon, authenticated;
GRANT SELECT ON public.l2_population_verdict TO anon, authenticated;
