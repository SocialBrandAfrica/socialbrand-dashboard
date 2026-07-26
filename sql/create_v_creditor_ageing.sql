-- =============================================================================
-- create_v_creditor_ageing.sql
-- SB-CC-DEBT-001 deliverable 2 -- the creditor ageing instrument.
-- Applied 2026-07-26, migration debt001_05_v_creditor_ageing. Owner: CC.
-- =============================================================================
-- Answers the R31 Definition of Done in one read: WHO we owe (supplier), HOW MUCH
-- (billed_ex_vat), HOW OLD (ageing_bucket), and HOW MUCH IS BACKED BY STOCK THAT
-- ACTUALLY ARRIVED (billed_backed_by_stock vs billed_at_risk). Verdicts are
-- carried through, so an aged UNMATCHED invoice is visibly distinct from an aged
-- matched one -- which is what makes this a debts instrument and not a
-- data-integrity report.
--
-- ⚠️⚠️ DEVIATION FROM THE BRIEF, FORCED BY SOURCE AND NAMED (R23 §2).
-- SB-CC-DEBT-001 §3 and CANON §12e point 1 both specify ageing "off due_date",
-- on the stated basis that "due_date populated on 100% = the debtor-age/
-- creditor-ageing spine is already there".
--
-- MEASURED, and this is a canon correction: sigma_orders.due_date holds
-- **ONE distinct value, '1990-01-01', on ALL 55,002 rows**. It is 100% PRESENT
-- and 100% SENTINEL -- a DEAD COLUMN of exactly the same class as
-- sigma_order_lines.received_qty, which the same brief warns about three
-- paragraphs earlier. Ageing off it would print "13,355 days overdue" on every
-- row in the group: a confident, catastrophic-looking, completely false number.
--
-- Nor can a due date be DERIVED anywhere in L1:
--   sigma_supplier_master.terms_nr        unset on 13,794 / 13,794
--   sigma_supplier_master.settle_disc_1_days  set on      1 / 13,794
--   sigma_supplier_master.settle_disc_2_days  set on      0 / 13,794
--   sigma_supplier_master.creditor_nr     unset on 13,794 / 13,794
-- There is no payment-terms data in the platform at all.
--
-- SO THIS VIEW AGES ON invoice_date (how long since the supplier billed us),
-- falling back to grv_date (how long since the stock arrived) where a header is
-- received-but-unbilled. That honestly answers "how old".
-- ⛔ IT IS **TIME SINCE BILLED**, NOT **DAYS OVERDUE**. Never relabel it on a
-- screen -- without payment terms, "overdue" is unknowable.
--
-- OWED TO CLOSE THE GAP (an L1/extractor extraction, not a build): the real due
-- date and/or DBKOND payment terms. Named as a debt, not worked around silently.
--
-- OPEN_ORDER headers are EXCLUDED: nothing received and nothing billed is not a
-- payable. They belong to the ordering lane (BLOOM-015's outstanding-order
-- arbiter), not to creditors.
--
-- GROUP TOTALS AT BUILD (2026-07-26), by bucket -- headers / billed ex-VAT /
-- backed by stock / at risk:
--   0-30    1,150 /   7,556,140 /   6,574,439 /    980,242
--   31-60   1,457 /   9,054,501 /   8,321,707 /    694,047
--   61-90   1,564 /   9,390,798 /   8,897,890 /    485,005
--   90+    35,365 / 254,559,034 / 129,867,380 / 13,383,635
-- The 90+ bucket reaches back to 2012 invoice dates and contains 10,532
-- RECEIPT_OUT_OF_WINDOW headers (pre-2025-02 receipts we cannot verify, correctly
-- labelled rather than accused). A screen should default to the recent buckets;
-- the deep history is carried for completeness, not for action.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_creditor_ageing AS
WITH b AS (
  SELECT m.*,
         CASE WHEN m.age_anchor_date IS NULL THEN 'UNDATED'
              WHEN m.age_days <= 30  THEN '0-30'
              WHEN m.age_days <= 60  THEN '31-60'
              WHEN m.age_days <= 90  THEN '61-90'
              ELSE '90+' END AS ageing_bucket,
         CASE WHEN m.age_anchor_date IS NULL THEN 5
              WHEN m.age_days <= 30 THEN 1 WHEN m.age_days <= 60 THEN 2
              WHEN m.age_days <= 90 THEN 3 ELSE 4 END AS bucket_sort,
         CASE WHEN m.invoice_date IS NOT NULL THEN 'invoice_date'
              WHEN m.grv_date IS NOT NULL     THEN 'grv_date'
              ELSE 'none' END AS age_basis
  FROM l2_creditor_stock_match m
  WHERE m.verdict <> 'OPEN_ORDER'
)
SELECT
  b.store_code,
  b.supplier_nr,
  b.supplier_name,
  b.ageing_bucket,
  min(b.bucket_sort)                                              AS bucket_sort,
  count(*)                                                        AS headers,
  round(SUM(COALESCE(b.invoice_ex_vat,0)), 2)                     AS billed_ex_vat,
  round(SUM(CASE WHEN b.verdict='MATCHED' THEN COALESCE(b.invoice_ex_vat,0) ELSE 0 END), 2) AS billed_backed_by_stock,
  round(SUM(CASE WHEN b.verdict IN ('VALUE_BREAK','NO_GRV') THEN COALESCE(b.invoice_ex_vat,0) ELSE 0 END), 2) AS billed_at_risk,
  round(SUM(CASE WHEN b.verdict='NO_INVOICE' THEN COALESCE(b.grv_cost_ex_vat,0) ELSE 0 END), 2) AS received_unbilled,
  round(SUM(CASE WHEN b.verdict='VALUE_BREAK' THEN COALESCE(b.delta_ex_vat,0) ELSE 0 END), 2) AS value_break_delta,
  count(*) FILTER (WHERE b.verdict='MATCHED')               AS n_matched,
  count(*) FILTER (WHERE b.verdict='VALUE_BREAK')           AS n_value_break,
  count(*) FILTER (WHERE b.verdict='NO_GRV')                AS n_no_grv,
  count(*) FILTER (WHERE b.verdict='NO_INVOICE')            AS n_no_invoice,
  count(*) FILTER (WHERE b.verdict='INVOICE_VALUE_MISSING') AS n_invoice_value_missing,
  count(*) FILTER (WHERE b.verdict='RECEIPT_OUT_OF_WINDOW') AS n_unverifiable,
  max(b.age_days)                                           AS oldest_days,
  string_agg(DISTINCT b.age_basis, '+')                     AS age_basis
FROM b
GROUP BY b.store_code, b.supplier_nr, b.supplier_name, b.ageing_bucket;

COMMENT ON VIEW public.v_creditor_ageing IS
  'SB-CC-DEBT-001 deliverable 2. Creditor ageing per (store, supplier, bucket) carrying the l2_creditor_stock_match verdict through, so an aged UNMATCHED invoice is visibly distinct from an aged matched one. Answers the DoD: who we owe, how much, how old, and how much is backed by stock that actually arrived. ⚠️ AGES ON invoice_date (fallback grv_date), NOT due_date: sigma_orders.due_date holds one sentinel value (1990-01-01) on all 55,002 rows and no payment terms exist in L1 either (terms_nr unset 13,794/13,794). This is TIME SINCE BILLED, never DAYS OVERDUE -- do not relabel it. OPEN_ORDER headers are excluded: nothing received, nothing billed, not a payable.';

GRANT SELECT ON public.v_creditor_ageing TO anon, authenticated;

SELECT pg_notify('pgrst','reload schema');
