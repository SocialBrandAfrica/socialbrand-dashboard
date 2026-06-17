-- =============================================================================
-- create_v_legacy_reporting_views.sql
-- SB-CC-RECONCILE-001 Phase 1 -- canonical source-of-record for the 7 legacy
-- reporting views that had NO committed CREATE. Definitions captured verbatim
-- from LIVE 2026-06-17 (pg_get_viewdef). CREATE OR REPLACE => safe no-op against
-- live (reconciles repo to live). Grouped as a cohort of legacy views.
--
-- NOTE (R26, not scope creep): v_diwaais / v_negative_soh / v_slow_movers /
-- v_focus_trend still read daily_snapshots (PRSSALE). Migrating them onto the
-- sigma-native / l2_classification spine is the stock-facts thread, NOT this
-- reconcile. Captured here as-is. v_cashier_performance / v_payment_splits read
-- the (empty) TillWatch shells; v_push_health reads push_log.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_cashier_performance AS
 SELECT client_id,
    store_code,
    txn_date,
    cashier_code,
    count(*) AS txn_count,
    sum(item_count) AS items_scanned,
    sum(total_amount) AS sales_total,
    avg(total_amount) AS avg_basket
   FROM transaction_headers
  WHERE txn_type = 'SALE'::text
  GROUP BY client_id, store_code, txn_date, cashier_code;

CREATE OR REPLACE VIEW public.v_diwaais AS
 WITH latest AS (
         SELECT DISTINCT ON (daily_snapshots.store_code, daily_snapshots.ean) daily_snapshots.id,
            daily_snapshots.store_code,
            daily_snapshots.store_name,
            daily_snapshots.file_date,
            daily_snapshots.snapshot_date,
            daily_snapshots.ean,
            daily_snapshots.description,
            daily_snapshots.size,
            daily_snapshots.unit,
            daily_snapshots.sell_price,
            daily_snapshots.vat_pct,
            daily_snapshots.today_qty,
            daily_snapshots.today_cost,
            daily_snapshots.today_sales,
            daily_snapshots.period_qty,
            daily_snapshots.period_cost,
            daily_snapshots.period_sales,
            daily_snapshots.soh,
            daily_snapshots.dept_code,
            daily_snapshots.dept_name,
            daily_snapshots.sub_dept_code,
            daily_snapshots.sub_dept_name,
            daily_snapshots.internal_ref,
            daily_snapshots.status,
            daily_snapshots.promo,
            daily_snapshots.last_sales_date_raw,
            daily_snapshots.last_sales_date_iso,
            daily_snapshots.unit_cost,
            daily_snapshots.is_placeholder
           FROM daily_snapshots
          ORDER BY daily_snapshots.store_code, daily_snapshots.ean, daily_snapshots.snapshot_date DESC, daily_snapshots.id DESC
        )
 SELECT l.store_code,
    l.ean,
    COALESCE(p.description, l.description) AS description,
    COALESCE(p.size, l.size) AS size,
    COALESCE(p.sub_department, l.sub_dept_name) AS sub_department,
    p.supplier_code,
    l.soh,
    l.sell_price,
    COALESCE(p.list_cost, l.unit_cost) AS list_cost,
    l.period_sales,
    l.last_sales_date_iso AS last_sales_date,
    l.snapshot_date,
    l.period_qty,
    l.period_cost,
    l.dept_name,
    l.sub_dept_name,
    l.status,
    l.is_placeholder,
    s.supplier_name
   FROM latest l
     LEFT JOIN products p ON p.store_id = l.store_code AND p.ean = l.ean
     LEFT JOIN suppliers s ON s.supplier_code = p.supplier_code;

CREATE OR REPLACE VIEW public.v_focus_trend AS
 SELECT store_code,
    snapshot_date,
    ean,
    dept_name,
    sub_dept_name,
    description,
    sum(today_sales) AS sales,
    sum(today_qty) AS qty
   FROM daily_snapshots
  GROUP BY store_code, snapshot_date, ean, dept_name, sub_dept_name, description;

