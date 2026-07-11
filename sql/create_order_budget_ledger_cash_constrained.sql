-- create_order_budget_ledger_cash_constrained.sql
-- SB-CC-BLOOM-007 item 5: the ledger's own basis for the week (canon SS14
-- v7 item 3). FALSE (default) = the normal 82%-of-forecast basis; TRUE =
-- the week is running on the 80% cash-constrained basis. Read by
-- rpc_bloom_order_recipe to gate the order_essentials preset's cover
-- (21-day when normal, 10-day flat when cash-constrained) -- "read from
-- order_budget_ledger for the week, never asked twice." Defaults false
-- (matches every currently-seeded week: no cash constraint recorded).
ALTER TABLE public.order_budget_ledger
  ADD COLUMN cash_constrained boolean NOT NULL DEFAULT false;
