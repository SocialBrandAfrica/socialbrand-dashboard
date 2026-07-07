-- =============================================================================
-- order_budget_ledger -- SB-CC-BLOOM-003 Ship 1. The 82% budget gauge's source
-- of truth: budget vs committed vs landed vs sales, per store per route per
-- month. R28 stamped, DEMO_CALIBRATION (the rand figures are this operator's
-- recovery plan, never a general formula).
--
-- Seed: SAB (DIRECT_BEER) monthly group budget from SB-AP-REPAY-001 section 2
-- (Jul 0.83M .. Dec 1.66M), split across the 3 TOPS stores by their LY H2 beer
-- sales share (SB-STRAT-002 section 6b: 21355 R2.93M / 80176 R5.67M / 80579
-- R2.64M of R11.24M TOPS total) -- the store's own historical beer market size,
-- not a name lookup. This split is a PM-reviewable modelling choice (neither
-- brief states a per-store SAB split explicitly); flagged in source_note.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.order_budget_ledger (
  client_id           text NOT NULL DEFAULT 'socialbrand',
  store_code          text NOT NULL,
  route_key           text NOT NULL,              -- 'DIRECT_BEER', 'DC', etc.
  year_month          date NOT NULL,               -- first of month
  budget_amount       numeric NOT NULL,
  committed_amount    numeric NOT NULL DEFAULT 0,  -- orders generated, not yet landed
  landed_amount       numeric NOT NULL DEFAULT 0,  -- GRV-confirmed receipts this month
  sales_actual        numeric NOT NULL DEFAULT 0,  -- route-scoped sales, refreshed nightly
  beat_carry_forward  numeric NOT NULL DEFAULT 0,  -- prior month's beat, carried per SB-AP-REPAY-001 §5
  scope               text NOT NULL DEFAULT 'DEMO_CALIBRATION',
  source_note         text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, route_key, year_month)
);

COMMENT ON TABLE public.order_budget_ledger IS
  'R22 budget gauge source: budget/committed/landed/sales_actual per store per
   route per month. Seeded from SB-AP-REPAY-001 (group) split by SB-STRAT-002
   §6b LY H2 beer-sales share (per-store). SB-CC-BLOOM-003 Ship 1.';

INSERT INTO public.order_budget_ledger (store_code, route_key, year_month, budget_amount, source_note)
VALUES
  -- 21355 TOPS Delareyville, share 26.07% (2.93M / 11.24M)
  ('21355','DIRECT_BEER','2026-07-01', 216363.88, 'SB-AP-REPAY-001 §2 Jul group SAB R830,000 x 26.07% store share (SB-STRAT-002 §6b LY H2 beer sales R2.93M/R11.24M)'),
  ('21355','DIRECT_BEER','2026-08-01', 237230.25, 'Aug group SAB R910,000 x 26.07%'),
  ('21355','DIRECT_BEER','2026-09-01', 232008.90, 'Sep group SAB R890,000 x 26.07%'),
  ('21355','DIRECT_BEER','2026-10-01', 273820.99, 'Oct group SAB R1,050,000 x 26.07%'),
  ('21355','DIRECT_BEER','2026-11-01', 286865.48, 'Nov group SAB R1,100,000 x 26.07%'),
  ('21355','DIRECT_BEER','2026-12-01', 432876.34, 'Dec group SAB R1,660,000 x 26.07%'),
  -- 80176 TOPS Roosville, share 50.44% (5.67M / 11.24M)
  ('80176','DIRECT_BEER','2026-07-01', 418593.59, 'Jul group SAB R830,000 x 50.44% (SB-STRAT-002 §6b R5.67M/R11.24M)'),
  ('80176','DIRECT_BEER','2026-08-01', 458973.31, 'Aug group SAB R910,000 x 50.44%'),
  ('80176','DIRECT_BEER','2026-09-01', 448953.74, 'Sep group SAB R890,000 x 50.44%'),
  ('80176','DIRECT_BEER','2026-10-01', 529649.47, 'Oct group SAB R1,050,000 x 50.44%'),
  ('80176','DIRECT_BEER','2026-11-01', 554870.11, 'Nov group SAB R1,100,000 x 50.44%'),
  ('80176','DIRECT_BEER','2026-12-01', 837224.02, 'Dec group SAB R1,660,000 x 50.44%'),
  -- 80579 TOPS Dice, share 23.49% (2.64M / 11.24M)
  ('80579','DIRECT_BEER','2026-07-01', 195042.53, 'Jul group SAB R830,000 x 23.49% (SB-STRAT-002 §6b R2.64M/R11.24M)'),
  ('80579','DIRECT_BEER','2026-08-01', 213796.44, 'Aug group SAB R910,000 x 23.49%'),
  ('80579','DIRECT_BEER','2026-09-01', 209037.37, 'Sep group SAB R890,000 x 23.49%'),
  ('80579','DIRECT_BEER','2026-10-01', 246529.54, 'Oct group SAB R1,050,000 x 23.49%'),
  ('80579','DIRECT_BEER','2026-11-01', 258264.41, 'Nov group SAB R1,100,000 x 23.49%'),
  ('80579','DIRECT_BEER','2026-12-01', 389899.64, 'Dec group SAB R1,660,000 x 23.49%')
ON CONFLICT (store_code, route_key, year_month) DO UPDATE SET
  budget_amount = EXCLUDED.budget_amount,
  source_note = EXCLUDED.source_note,
  updated_at = now();

GRANT SELECT ON public.order_budget_ledger TO anon, authenticated;

-- Sanity check: store splits sum back to the group monthly total (R22)
DO $$
DECLARE v_jul numeric;
BEGIN
  SELECT sum(budget_amount) INTO v_jul FROM public.order_budget_ledger
    WHERE route_key='DIRECT_BEER' AND year_month='2026-07-01';
  IF ABS(v_jul - 830000) > 1 THEN
    RAISE EXCEPTION 'July SAB split does not reconcile to group budget: got %, expected 830000', v_jul;
  END IF;
END $$;
