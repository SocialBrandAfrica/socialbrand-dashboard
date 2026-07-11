-- =============================================================================
-- create_order_budget_ledger_weekly_grain.sql
-- BLOOM-004 item 7 / §3b (2026-07-11). Extends `order_budget_ledger`
-- (Ship 1, sql/create_order_budget_ledger.sql) to weekly grain -- an ALTER +
-- INSERT on a table already carrying live Ship-1 monthly DIRECT_BEER budget
-- data, NOT a Rule-19 DROP+CREATE rebuild (would destroy the Desk view's
-- existing gauge source).
--
-- `year_month` is reused generically as "the period date" for weekly rows
-- too (holds the week-commencing date instead of a month-start date),
-- distinguished by the new `grain` column -- avoids an awkward PK migration:
-- PRIMARY KEY columns cannot be NULL in Postgres, so adding a separate
-- nullable `week_ending` column could not safely join the existing PK
-- (store_code, route_key, year_month) without breaking every existing row.
--
-- Seed: SB-AP-BUDGET-002_Per-Store_Budgets_WC-11-Jul-2026.xlsx via BLOOM-004
-- §3b's own table (read in full, not re-derived). Method fixed in the source
-- file: forecast = LY same week x 1.02 glide, budget = 82% of forecast
-- (cash-margin law, SB-AP-REPAY-001), DC share from real GRV receipts over
-- 90 days. All DEMO_CALIBRATION, refresh weekly from the workbook (R28),
-- never live in code.
--
-- Two row shapes per store per week:
--   route_key='ALL'    -- store-wide: budget_amount (82% figure),
--                          budget_80pct_cash, floor_21day, good_stock_now.
--   route_key='DC'/'DIRECT' -- the allocation split of the same total
--                          (budget_amount only -- floor/good-stock are
--                          store-wide facts, not meaningful split by route).
--
-- Consumed by `rpc_bloom_order_recipe`'s Fit-to-Budget allocator (item 8),
-- reading route_key='DC' (this recipe's own pool is Z-supplier-link-scoped,
-- DC-ambient) at the most recent grain='weekly' row for the store.
--
-- Reconciled on deploy (Ship-1 precedent): the group total across the 5
-- ALL-grain weekly rows must tie to the rand.
-- =============================================================================

ALTER TABLE public.order_budget_ledger ADD COLUMN IF NOT EXISTS grain text NOT NULL DEFAULT 'monthly';
ALTER TABLE public.order_budget_ledger ADD COLUMN IF NOT EXISTS budget_80pct_cash numeric;
ALTER TABLE public.order_budget_ledger ADD COLUMN IF NOT EXISTS floor_21day numeric;
ALTER TABLE public.order_budget_ledger ADD COLUMN IF NOT EXISTS good_stock_now numeric;

COMMENT ON COLUMN public.order_budget_ledger.grain IS
  'monthly (Ship-1 seed, DIRECT_BEER only, year_month=month-start) or weekly '
  '(BLOOM-004 item 7, route_key=ALL/DC/DIRECT, year_month=week-commencing date). '
  'Same table, two grains, distinguished here rather than migrating the PK.';
COMMENT ON COLUMN public.order_budget_ledger.floor_21day IS
  'Store-wide 21-day good-stock floor (SB-AP-BUDGET-002). Only populated on '
  'route_key=ALL rows -- not meaningful split by DC/direct.';

INSERT INTO public.order_budget_ledger
  (client_id, store_code, route_key, year_month, grain, budget_amount, budget_80pct_cash, floor_21day, good_stock_now, scope, source_note)
VALUES
  ('socialbrand','10116','ALL','2026-07-11','weekly',1216645,973316,3296721,2887226,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026: 82% forecast, incl-VAT turnover basis'),
  ('socialbrand','80175','ALL','2026-07-11','weekly', 599886,479909,1486147,1545989,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026'),
  ('socialbrand','21355','ALL','2026-07-11','weekly', 171279,137023, 538800, 541326,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026'),
  ('socialbrand','80176','ALL','2026-07-11','weekly', 221066,176852, 394611, 521772,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026'),
  ('socialbrand','80579','ALL','2026-07-11','weekly', 152230,121784, 383239, 374704,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026')
ON CONFLICT (store_code, route_key, year_month) DO UPDATE SET
  budget_amount=EXCLUDED.budget_amount, budget_80pct_cash=EXCLUDED.budget_80pct_cash,
  floor_21day=EXCLUDED.floor_21day, good_stock_now=EXCLUDED.good_stock_now,
  grain=EXCLUDED.grain, scope=EXCLUDED.scope, source_note=EXCLUDED.source_note, updated_at=now();

INSERT INTO public.order_budget_ledger
  (client_id, store_code, route_key, year_month, grain, budget_amount, scope, source_note)
VALUES
  ('socialbrand','10116','DC','2026-07-11','weekly', 850435,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, DC share of the 82% budget'),
  ('socialbrand','10116','DIRECT','2026-07-11','weekly', 366210,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, direct share'),
  ('socialbrand','80175','DC','2026-07-11','weekly', 399524,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, DC share'),
  ('socialbrand','80175','DIRECT','2026-07-11','weekly', 200362,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, direct share'),
  ('socialbrand','21355','DC','2026-07-11','weekly', 107734,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, DC share'),
  ('socialbrand','21355','DIRECT','2026-07-11','weekly',  63544,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, direct share'),
  ('socialbrand','80176','DC','2026-07-11','weekly', 125565,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, DC share'),
  ('socialbrand','80176','DIRECT','2026-07-11','weekly',  95500,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, direct share'),
  ('socialbrand','80579','DC','2026-07-11','weekly', 151316,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, DC share'),
  ('socialbrand','80579','DIRECT','2026-07-11','weekly',    913,'DEMO_CALIBRATION','SB-AP-BUDGET-002 WC-11-Jul-2026, direct share')
ON CONFLICT (store_code, route_key, year_month) DO UPDATE SET
  budget_amount=EXCLUDED.budget_amount, grain=EXCLUDED.grain,
  scope=EXCLUDED.scope, source_note=EXCLUDED.source_note, updated_at=now();

DO $$
DECLARE v_total numeric;
BEGIN
  SELECT SUM(budget_amount) INTO v_total FROM public.order_budget_ledger
  WHERE grain='weekly' AND route_key='ALL' AND year_month='2026-07-11';
  IF ABS(v_total - 2361106) > 5 THEN
    RAISE EXCEPTION 'order_budget_ledger weekly seed does not reconcile: group total %, expected ~2361105', v_total;
  END IF;
END $$;

SELECT pg_notify('pgrst', 'reload schema');
