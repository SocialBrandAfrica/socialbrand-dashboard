-- ENG-039, PM ruling 14-10 s15 pt5: a derived due date applies only from the first date with statement evidence;
-- older headers read UNDATED and are not back-filled. The store-server probe is not needed for this.
-- Evidence: ten SPAR statements dated 31/07/26 covering invoice rows 26/06/26 to 24/07/26. Derivative of the SPAR statements (R25 s1), interim.
-- This is TIME SINCE BILLED plus an interim due date, never DAYS OVERDUE (L1 has no paid flag).
-- Before (14-10 00:39 SAST): sigma_orders.due_date has 1 distinct value in 61,186 rows; 0 derived due dates in v_creditor_ageing.
-- After (14-10 ~17:1x SAST, l2 snapshot of the 14-10 pipeline): headers 43,194; DERIVED 3,483; UNDATED 30,091; 270 view rows NO_TERMS_KNOWN.
INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes) VALUES
 ('creditor_terms_days_dc','*',19,'DEMO_CALIBRATION',DATE '2026-10-14','ENG-039 / canon 12e (PM 2026-07-27): SPAR Warehouse A (DC) days after the statement Friday. Derivative of ten SPAR statements dated 31/07/26 (R25 s1), interim. Applies only to Sigma TYP Z in lGruppe 1 (DC accounts, schema map v1.4e).'),
 ('creditor_terms_days_dropship','*',31,'DEMO_CALIBRATION',DATE '2026-10-14','ENG-039 / canon 12e: SPAR Dropshipments (B), same basis. Applies only to TYP S in lGruppe 3 (active DRP).'),
 ('creditor_statement_close_dow','*',5,'DEMO_CALIBRATION',DATE '2026-10-14','Statements weekly, Friday-dated (Postgres extract(dow), Friday = 5).'),
 ('creditor_terms_valid_from_yyyymmdd','*',20260626,'DEMO_CALIBRATION',DATE '2026-10-14','PM ruling 14-10-2026 s15 pt5: derived due dates apply from the first date with statement evidence, 2026-06-26 (earliest invoice row on the ten statements dated 31/07/26). Older headers read UNDATED and are not back-filled. Moves only when earlier statements are loaded.')
ON CONFLICT (config_key, store_format) DO NOTHING;

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
COMMENT ON FUNCTION public.creditor_derived_due_date(date,text,integer) IS 'GRADE: DERIVED. ENG-039. Interim statement-rule due date: the Friday on or after the invoice date plus the account terms (DC Z/lGruppe 1 = 19 days, dropship S/lGruppe 3 = 31 days), from forge_config. NULL when the account terms are unknown, the invoice is undated, or the invoice date is before creditor_terms_valid_from_yyyymmdd (UNDATED, never back-filled). Not DAYS OVERDUE: L1 has no paid flag.';

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
COMMENT ON VIEW public.v_creditor_ageing IS 'SB-CC-DEBT-001 deliverable 2 + ENG-039 (14-10-2026). Creditor ageing per (store, supplier, bucket) carrying the l2_creditor_stock_match verdict through. AGES ON invoice_date (fallback grv_date): this is TIME SINCE BILLED, never DAYS OVERDUE (L1 has no paid flag; do not relabel). Derived due dates (earliest/latest_derived_due_date) are interim and statement-rule based, apply only to DC Z/lGruppe 1 and dropship S/lGruppe 3 accounts and only from the first date with statement evidence (forge_config creditor_terms_valid_from_yyyymmdd); older invoices of those accounts read UNDATED (headers_due_undated), never back-filled. OPEN_ORDER headers excluded.';
SELECT pg_notify('pgrst','reload schema');