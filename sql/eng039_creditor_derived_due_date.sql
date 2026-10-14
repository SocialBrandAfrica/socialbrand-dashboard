-- ENG-039: interim derived due date for creditor ageing. creditor_derived_due_date() and creditor_due_class() read forge_config keys creditor_terms_days_dc, creditor_terms_days_dropship, creditor_statement_close_dow and creditor_terms_valid_from_yyyymmdd.
-- The key values are seeded in the private database and recorded in BUG-LOG ENG-039; they are deliberately not in this file.
-- Time since billed plus an interim due date, never days overdue: L1 has no paid flag.
-- Before (14-10 00:39 SAST): sigma_orders.due_date holds 1 distinct value in 61,186 rows; v_creditor_ageing carried no derived due date.
-- After (14-10 ~17:1x SAST): 43,194 headers; 3,483 DERIVED; 30,091 UNDATED; 270 view rows NO_TERMS_KNOWN.
-- forge_config keys read below: creditor_terms_days_dc, creditor_terms_days_dropship, creditor_statement_close_dow, creditor_terms_valid_from_yyyymmdd (values in the private database, BUG-LOG ENG-039).

CREATE OR REPLACE FUNCTION public.creditor_derived_due_date(p_invoice_date date, p_supplier_type text, p_supplier_group integer)
RETURNS date LANGUAGE sql STABLE SET search_path = public, pg_temp AS $f$
 SELECT CASE WHEN p_invoice_date IS NULL OR p_invoice_date > CURRENT_DATE THEN NULL
        WHEN to_char(p_invoice_date,'YYYYMMDD')::int < (SELECT value_num FROM public.forge_config WHERE config_key='creditor_terms_valid_from_yyyymmdd' AND store_format='*' AND retired_on IS NULL ORDER BY effective_from DESC LIMIT 1) THEN NULL
        ELSE p_invoice_date + ((c.dow::int - extract(dow FROM p_invoice_date)::int + 7) % 7) + t.d::int END
 FROM (SELECT value_num AS d FROM public.forge_config
        WHERE config_key = CASE WHEN p_supplier_type='Z' AND p_supplier_group=1 THEN 'creditor_terms_days_dc'
                                WHEN p_supplier_type='S' AND p_supplier_group=3 THEN 'creditor_terms_days_dropship' END
          AND store_format='*' AND retired_on IS NULL ORDER BY effective_from DESC LIMIT 1) t
 CROSS JOIN (SELECT value_num AS dow FROM public.forge_config
        WHERE config_key='creditor_statement_close_dow' AND store_format='*' AND retired_on IS NULL
        ORDER BY effective_from DESC LIMIT 1) c
$f$;
COMMENT ON FUNCTION public.creditor_derived_due_date(date,text,integer) IS 'GRADE: DERIVED. ENG-039. Interim statement-rule due date from the forge_config terms keys for the supplier type and group. NULL when the account terms are unknown, the invoice is undated, or the invoice date is before creditor_terms_valid_from_yyyymmdd (UNDATED, never back-filled). Not DAYS OVERDUE: L1 has no paid flag.';

CREATE OR REPLACE FUNCTION public.creditor_due_class(p_invoice_date date, p_supplier_type text, p_supplier_group integer)
RETURNS text LANGUAGE sql STABLE SET search_path = public, pg_temp AS $f$
 SELECT CASE
   WHEN NOT ((p_supplier_type='Z' AND p_supplier_group=1) OR (p_supplier_type='S' AND p_supplier_group=3)) OR p_supplier_type IS NULL THEN 'NO_TERMS_KNOWN'
   WHEN p_invoice_date IS NULL OR p_invoice_date > CURRENT_DATE THEN 'NO_TERMS_KNOWN'
   WHEN to_char(p_invoice_date,'YYYYMMDD')::int < (SELECT value_num FROM public.forge_config WHERE config_key='creditor_terms_valid_from_yyyymmdd' AND store_format='*' AND retired_on IS NULL ORDER BY effective_from DESC LIMIT 1) THEN 'UNDATED'
   ELSE 'DERIVED' END
$f$;
COMMENT ON FUNCTION public.creditor_due_class(date,text,integer) IS 'ENG-039. DERIVED / UNDATED (terms known, invoice older than the first statement evidence) / NO_TERMS_KNOWN, matching creditor_derived_due_date().';

