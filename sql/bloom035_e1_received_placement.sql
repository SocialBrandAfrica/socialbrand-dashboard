-- =============================================================================
-- BLOOM-035 E1 -- EVERY RECEIVED PRODUCT IS ON ITS LATEST-GRV DESK'S SHEET, AS AN ORDER ROW OR AS A
-- HIDDEN ROW WITH ITS REASON (R7 acceptance, PM ruling E1 of 13-10-2026, R32: a desk reads, it never
-- computes). BUG-LOG ENG-234.
--
-- ONE FACT, STOCKED NIGHTLY: l2_received_placement, one row per (store, product) received (R/W) in the
-- desk_receipt_window_days to the store's watermark. It says WHICH DESK the product belongs on (the
-- latest GRV supplier decides, never a link, PM ruling A1) and, where the recipe would not put it on that
-- desk's sheet as an order row, WHY, in a code and a sentence the buyer reads. Everything is derived:
-- the desk from the receipts and the desk tables, the reason from the engine's own facts (class, world,
-- link, verdict). Nothing is typed.
--
-- THE SHEET ROW: refresh_bloom_order_cache appends, after the recipe's own rows, one row per placement
-- fact of THIS desk that is not already on the sheet: line_kind 'unordered', suggested_packs 0, the reason
-- in hidden_reason and the code in placement_code. line_kind is extended with 'unordered'. A hidden SELLER
-- (line_kind 'hidden', the stockout correction withheld) stays exactly what it was: this never touches it.
--
-- THE SERVED PAYLOAD: rpc_bloom_order_cached WITHHOLDS 'unordered' rows from `lines` until the desk can
-- render them, exactly as it withholds 'covered' rows (ENG-102). The count of rows withheld is returned
-- (`unordered_withheld`), so the stored sheet carries every received product and the buyer's screen does
-- not fill with 12,000 zero rows before the desk groups them. Flip: remove the filter in the reader.
--
-- ORDER OF THE NIGHT: refresh_l2_pipeline (20:15 UTC) -> refresh_supplier_desks -> refresh_l2_received_placement
-- -> refresh_bloom_order_cache_all (23:30 UTC). The placement fact reads the desks the first function made.
--
-- ROLLBACK: restore refresh_bloom_order_cache and rpc_bloom_order_cached from sql/_archive, drop the three
-- columns, restore the CHECK, DROP TABLE l2_received_placement.
-- =============================================================================

ALTER TABLE public.bloom_order_cache_line DROP CONSTRAINT IF EXISTS bloom_order_cache_line_kind_ck;
ALTER TABLE public.bloom_order_cache_line ADD CONSTRAINT bloom_order_cache_line_kind_ck
  CHECK (line_kind = ANY (ARRAY['ordered'::text, 'hidden'::text, 'covered'::text, 'unordered'::text]));
ALTER TABLE public.bloom_order_cache_line ADD COLUMN IF NOT EXISTS placement_code text;
ALTER TABLE public.bloom_order_cache ADD COLUMN IF NOT EXISTS unordered_line_count integer;
COMMENT ON COLUMN public.bloom_order_cache_line.placement_code IS
'BLOOM-035 E1. On a line_kind unordered row: the machine code of why the product is on this desk but not ordered (NO_ORDER_NEEDED, NO_ACTIVE_LINK, DEPARTMENT_OUTSIDE_CYCLE, NON_STOCK_SOLD, EXPENSE_NOT_STOCK, ON_ANOTHER_DESK, NOT_IN_POOL). The sentence is in hidden_reason.';

CREATE TABLE IF NOT EXISTS public.l2_received_placement (
  client_id              text    NOT NULL DEFAULT 'socialbrand',
  store_code             text    NOT NULL,
  product_code           bigint  NOT NULL,
  latest_grv_supplier_nr bigint  NOT NULL,
  supplier_name          text,
  supplier_type          text,
  last_receipt_date      date    NOT NULL,
  desk_route_key         text,
  product_class          text,
  department_nr          integer,
  is_world2              boolean NOT NULL,
  has_active_link        boolean NOT NULL,
  sold_91d               boolean NOT NULL,
  state                  text    NOT NULL CHECK (state IN ('DESK', 'PARKED', 'PRODUCTION', 'NO_DESK')),
  reason_code            text,
  reason                 text,
  computed_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, store_code, product_code)
);
CREATE INDEX IF NOT EXISTS idx_l2_received_placement_desk ON public.l2_received_placement (store_code, desk_route_key);
ALTER TABLE public.l2_received_placement ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.l2_received_placement FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.l2_received_placement TO service_role;
COMMENT ON TABLE public.l2_received_placement IS
'GRADE: CALCULATED. BLOOM-035 E1 (R7). One row per (store, product) received in the desk_receipt_window_days: the desk it belongs on (the LATEST GRV supplier decides, never a link) and why it would not be an order row. state DESK = a desk exists for it (reason_code says why it is not ordered when it is not), PARKED = no sheet can hold it yet (a catch-all account whose consolidated desk is not built, an expense account), PRODUCTION = World 2, belongs on the production desk (item 7), NO_DESK = the latest supplier has no desk (a defect to read, expected 0). Written nightly by refresh_l2_received_placement. The one home for "where does this received product sit", read by the order cache and, by design, by the stocktake supplier lists (R33).';

