-- =============================================================================
-- create_l2_creditor_stock_match.sql
-- SB-CC-DEBT-001 / CANON §12e -- THE COST-INTEGRITY BASELINE.
-- Applied 2026-07-26, migrations debt001_01..debt001_07. Owner: CC.
-- =============================================================================
-- One row per (store_code, order_nr): what we RECEIVED (sigma_movements R/W)
-- married to what we OWE (sigma_orders), with a named verdict carrying its
-- reason in words a buyer can read (R29). HEADER grain per §12e point 5.
--
-- Pieter's ruling: establish this BEFORE any cost calculation. Budgeting,
-- projections, cash-margin and capital-tied all run off purchase cost, and
-- purchase cost is untrustworthy until the receipt is married to the invoice.
--
-- R22 PROOF REPRODUCED FROM THIS FACT (not an ad-hoc query), July 2026, ×5,
-- exact to the cent against PM's independent baseline:
--   10116  4,345,966.73 / 4,330,605.45 / -15,361.28
--   21355    442,224.39 /   430,251.57 / -11,972.82
--   80175  1,682,744.56 / 1,681,609.46 /  -1,135.10
--   80176    534,790.22 /   510,921.75 / -23,868.47
--   80579     22,458.96 /    22,458.97 /     +0.01
--   TOTAL  7,028,184.86 / 6,975,847.20 / -52,337.66  (0.745%)
--   684 headers / 13,459 receipt lines. Delta = invoice_ex_vat - grv_cost.
--
-- ── PM'S THREE LANDMINE LAWS, APPLIED ───────────────────────────────────────
-- VAT   : invoice_value is VAT-INCLUSIVE, cost_value is EX-VAT. Compare
--         invoice_value - COALESCE(vat_total,0). Raw comparison shows a uniform
--         +11.8% phantom "overcharge" at every store.
-- UNITS : invoiced_qty × invoiced_cost is SINGLES × CASE cost (15.7× inflation,
--         R4.7M -> R73.6M at 10116). Not used here at all -- the GRV leg is
--         sigma_movements.cost_value.
-- GRAIN : header grain. sigma_order_lines.received_qty is DEAD (0.0000 on
--         1,007,914 of 1,007,915 rows) and is never read.
--
-- ── FOUR FURTHER SENTINEL TRAPS FOUND BY CC AND NEUTRALISED HERE ────────────
-- (a) grv_nr = 0 IS THE "NO GRV" SENTINEL, NOT NULL -- 18,049 headers. grv_nr is
--     NULL on ZERO rows, so `grv_nr IS NOT NULL` reports NO no-GRV cases at all
--     and hides the entire overpayment-risk population. Normalised with NULLIF.
-- (b) vat_total IS POPULATED WHERE invoice_value = 0 -- 15,974 headers. So
--     invoice_value - vat_total FABRICATES a NEGATIVE invoice: -R1,909,649
--     group-wide, -R225,865 on observable no-GRV headers. invoice_ex_vat is
--     therefore computed ONLY where invoice_value > 0, else NULL.
-- (c) DATE SENTINELS '1990-01-01': order_date on 41,920/55,002 (76%),
--     invoice_date on 20,618, grv_date on 5,054. All normalised to NULL.
-- (d) due_date IS A DEAD COLUMN -- ONE distinct value ('1990-01-01') on ALL
--     55,002 rows. See create_v_creditor_ageing.sql; the column is carried here
--     as always-NULL so a future L1 fix has a home.
--
-- ── RECEIPT OBSERVABILITY (R23 §2 -- undecoded is UNCERTAIN, never silent) ───
-- sigma_movements R/W spans 2025-02-01..2026-07-25. 12,998 headers carry a real
-- grv_nr whose grv_date PREDATES that floor, so their receipt leg cannot be seen.
-- Those get RECEIPT_OUT_OF_WINDOW and are NEVER accused of being unreceived.
-- The floor is MEASURED from the ledger at refresh time, never hardcoded.
--
-- ── TOLERANCE, JUSTIFIED TO SOURCE (R21, not invented) ──────────────────────
-- |delta| on the 684 married July headers is BIMODAL: 386 exact zero, 576 within
-- 5c, 625 (91.4%) within R1, then only 4 between R1 and R10, then 55 genuine
-- breaks to a max of R12,527. R1.00 absolute sits in the natural gap. No
-- percentage floor was measurable as a break, so none was invented.
-- Config: forge_config.creditor_match_tolerance_rand, DEMO_CALIBRATION (R25/R28).
--
-- ── VERDICTS (7, cascade, first match wins) ─────────────────────────────────
-- OPEN_ORDER            placed, no GRV, no invoice -- an outstanding order, NOT a
--                       creditor exception. 15,470 group-wide. This is also the
--                       population BLOOM-015's 7k arbiter needs.
-- NO_GRV                invoice on the books, grv_nr = 0 -- we may be about to pay
--                       for goods that never arrived (Pieter's named risk).
-- NO_INVOICE            GRV, no invoice header -- stock we may hold unbilled.
-- INVOICE_VALUE_MISSING invoice_nr present, invoice_value = 0 -- a CAPTURE gap,
--                       never "no money owed".
-- RECEIPT_OUT_OF_WINDOW both legs exist, receipt not in our ledger window.
-- MATCHED               reconciles within tolerance.
-- VALUE_BREAK           both legs present, values disagree -- the one that matters.
--
-- ⭐ WHAT THE REASON STRINGS MAY NEVER SAY (§12e point 7, Pieter's correction to
-- a PM over-claim, preserved): we CANNOT state the purchase COST is wrong. A real
-- case cost on the wrong single code produces the same signature. Every reason is
-- written as "the wrong code or article was sent or received, cost basis
-- unmatched" -- never "the cost is wrong".
-- CC applied the same discipline to its own text: the NO_INVOICE reason initially
-- asserted "stock was received ... we are holding stock we have not been billed
-- for", but ALL such headers carry ZERO receipt lines, so the claim exceeded the
-- evidence. It now states the missing invoice as fact and the receipt as
-- unverified, with no rand value claimed.
-- =============================================================================

INSERT INTO forge_config (config_key, store_format, value_num, scope, effective_from, notes)
SELECT 'creditor_match_tolerance_rand', '*', 1.00, 'DEMO_CALIBRATION', '2026-07-26',
       'SB-CC-DEBT-001. Absolute rand tolerance on |invoice_ex_vat - grv_cost_ex_vat| at header grain. Measured bimodal on 684 married July headers: 625 (91.4%) within R1, only 4 between R1 and R10, then 55 genuine breaks to R12,527. Not a percentage floor -- no percentage was measurable as a natural break.'
WHERE NOT EXISTS (SELECT 1 FROM forge_config WHERE config_key='creditor_match_tolerance_rand');

CREATE TABLE IF NOT EXISTS public.l2_creditor_stock_match (
  client_id          text        NOT NULL DEFAULT 'socialbrand',
  store_code         text        NOT NULL,
  order_nr           bigint      NOT NULL,
  supplier_nr        bigint,
  supplier_name      text,
  order_date         date,                 -- sentinel-normalised
  grv_nr             bigint,               -- 0 normalised to NULL
  grv_date           date,
  invoice_nr         text,
  invoice_date       date,
  due_date           date,                 -- ALWAYS NULL: source column is a dead sentinel
  grv_cost_ex_vat    numeric,              -- sigma_movements R/W, ex-VAT; NULL when unobservable
  receipt_lines      integer     NOT NULL DEFAULT 0,
  invoice_ex_vat     numeric,              -- ONLY where invoice_value > 0
  vat_total          numeric,
  delta_ex_vat       numeric,              -- invoice_ex_vat - grv_cost; POSITIVE = billed more than arrived
  delta_pct          numeric,
  verdict            text        NOT NULL,
  reason             text        NOT NULL,
  receipt_observable boolean     NOT NULL,
  order_line_count   integer     NOT NULL DEFAULT 0,
  age_anchor_date    date,                 -- invoice_date, else grv_date
  age_days           integer,
  engine_version     text        NOT NULL DEFAULT 'debt001-v1',
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_code, order_nr),
  CONSTRAINT l2_creditor_stock_match_verdict_ck CHECK (verdict IN
    ('MATCHED','VALUE_BREAK','NO_INVOICE','NO_GRV','INVOICE_VALUE_MISSING',
     'RECEIPT_OUT_OF_WINDOW','OPEN_ORDER'))
);