CREATE OR REPLACE VIEW public.v_negative_soh AS
 SELECT store_code,
    store_name,
    snapshot_date,
    ean,
    description,
    sub_dept_name,
    soh,
    sell_price,
    period_qty,
    last_sales_date_iso AS last_sales_date
   FROM ( SELECT DISTINCT ON (daily_snapshots.store_code, daily_snapshots.ean) daily_snapshots.id,
            daily_snapshots.store_code,
            daily_snapshots.store_name,
            daily_snapshots.file_date,
            daily_snapshots.snapshot_date,
            daily_snapshots.ean,
            daily_snapshots.description,
            daily_snapshots.size,
            daily_snapshots.unit,
            daily_snapshots.sell_price,
            daily_snapshots.vat_pct,
            daily_snapshots.today_qty,
            daily_snapshots.today_cost,
            daily_snapshots.today_sales,
            daily_snapshots.period_qty,
            daily_snapshots.period_cost,
            daily_snapshots.period_sales,
            daily_snapshots.soh,
            daily_snapshots.dept_code,
            daily_snapshots.dept_name,
            daily_snapshots.sub_dept_code,
            daily_snapshots.sub_dept_name,
            daily_snapshots.internal_ref,
            daily_snapshots.status,
            daily_snapshots.promo,
            daily_snapshots.last_sales_date_raw,
            daily_snapshots.last_sales_date_iso,
            daily_snapshots.unit_cost,
            daily_snapshots.is_placeholder
           FROM daily_snapshots
          ORDER BY daily_snapshots.store_code, daily_snapshots.ean, daily_snapshots.snapshot_date DESC, daily_snapshots.id DESC) latest
  WHERE soh < 0::numeric
  ORDER BY store_code, soh;

CREATE OR REPLACE VIEW public.v_payment_splits AS
 SELECT client_id,
    store_code,
    txn_date,
    payment_type,
    count(DISTINCT txn_number) AS txn_count,
    sum(amount) AS total_amount
   FROM transaction_payments
  GROUP BY client_id, store_code, txn_date, payment_type;

CREATE OR REPLACE VIEW public.v_push_health AS
 WITH latest AS (
         SELECT DISTINCT ON (push_log.store_code, push_log.table_name) push_log.store_code,
            push_log.table_name,
            push_log.completed_at AS last_success_at,
            push_log.rows_pushed AS last_rows_pushed
           FROM push_log
          WHERE push_log.status = 'SUCCESS'::text
          ORDER BY push_log.store_code, push_log.table_name, push_log.completed_at DESC
        )
 SELECT store_code,
    table_name,
    last_success_at,
    last_rows_pushed,
        CASE
            WHEN last_success_at > (now() - '25:00:00'::interval) THEN 'OK'::text
            WHEN last_success_at > (now() - '49:00:00'::interval) THEN 'STALE'::text
            ELSE 'MISSING'::text
        END AS freshness
   FROM latest
  ORDER BY store_code, table_name;

CREATE OR REPLACE VIEW public.v_slow_movers AS
 SELECT store_code,
    store_name,
    snapshot_date,
    ean,
    description,
    sub_dept_name,
    soh,
    sell_price,
    unit_cost,
    round(soh * unit_cost, 2) AS capital_tied,
    last_sales_date_iso AS last_sales_date
   FROM ( SELECT DISTINCT ON (daily_snapshots.store_code, daily_snapshots.ean) daily_snapshots.id,
            daily_snapshots.store_code,
            daily_snapshots.store_name,
            daily_snapshots.file_date,
            daily_snapshots.snapshot_date,
            daily_snapshots.ean,
            daily_snapshots.description,
            daily_snapshots.size,
            daily_snapshots.unit,
            daily_snapshots.sell_price,
            daily_snapshots.vat_pct,
            daily_snapshots.today_qty,
            daily_snapshots.today_cost,
            daily_snapshots.today_sales,
            daily_snapshots.period_qty,
            daily_snapshots.period_cost,
            daily_snapshots.period_sales,
            daily_snapshots.soh,
            daily_snapshots.dept_code,
            daily_snapshots.dept_name,
            daily_snapshots.sub_dept_code,
            daily_snapshots.sub_dept_name,
            daily_snapshots.internal_ref,
            daily_snapshots.status,
            daily_snapshots.promo,
            daily_snapshots.last_sales_date_raw,
            daily_snapshots.last_sales_date_iso,
            daily_snapshots.unit_cost,
            daily_snapshots.is_placeholder
           FROM daily_snapshots
          ORDER BY daily_snapshots.store_code, daily_snapshots.ean, daily_snapshots.snapshot_date DESC, daily_snapshots.id DESC) latest
  WHERE soh > 0::numeric AND (period_qty = 0::numeric OR period_qty IS NULL) AND is_placeholder = false
  ORDER BY store_code, (round(soh * unit_cost, 2)) DESC NULLS LAST;
