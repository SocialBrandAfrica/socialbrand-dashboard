-- create_order_budget_ledger_sab_weekly_seed.sql
-- BUG-LOG accuracy-gate finding (2026-07-11 CC run): order_budget_ledger
-- carried ZERO grain='weekly' rows for any DIRECT_BEER store (21355/
-- 80176/80579 monthly-only) -- the budget strip and Fit-to-Budget would
-- have read empty on every SAB desk during Pieter's Monday 13 Jul walk.
--
-- PM applied the fix live 2026-07-12: each store's own weekly figure,
-- split by that store's own LY beer rhythm for the week (not a flat
-- monthly/4 divide) -- verified reading correctly through the live
-- scenario overview before this file was written. This is the CANONICAL
-- record of that seed so the repo does not drift from what's live
-- (PM's own flag: "the canonical seed file must land in the repo").
--
-- R22 (CC, post-seed verification): 80176's full standard order sits
-- inside the ENG-013 acceptance band on this budget -- above demonstrated
-- weekly cost demand, under the ceiling.
--
-- ON CONFLICT DO NOTHING -- PK is (store_code, route_key, year_month),
-- this file is safe to re-run, never overwrites a value someone
-- (Pieter/PM) has since adjusted live.
--
-- FLAGGED, NOT FIXED HERE (PM's own note, hygiene pass AFTER Monday's
-- walk): the SAME stores (21355/80176/80579, plus 10116/80175) also
-- carry weekly rows under route_key='DIRECT' for this same week --
-- "look like the same money on two keys." Do not merge or delete either
-- key's rows without Pieter's own ruling on which key is authoritative
-- going forward; both are left untouched by this file.

INSERT INTO public.order_budget_ledger (store_code, route_key, grain, year_month, budget_amount, committed_amount, cash_constrained)
VALUES
  ('21355', 'DIRECT_BEER', 'weekly', '2026-07-11', 41541.86, 0, false),
  ('80176', 'DIRECT_BEER', 'weekly', '2026-07-11', 77732.83, 0, false),
  ('80579', 'DIRECT_BEER', 'weekly', '2026-07-11', 36258.41, 0, false)
ON CONFLICT (store_code, route_key, year_month) DO NOTHING;