COMMENT ON TABLE public.l2_creditor_stock_match IS
  'SB-CC-DEBT-001 / CANON §12e. The cost-integrity baseline: per (store, order_nr), GRV cost ex-VAT from sigma_movements married to invoice ex-VAT from sigma_orders, with a named verdict and its reason in words a buyer can read (R29). Header grain. Applies the VAT law, avoids the singles-vs-case units trap entirely, never reads the dead received_qty, and normalises the grv_nr=0 and date-1990 sentinels. due_date is NULL on every row because the source column holds one sentinel value on all 55,002 rows. A cost is trustworthy only where the invoice is married to the GRV, and this table says so per order, not per query. Never asserts that a COST is wrong -- only that a receipt is unmatched (§12e point 7).';

CREATE INDEX IF NOT EXISTS l2_creditor_stock_match_verdict_idx  ON public.l2_creditor_stock_match (store_code, verdict);
CREATE INDEX IF NOT EXISTS l2_creditor_stock_match_supplier_idx ON public.l2_creditor_stock_match (store_code, supplier_nr);
CREATE INDEX IF NOT EXISTS l2_creditor_stock_match_age_idx      ON public.l2_creditor_stock_match (store_code, age_anchor_date);

ALTER TABLE public.l2_creditor_stock_match ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS l2_creditor_stock_match_read ON public.l2_creditor_stock_match;
CREATE POLICY l2_creditor_stock_match_read ON public.l2_creditor_stock_match FOR SELECT USING (true);
GRANT SELECT ON public.l2_creditor_stock_match TO anon, authenticated;