-- The nightly fact ------------------------------------------------------------------------------------
-- Re-synced from the live definition 2026-10-14 (after bloom035_1b_dc_fresh_phase0, ENG-204).
CREATE OR REPLACE FUNCTION public.refresh_l2_received_placement(p_store_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_store text;
  v_wm    date;
  v_win   int;
  v_n     int;
  v_out   jsonb := '[]'::jsonb;
BEGIN
  SELECT fc.value_num::int INTO v_win FROM forge_config fc
   WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_win IS NULL THEN RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing'; END IF;

  FOR v_store IN SELECT s.store_code FROM stores s WHERE s.is_active AND (p_store_code IS NULL OR s.store_code = p_store_code) ORDER BY 1 LOOP
    SELECT max(movement_date) INTO v_wm FROM sigma_movements WHERE store_code = v_store;
    DELETE FROM l2_received_placement WHERE store_code = v_store;

    INSERT INTO l2_received_placement
      (store_code, product_code, latest_grv_supplier_nr, supplier_name, supplier_type, last_receipt_date, desk_route_key,
       product_class, department_nr, is_world2, has_active_link, sold_91d, state, reason_code, reason)
    WITH rec AS (
      SELECT m.product_code, m.supplier_nr, m.movement_date, m.movement_time, m.movement_id
        FROM sigma_movements m
       WHERE m.store_code = v_store AND m.movement_type IN ('R','W') AND m.qty > 0
         AND m.movement_date > v_wm - v_win AND m.movement_date <= v_wm
         AND m.supplier_nr IS NOT NULL AND m.supplier_nr <> 0
    ),
    latest AS (
      SELECT DISTINCT ON (product_code) product_code, supplier_nr, movement_date AS last_d
        FROM rec ORDER BY product_code, movement_date DESC, movement_time DESC NULLS LAST, movement_id DESC
    ),
    typ AS (
      SELECT DISTINCT ON (sm.supplier_nr) sm.supplier_nr, sm.supplier_type,
             COALESCE(NULLIF(btrim(sm.name), ''), NULLIF(btrim(sm.short_name), ''), 'Supplier ' || sm.supplier_nr) AS nm
        FROM sigma_supplier_master sm WHERE sm.store_code = v_store ORDER BY sm.supplier_nr, sm.id DESC
    ),
    dcroute AS (SELECT DISTINCT pv.route_key FROM l2_population_verdict pv WHERE pv.store_code = v_store AND pv.is_dc AND pv.route_key <> 'DC_FRESH' LIMIT 1),
    freshdept AS (SELECT unnest(dc.dc_fresh_dept_nrs)::int AS d FROM bloom_dc_config dc WHERE dc.store_code = v_store AND dc.status = 'RULED'),
    dcdept AS (SELECT unnest(dc.dc_cycle_dept_nrs)::int AS d, dc.fresh_cycle_applicable AS fresh
                 FROM bloom_dc_config dc WHERE dc.store_code = v_store AND dc.status = 'RULED'),
    sold AS (SELECT DISTINCT ss.product_code FROM sigma_sales ss
              WHERE ss.store_code = v_store AND ss.period_kind = 'T' AND ss.txn_kind = 1 AND ss.qty > 0 AND ss.sale_date > v_wm - 91),
    facts AS (
      SELECT l.product_code, l.supplier_nr, l.last_d, t.supplier_type, t.nm,
             sp.class AS pclass, sp.department_nr::int AS dept,
             (w.product_code IS NOT NULL) AS w2,
             EXISTS (SELECT 1 FROM bloom_catchall_account ca
                      WHERE upper(btrim(t.nm)) = ca.account_name OR upper(btrim(t.nm)) LIKE ca.account_name || ' %') AS catchall,
             CASE WHEN t.supplier_type = 'Z' THEN (CASE WHEN sp.department_nr::int IN (SELECT d FROM freshdept) THEN 'DC_FRESH' ELSE (SELECT route_key FROM dcroute) END)
                  ELSE (SELECT rc.route_key FROM bloom_route_config rc
                         WHERE rc.store_code = v_store AND rc.status = 'RULED' AND l.supplier_nr = ANY (rc.direct_supplier_nrs)
                         ORDER BY rc.route_key LIMIT 1) END AS desk,
             EXISTS (SELECT 1 FROM sigma_supplier_link sl
                       LEFT JOIN sigma_supplier_master sm ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
                      WHERE sl.store_code = v_store AND sl.product_code = l.product_code AND COALESCE(sl.status, '') <> 'S'
                        AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
                        AND ((t.supplier_type = 'Z' AND sm.supplier_type = 'Z') OR (t.supplier_type <> 'Z' AND sl.supplier_nr = l.supplier_nr))) AS has_link,
             (so.product_code IS NOT NULL) AS sold91
        FROM latest l
        JOIN typ t ON t.supplier_nr = l.supplier_nr
        LEFT JOIN l2_stock_position sp ON sp.store_code = v_store AND sp.product_code = l.product_code
        LEFT JOIN l2_world_assignment w ON w.store_code = v_store AND w.product_code = l.product_code AND w.world = 'WORLD_2'
        LEFT JOIN sold so ON so.product_code = l.product_code
    )
    SELECT v_store, f.product_code, f.supplier_nr, f.nm, f.supplier_type, f.last_d, f.desk, f.pclass, f.dept, f.w2, f.has_link, f.sold91,
           CASE WHEN f.w2 THEN 'PRODUCTION'
                WHEN f.pclass IS DISTINCT FROM 'NORMAL' AND f.desk IS NULL THEN 'PARKED'
                WHEN f.catchall THEN 'PARKED'
                WHEN f.desk IS NULL THEN 'NO_DESK'
                ELSE 'DESK' END,
           CASE WHEN f.w2 THEN 'WORLD_2'
                WHEN f.pclass IS DISTINCT FROM 'NORMAL' THEN CASE WHEN f.pclass = 'NON_STOCK' AND f.sold91 THEN 'NON_STOCK_SOLD' ELSE 'EXPENSE_NOT_STOCK' END
                WHEN f.catchall THEN 'CATCH_ALL_ACCOUNT'
                WHEN f.desk IS NULL THEN 'NO_DESK'
                WHEN f.desk IN (SELECT route_key FROM dcroute) AND f.dept IS NOT NULL AND f.dept NOT IN (SELECT d FROM dcdept) THEN 'DEPARTMENT_OUTSIDE_CYCLE'
                WHEN NOT f.has_link THEN 'NO_ACTIVE_LINK'
                WHEN pv.route_key = f.desk THEN 'NO_ORDER_NEEDED'
                WHEN pv.route_key IS NOT NULL THEN 'ON_ANOTHER_DESK'
                ELSE 'NOT_IN_POOL' END,
           CASE WHEN f.w2 THEN 'World 2 input: it belongs on the production desk (BLOOM-035 item 7), never on a Bloom desk.'
                WHEN f.pclass IS DISTINCT FROM 'NORMAL' THEN
                  CASE WHEN f.pclass = 'NON_STOCK' AND f.sold91 THEN 'Non-stock in Sigma but it sold in the last 91 days. If it is a buy-and-sell line, set Record Stock Qty to Yes in Sigma. Not ordered.'
                       ELSE 'Expense, not stock. Not ordered, kept out of purchases and budgets.' END
                WHEN f.catchall THEN format('Booked against the catch-all account %s. It has no supplier desk. It waits for the store consolidated desk (ENG-202, not built).', f.nm)
                WHEN f.desk IS NULL THEN format('The latest supplier, %s, has no desk at this store.', f.nm)
                WHEN f.desk IN (SELECT route_key FROM dcroute) AND f.dept IS NOT NULL AND f.dept NOT IN (SELECT d FROM dcdept) THEN
                  CASE WHEN (SELECT bool_or(fresh) FROM dcdept) THEN format('Department %s is outside the DC ambient cycle. It is in no DC desk department set (the DC fresh desk takes the departments the DC delivered, ENG-204).', f.dept)
                       ELSE format('Department %s is outside this store''s DC cycle departments.', f.dept) END
                WHEN NOT f.has_link THEN format('No active supplier link to %s in Sigma. Repair the link to order it.', f.nm)
                WHEN pv.route_key = f.desk THEN format('In the desk pool, nothing to order: %s%s.', pv.population_state, COALESCE(' (' || NULLIF(pv.state_reason, '') || ')', ''))
                WHEN pv.route_key IS NOT NULL THEN format('Its latest receipt is from this desk''s supplier, but the pool holds it on %s.', pv.route_key)
                ELSE 'In no desk pool: there is no population verdict row for it.' END
      FROM facts f
      LEFT JOIN l2_population_verdict pv ON pv.store_code = v_store AND pv.product_code = f.product_code;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    v_out := v_out || jsonb_build_array(jsonb_build_object('store_code', v_store, 'rows', v_n, 'watermark', v_wm,
              'by_state', (SELECT jsonb_object_agg(state, c) FROM (SELECT state, count(*) c FROM l2_received_placement WHERE store_code = v_store GROUP BY 1) q)));
  END LOOP;
  RETURN jsonb_build_object('stores', v_out);
END
$function$;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_received_placement(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_received_placement(text) TO service_role;
COMMENT ON FUNCTION public.refresh_l2_received_placement(text) IS
'GRADE: CALCULATED. BLOOM-035 E1 (R7). Stocks l2_received_placement for one store or every active store: each product received in the desk_receipt_window_days, the desk its LATEST GRV supplier puts it on, and the code and sentence for why it would not be an order row. Runs nightly after refresh_supplier_desks and before the order cache build.';
