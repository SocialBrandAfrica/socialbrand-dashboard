-- =============================================================================
-- create_shell_tables.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for the empty
-- future-feature SHELL tables (all 0 rows live, created together in early schema,
-- no prior committed CREATE). Grouped in one file as a cohort -- they are unused
-- placeholders for planned apps (Vigil/TillWatch tills, Root/SupplierLens GRV,
-- Mark promotions). Rebuilt from LIVE 2026-06-17. IF NOT EXISTS => no-op vs live.
-- If/when a feature is built, promote its table to its own create_<table>.sql.
-- =============================================================================

-- Root / SupplierLens (deliveries, supplier invoices/terms)
CREATE TABLE IF NOT EXISTS public.deliveries (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  delivery_ref text NOT NULL,
  delivery_date date NOT NULL,
  supplier_code text,
  ean text NOT NULL,
  plu_code text,
  description text,
  qty_ordered numeric(10,3),
  qty_received numeric(10,3),
  qty_variance numeric(10,3),
  unit_cost numeric(10,4),
  line_value numeric(12,2),
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT deliveries_pkey PRIMARY KEY (client_id, store_code, delivery_ref, ean)
);

CREATE TABLE IF NOT EXISTS public.supplier_invoices (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  invoice_number text NOT NULL,
  supplier_code text,
  invoice_date date,
  invoice_total numeric(14,2),
  vat_amount numeric(12,2),
  status text,
  delivery_ref text,
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT supplier_invoices_pkey PRIMARY KEY (client_id, store_code, invoice_number)
);

CREATE TABLE IF NOT EXISTS public.supplier_terms (
  term_id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  supplier_code text NOT NULL,
  settlement_days integer,
  settlement_discount numeric(5,2),
  buying_discount numeric(5,2),
  rebate_pct numeric(5,2),
  valid_from date,
  valid_to date,
  CONSTRAINT supplier_terms_client_id_store_code_supplier_code_valid_fro_key UNIQUE (client_id, store_code, supplier_code, valid_from),
  CONSTRAINT supplier_terms_pkey PRIMARY KEY (term_id)
);

-- Rhythm / staff (employees)
CREATE TABLE IF NOT EXISTS public.employees (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  empl_code text NOT NULL,
  empl_name text,
  role_code text,
  is_active boolean DEFAULT true,
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT employees_pkey PRIMARY KEY (client_id, store_code, empl_code)
);

-- Mark / promotions (legacy promo shells -- distinct from sigma_promotions L1)
CREATE TABLE IF NOT EXISTS public.promotions (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  promo_code text NOT NULL,
  promo_name text,
  promo_type text,
  valid_from date,
  valid_to date,
  is_active boolean DEFAULT true,
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT promotions_pkey PRIMARY KEY (client_id, store_code, promo_code)
);

CREATE TABLE IF NOT EXISTS public.promotion_lines (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  promo_code text NOT NULL,
  ean text NOT NULL,
  plu_code text,
  promo_price numeric(10,4),
  normal_price numeric(10,4),
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT promotion_lines_pkey PRIMARY KEY (client_id, store_code, promo_code, ean)
);

-- Vigil / TillWatch (transaction headers/lines/payments)
CREATE TABLE IF NOT EXISTS public.transaction_headers (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  txn_number bigint NOT NULL,
  txn_date date NOT NULL,
  txn_time time without time zone,
  till_number smallint,
  cashier_code text,
  total_amount numeric(12,2),
  item_count integer,
  txn_type text,
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT transaction_headers_pkey PRIMARY KEY (client_id, store_code, txn_date, txn_number)
);

CREATE TABLE IF NOT EXISTS public.transaction_lines (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  txn_number bigint NOT NULL,
  txn_date date NOT NULL,
  line_seq smallint NOT NULL,
  ean text NOT NULL,
  plu_code text,
  description text,
  qty numeric(10,3),
  unit_price numeric(10,4),
  line_total numeric(12,2),
  dept_code text,
  sub_dept_code text,
  is_promotion boolean DEFAULT false,
  promotion_code text,
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT transaction_lines_pkey PRIMARY KEY (client_id, store_code, txn_date, txn_number, line_seq)
);

CREATE TABLE IF NOT EXISTS public.transaction_payments (
  client_id uuid NOT NULL,
  store_code text NOT NULL,
  txn_number bigint NOT NULL,
  txn_date date NOT NULL,
  payment_type text NOT NULL,
  amount numeric(12,2),
  pushed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT transaction_payments_pkey PRIMARY KEY (client_id, store_code, txn_date, txn_number, payment_type)
);