-- The refresh function's live body is authoritative; see migration
-- debt001_06_no_invoice_honesty_pipeline_wire_retire_scaffold for the current
-- definition (reproduced by pg_get_functiondef at any time). It is idempotent
-- per store (DELETE + re-INSERT), raises rather than returning a false green on
-- 0 rows (§8.6 guard 4), and ships the R30 double-revoke below.
--
-- REVOKE ALL     ON FUNCTION public.refresh_l2_creditor_stock_match(text) FROM PUBLIC;
-- REVOKE EXECUTE ON FUNCTION public.refresh_l2_creditor_stock_match(text) FROM anon;
-- GRANT  EXECUTE ON FUNCTION public.refresh_l2_creditor_stock_match(text) TO authenticated;
--
-- Wired into refresh_l2_pipeline after the Identity Phase 2 block and ahead of
-- every cost consumer. See sql/create_refresh_l2_pipeline.sql.
--
-- LIVE AT BUILD (2026-07-26), rows / verdict split:
--   10116 37,263  MATCHED 9,083 · OPEN_ORDER 11,017 · RECEIPT_OUT_OF_WINDOW 10,534
--                 NO_INVOICE 2,932 · INVOICE_VALUE_MISSING 1,922 · NO_GRV 1,443 · VALUE_BREAK 332
--   21355  1,538  MATCHED 1,051 · NO_INVOICE 281 · OPEN_ORDER 130 · VALUE_BREAK 53 · IVM 23
--   80175 13,114  MATCHED 6,244 · OPEN_ORDER 3,930 · NO_INVOICE 1,318 · NO_GRV 1,140 · IVM 267 · VB 206 · ROOW 9
--   80176  1,767  MATCHED 979 · NO_INVOICE 410 · OPEN_ORDER 263 · VALUE_BREAK 88 · IVM 25 · ROOW 2
--   80579  1,324  MATCHED 893 · NO_INVOICE 211 · OPEN_ORDER 130 · VALUE_BREAK 74 · IVM 16