CREATE OR REPLACE VIEW public.v_creditor_ageing AS
 WITH b AS (
         SELECT m.client_id, m.store_code, m.order_nr, m.supplier_nr, m.supplier_name, m.order_date, m.grv_nr, m.grv_date,
            m.invoice_nr, m.invoice_date, m.due_date, m.grv_cost_ex_vat, m.receipt_lines, m.invoice_ex_vat, m.vat_total,
            m.delta_ex_vat, m.delta_pct, m.verdict, m.reason, m.receipt_observable, m.order_line_count, m.age_anchor_date,
            m.age_days, m.engine_version, m.computed_at,
                CASE
                    WHEN m.age_anchor_date IS NULL THEN 'UNDATED'::text
                    WHEN m.age_days <= 30 THEN '0-30'::text
                    WHEN m.age_days <= 60 THEN '31-60'::text
                    WHEN m.age_days <= 90 THEN '61-90'::text
                    ELSE '90+'::text
                END AS ageing_bucket,
                CASE
                    WHEN m.age_anchor_date IS NULL THEN 5
                    WHEN m.age_days <= 30 THEN 1
                    WHEN m.age_days <= 60 THEN 2
                    WHEN m.age_days <= 90 THEN 3
                    ELSE 4
                END AS bucket_sort,
                CASE
                    WHEN m.invoice_date IS NOT NULL THEN 'invoice_date'::text
                    WHEN m.grv_date IS NOT NULL THEN 'grv_date'::text
                    ELSE 'none'::text
                END AS age_basis,
            public.creditor_derived_due_date(m.invoice_date, sm.supplier_type, sm.supplier_group) AS due_derived,
            public.creditor_due_class(m.invoice_date, sm.supplier_type, sm.supplier_group) AS due_class
           FROM l2_creditor_stock_match m
           LEFT JOIN sigma_supplier_master sm ON sm.client_id = m.client_id AND sm.store_code = m.store_code AND sm.supplier_nr = m.supplier_nr
          WHERE m.verdict <> 'OPEN_ORDER'::text
        )
 SELECT store_code, supplier_nr, supplier_name, ageing_bucket,
    min(bucket_sort) AS bucket_sort,
    count(*) AS headers,
    round(sum(COALESCE(invoice_ex_vat, 0::numeric)), 2) AS billed_ex_vat,
    round(sum(CASE WHEN verdict = 'MATCHED'::text THEN COALESCE(invoice_ex_vat, 0::numeric) ELSE 0::numeric END), 2) AS billed_backed_by_stock,
    round(sum(CASE WHEN verdict = ANY (ARRAY['VALUE_BREAK'::text, 'NO_GRV'::text]) THEN COALESCE(invoice_ex_vat, 0::numeric) ELSE 0::numeric END), 2) AS billed_at_risk,
    round(sum(CASE WHEN verdict = 'NO_INVOICE'::text THEN COALESCE(grv_cost_ex_vat, 0::numeric) ELSE 0::numeric END), 2) AS received_unbilled,
    round(sum(CASE WHEN verdict = 'VALUE_BREAK'::text THEN COALESCE(delta_ex_vat, 0::numeric) ELSE 0::numeric END), 2) AS value_break_delta,
    count(*) FILTER (WHERE verdict = 'MATCHED'::text) AS n_matched,
    count(*) FILTER (WHERE verdict = 'VALUE_BREAK'::text) AS n_value_break,
    count(*) FILTER (WHERE verdict = 'NO_GRV'::text) AS n_no_grv,
    count(*) FILTER (WHERE verdict = 'NO_INVOICE'::text) AS n_no_invoice,
    count(*) FILTER (WHERE verdict = 'INVOICE_VALUE_MISSING'::text) AS n_invoice_value_missing,
    count(*) FILTER (WHERE verdict = 'RECEIPT_OUT_OF_WINDOW'::text) AS n_unverifiable,
    max(age_days) AS oldest_days,
    string_agg(DISTINCT age_basis, '+'::text) AS age_basis,
    min(due_derived) AS earliest_derived_due_date,
    max(due_derived) AS latest_derived_due_date,
    count(*) FILTER (WHERE due_class = 'DERIVED') AS headers_with_derived_due,
    count(*) FILTER (WHERE due_class = 'UNDATED') AS headers_due_undated,
    CASE WHEN count(*) FILTER (WHERE due_class = 'DERIVED') > 0 THEN 'STATEMENT_RULE_CONFIG'
         WHEN count(*) FILTER (WHERE due_class = 'UNDATED') > 0 THEN 'UNDATED'
         ELSE 'NO_TERMS_KNOWN' END AS due_basis
   FROM b
  GROUP BY store_code, supplier_nr, supplier_name, ageing_bucket;
COMMENT ON VIEW public.v_creditor_ageing IS 'SB-CC-DEBT-001 deliverable 2 + ENG-039 (14-10-2026). Creditor ageing per (store, supplier, bucket) carrying the l2_creditor_stock_match verdict through. AGES ON invoice_date (fallback grv_date): this is TIME SINCE BILLED, never DAYS OVERDUE (L1 has no paid flag; do not relabel). Derived due dates (earliest/latest_derived_due_date) are interim and statement-rule based, apply only to the supplier type and group combinations that have configured terms and only from the first date with statement evidence (forge_config creditor_terms_valid_from_yyyymmdd); older invoices of those combinations read UNDATED (headers_due_undated), never back-filled. OPEN_ORDER headers excluded.';
SELECT pg_notify('pgrst','reload schema');