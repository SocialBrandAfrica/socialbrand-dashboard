-- create_order_budget_ledger_manual_override.sql
-- WALK-FINDINGS W5 (Pieter, live walk 2026-07-12, freeze lifted): a manual
-- budget insert must override the 82%-forecast/80%-cash-constrained basis
-- display, strip labels MANUAL. `cash_constrained` (create_order_budget_
-- ledger_cash_constrained.sql) already carries a real, separate meaning --
-- it gates the order_essentials preset's day-cover (21d normal / 10d cash-
-- constrained, canon v7 item 3) inside rpc_bloom_order_recipe -- so it is
-- NOT reused here; a manual override is a THIRD, independent state (the
-- rand figure itself was typed in ad hoc for the week, not derived from
-- either seeded formula) and must not silently flip the essentials cover
-- too. `budget_amount` was already, in practice, always a seeded/manual
-- plan figure (refresh_order_budget_ledger() never touches it, per
-- DB-SCHEMA.md) -- this column makes the ad-hoc-override CASE explicit and
-- displayable, distinct from "seeded via the normal 82%/80% workbook
-- process." Defaults false (every currently-seeded week is workbook-
-- derived, not a manual override).
ALTER TABLE public.order_budget_ledger
  ADD COLUMN IF NOT EXISTS budget_manual_override boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.order_budget_ledger.budget_manual_override IS
  'TRUE when budget_amount for this store/route/week was entered ad hoc '
  '(overriding the normal 82%-forecast or 80%-cash-constrained workbook '
  'derivation) -- the desk strip labels the week MANUAL instead of a '
  'percent-basis figure. Independent of cash_constrained, which still '
  'governs the order_essentials preset day-cover on its own (canon v7 '
  'item 3) regardless of this flag. WALK-FINDINGS W5, 2026-07-12.';

SELECT pg_notify('pgrst', 'reload schema');
