-- =============================================================================
-- ENG-241 -- THE STOCKTAKE COUNT APP, DATABASE CORE (SB-CC-STOCKTAKE-001 v1.2)
--
-- Tables: stocktake_cycle, stocktake_cycle_line, stocktake_event. Apps write ONLY through the
-- SECURITY DEFINER rpc_stocktake_* functions below (R30 addendum 2). The tables carry RLS and no
-- client grant. Every function is granted to authenticated and service_role, never PUBLIC or anon.
--
-- The draw (stocktake_candidates) is the one home of the ruled order (Pieter 13-10-2026 16:24):
--   1 NEGATIVE  stock on hand below 0
--   2 INACTIVE  stock on hand above 0 and no positive till sale in stocktake_inactive_days (28)
--   3 SUSPECT   every other line with stock above 0, ranked by the rand value of the stock the
--               system claims (soh x unit cost), highest first
--   4 ZERO      a selling or received line the system shows at 0 (section 7: a count of 0
--               confirms it). Last, because it carries no rand value. ASSUMPTION, named in
--               BUG-LOG ENG-241: the brief orders three groups and is silent on zero-stock lines.
-- Within a group the largest absolute rand value comes first. Cost-error lines are out
-- (l2_classification.bucket = COST_ERROR, they have their own toolkit worklist).
--
-- Identity (one test, no length rule): a line goes to the TLX only when the classification says
-- REAL, l2_export_key says eligible, BOTH carry the same key, and the key is 8, 12, 13 or 14
-- digits with a valid GS1 check digit. Anything else is MANUAL (counted by PLU or product code):
-- PLU, UNRESOLVED, and the 24 REAL lines where the two engine facts disagree (R33, named).
--
-- Rollback: DROP the three tables and the stocktake_* / rpc_stocktake_* functions.
-- =============================================================================

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS public.stocktake_cycle (
  cycle_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id         text NOT NULL DEFAULT 'socialbrand',
  store_code        text NOT NULL,
  list_type         text NOT NULL CHECK (list_type IN ('DAILY','CONFIRM','ADHOC','PLU','SUPPLIER')),
  subdept_name      text,
  supplier_nr       bigint,
  supplier_name     text,
  status            text NOT NULL DEFAULT 'PENDING_CAPTURE'
                    CHECK (status IN ('PENDING_CAPTURE','CAPTURING','FINALISED','CANCELLED')),
  generated_by      text NOT NULL,
  generated_at      timestamptz NOT NULL DEFAULT now(),
  generated_on      date NOT NULL,
  target_size       integer,
  pool_size         integer,
  line_count        integer NOT NULL DEFAULT 0,
  ordering_basis    text NOT NULL,
  non_count_day     boolean NOT NULL DEFAULT false,
  non_count_reason  text,
  params            jsonb NOT NULL DEFAULT '{}'::jsonb,
  finalised_by      text,
  finalised_at      timestamptz,
  cancelled_by      text,
  cancelled_at      timestamptz,
  cancel_reason     text
);
CREATE UNIQUE INDEX IF NOT EXISTS stocktake_cycle_one_open
  ON public.stocktake_cycle (store_code, list_type, COALESCE(subdept_name, ''), COALESCE(supplier_nr, 0))
  WHERE status IN ('PENDING_CAPTURE','CAPTURING');
CREATE INDEX IF NOT EXISTS stocktake_cycle_store_date ON public.stocktake_cycle (store_code, generated_at DESC);

CREATE TABLE IF NOT EXISTS public.stocktake_cycle_line (
  line_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cycle_id          uuid NOT NULL REFERENCES public.stocktake_cycle(cycle_id),
  store_code        text NOT NULL,
  product_code      bigint NOT NULL,
  seq               integer NOT NULL,
  group_tag         text NOT NULL,
  identifier        text NOT NULL,
  identifier_kind   text NOT NULL CHECK (identifier_kind IN ('EAN','PLU','PRODUCT_CODE')),
  route             text NOT NULL CHECK (route IN ('TLX','MANUAL')),
  route_reason      text,
  ean_status        text,
  description       text,
  size_text         text,
  dept_name         text,
  subdept_name      text,
  system_stock      numeric NOT NULL,
  unit_cost         numeric,
  system_value      numeric,
  last_counted_date date,
  last_sale_date    date,
  story             text,
  front             numeric CHECK (front IS NULL OR front >= 0),
  back              numeric CHECK (back IS NULL OR back >= 0),
  count_qty         numeric,
  captured_by       text,
  captured_at       timestamptz,
  recount_count     integer NOT NULL DEFAULT 0,
  variance_qty      numeric,
  variance_value    numeric,
  variance_pct      numeric,
  flagged           boolean NOT NULL DEFAULT false,
  review_state      text NOT NULL DEFAULT 'OPEN' CHECK (review_state IN ('OPEN','CONFIRMED','RECOUNT')),
  reviewed_by       text,
  reviewed_at       timestamptz,
  UNIQUE (cycle_id, product_code)
);
CREATE INDEX IF NOT EXISTS stocktake_cycle_line_cycle ON public.stocktake_cycle_line (cycle_id, seq);
CREATE INDEX IF NOT EXISTS stocktake_cycle_line_store_prod ON public.stocktake_cycle_line (store_code, product_code);

CREATE TABLE IF NOT EXISTS public.stocktake_event (
  event_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cycle_id    uuid REFERENCES public.stocktake_cycle(cycle_id),
  store_code  text NOT NULL,
  event_type  text NOT NULL CHECK (event_type IN
              ('GENERATE','DOWNLOAD','UPLOAD','EDIT','RECOUNT','CONFIRM','FINALISE','EXPORT_TLX','EXPORT_PLU','CANCEL')),
  line_id     bigint,
  actor       text NOT NULL,
  at          timestamptz NOT NULL DEFAULT now(),
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS stocktake_event_cycle ON public.stocktake_event (cycle_id, at);
CREATE INDEX IF NOT EXISTS stocktake_event_store ON public.stocktake_event (store_code, at DESC);

ALTER TABLE public.stocktake_cycle      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocktake_cycle_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocktake_event      ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stocktake_cycle, public.stocktake_cycle_line, public.stocktake_event FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.stocktake_cycle, public.stocktake_cycle_line, public.stocktake_event TO service_role;

COMMENT ON TABLE public.stocktake_cycle IS 'GRADE: RAW. One generated count list (a cycle) per store: DAILY, CONFIRM (the confirmation count), ADHOC (a sub-department batch) or PLU (the PLU / scale list). Written only by rpc_stocktake_* (SB-CC-STOCKTAKE-001, ENG-241). generated_by is a provenance stamp, never a permission.';
COMMENT ON TABLE public.stocktake_cycle_line IS 'GRADE: RAW. The lines of a cycle, frozen at issue (system stock, unit cost, identifier, route) with the counts captured against them. The identifier and route are decided once at generate time so the sheet and the TLX can never disagree. Each line keeps its full count history through its cycle (date, system stock, count, variance).';
COMMENT ON TABLE public.stocktake_event IS 'GRADE: RAW. The count app''s audit log: every event with the user and the time (generate, download, upload, edit, recount, confirm, finalise, export, cancel). Append only.';

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION public.stocktake_cfg(p_key text, p_store text)
 RETURNS numeric LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  SELECT f.value_num
  FROM forge_config f
  JOIN stores s ON s.store_code = p_store
  WHERE f.config_key = p_key AND f.retired_on IS NULL AND f.store_format IN (s.store_type, '*')
  ORDER BY (f.store_format = '*')
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.stocktake_actor()
 RETURNS text LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  SELECT COALESCE(NULLIF(auth.jwt() ->> 'email', ''), auth.uid()::text)
$$;

-- The count days (DIWAINV, one per day) of a store inside a window. A day with several
-- postings is ONE count: the correction is the day's summed qty, the stock after is the last
-- posting (movement_time, then movement_id), the stock before is after minus the correction.
-- var_pct = |correction| as a share of the LARGER of the stock before and after (v1.2 section 4).
CREATE OR REPLACE FUNCTION public.stocktake_count_days(p_store text, p_days integer)
 RETURNS TABLE (product_code bigint, count_date date, correction numeric, soh_after numeric, soh_before numeric, var_pct numeric)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  WITH ev AS (
    SELECT m.product_code AS pc, m.movement_date AS d, SUM(m.qty) AS dq,
           (ARRAY_AGG(m.new_soh ORDER BY m.movement_time DESC, m.movement_id DESC))[1] AS after_soh
    FROM sigma_movements m
    WHERE m.store_code = p_store AND m.movement_type = 'I' AND m.module = 'DIWAINV'
      AND m.movement_date >= store_local_today(p_store) - p_days
    GROUP BY m.product_code, m.movement_date
  )
  SELECT ev.pc, ev.d, ev.dq, ev.after_soh, ev.after_soh - ev.dq,
         CASE WHEN GREATEST(ABS(ev.after_soh), ABS(ev.after_soh - ev.dq)) = 0 THEN 0::numeric
              ELSE ABS(ev.dq) / GREATEST(ABS(ev.after_soh), ABS(ev.after_soh - ev.dq)) * 100 END
  FROM ev
$$;

-- Lines counted inside the confirmation window and NOT yet normalised (section 4).
-- Entry view B (default): normalised = two or more count days in the window and the LATEST
-- correct. Strict view A (stocktake_normalised_strict = 1): the latest TWO both correct.
CREATE OR REPLACE FUNCTION public.stocktake_not_normalised(p_store text)
 RETURNS TABLE (product_code bigint, count_days integer, latest_date date, latest_var_pct numeric, prev_var_pct numeric)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
  WITH w AS (
    SELECT d.*,
           ROW_NUMBER() OVER (PARTITION BY d.product_code ORDER BY d.count_date DESC) AS rn,
           COUNT(*) OVER (PARTITION BY d.product_code) AS n
    FROM stocktake_count_days(p_store, stocktake_cfg('stocktake_confirm_window_days', p_store)::int) d
  ), g AS (
    SELECT w.product_code AS pc, MAX(w.n)::int AS n,
           MAX(w.count_date) FILTER (WHERE w.rn = 1) AS latest_date,
           MAX(w.var_pct)    FILTER (WHERE w.rn = 1) AS latest_var,
           MAX(w.var_pct)    FILTER (WHERE w.rn = 2) AS prev_var
    FROM w GROUP BY w.product_code
  )
  SELECT g.pc, g.n, g.latest_date, g.latest_var, g.prev_var
  FROM g
  WHERE NOT (
    g.n >= 2
    AND g.latest_var <= stocktake_cfg('stocktake_normalised_tolerance_pct', p_store)
    AND (COALESCE(stocktake_cfg('stocktake_normalised_strict', p_store), 0) = 0
         OR g.prev_var <= stocktake_cfg('stocktake_normalised_tolerance_pct', p_store))
  )
$$;

-- ---------------------------------------------------------------- the draw
CREATE OR REPLACE FUNCTION public.stocktake_candidates_compute(p_store text)
 RETURNS TABLE (
   store_code text, product_code bigint, grp text, grp_prio integer, rank_overall integer,
   rand_value numeric, soh numeric, unit_cost numeric, description text, size_text text,
   dept_name text, subdept_name text, ean_status text, identifier text, identifier_kind text,
   route text, route_reason text, last_counted_date date, last_sale_date date, in_range boolean)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
WITH today AS (SELECT store_local_today(p_store) AS d),
cls AS (
  SELECT c.product_code AS pc, c.ean_status, c.ean_key, c.bucket
  FROM l2_classification c
  WHERE c.store_code = p_store
    AND c.snapshot_date = (SELECT MAX(x.snapshot_date) FROM l2_classification x WHERE x.store_code = p_store)
),
sold AS (
  SELECT DISTINCT s.product_code AS pc
  FROM sigma_sales s, today
  WHERE s.store_code = p_store AND s.period_kind = 'T' AND s.txn_kind = 1 AND s.qty > 0
    AND s.sale_date >= today.d - stocktake_cfg('stocktake_inactive_days', p_store)::int
),
plu AS (
  SELECT DISTINCT ON (d.product_code) d.product_code AS pc, d.scan_code
  FROM v_scan_ref_decoded d
  WHERE d.store_code = p_store AND d.is_true_plu
  ORDER BY d.product_code, d.scan_code
),
ie AS (
  SELECT e.product_code AS pc, e.has_barcode, e.is_confirmed_plu, e.barcode_list
  FROM v_item_ean e WHERE e.store_code = p_store
),
base AS (
  SELECT v.store_code AS sc, v.product_code AS pc, v.soh AS soh_v, v.unit_cost AS uc, v.description AS descr,
         v.dept_name AS dept, v.subdept_name AS subdept, v.last_counted_date AS lcd, v.in_range AS inr,
         (v.soh * v.unit_cost) AS rv,
         COALESCE(NULLIF(btrim(a.pack_content), ''), NULLIF(btrim(a.unit), '')) AS sz,
         sp.last_sale_date AS lsd,
         -- Identity: the classification's own facts where it has a row (class NORMAL, soh <> 0), and for the
         -- zero-stock sellers it has no row for, the SAME decoder it reads (v_item_ean), by the same expression.
         COALESCE(c.ean_status,
                  CASE WHEN COALESCE(i.has_barcode, false) THEN 'REAL'
                       WHEN COALESCE(i.is_confirmed_plu, false) THEN 'PLU' ELSE 'UNRESOLVED' END) AS es,
         COALESCE(c.ean_key,
                  CASE WHEN COALESCE(i.has_barcode, false) THEN split_part(i.barcode_list, '|', 1) END) AS ek,
         k.export_key AS xk, COALESCE(k.export_eligible, false) AS xe,
         pl.scan_code AS plu_code,
         (so.pc IS NOT NULL) AS sold_recent
  FROM v_stocktake_pool v
  JOIN sigma_articles a ON a.store_code = v.store_code AND a.product_code = v.product_code
  JOIN l2_stock_position sp ON sp.store_code = v.store_code AND sp.product_code = v.product_code
  LEFT JOIN cls c ON c.pc = v.product_code
  LEFT JOIN ie i ON i.pc = v.product_code
  LEFT JOIN l2_export_key k ON k.store_code = v.store_code AND k.product_code = v.product_code
  LEFT JOIN plu pl ON pl.pc = v.product_code
  LEFT JOIN sold so ON so.pc = v.product_code
  WHERE v.store_code = p_store AND NOT v.counted_91 AND COALESCE(c.bucket, '') <> 'COST_ERROR'
),
t AS (
  SELECT b.*,
    (b.es = 'REAL' AND b.xe AND b.xk = b.ek
     AND CASE WHEN b.xk ~ '^([0-9]{8}|[0-9]{12,14})$'
              THEN right(b.xk, 1) = gs1_check_digit(left(b.xk, length(b.xk) - 1))::text
              ELSE false END) AS tlx_ok,
    CASE WHEN b.soh_v < 0 THEN 'NEGATIVE' WHEN b.soh_v = 0 THEN 'ZERO'
         WHEN NOT b.sold_recent THEN 'INACTIVE' ELSE 'SUSPECT' END AS g
  FROM base b
)
SELECT t.sc, t.pc, t.g,
       (CASE t.g WHEN 'NEGATIVE' THEN 1 WHEN 'INACTIVE' THEN 2 WHEN 'SUSPECT' THEN 3 ELSE 4 END)::int,
       (ROW_NUMBER() OVER (ORDER BY (CASE t.g WHEN 'NEGATIVE' THEN 1 WHEN 'INACTIVE' THEN 2 WHEN 'SUSPECT' THEN 3 ELSE 4 END),
                                    ABS(t.rv) DESC NULLS LAST, t.pc))::int,
       t.rv, t.soh_v, t.uc, t.descr, t.sz, t.dept, t.subdept, t.es,
       CASE WHEN t.tlx_ok THEN t.xk WHEN t.es = 'PLU' AND t.plu_code IS NOT NULL THEN t.plu_code ELSE t.pc::text END,
       CASE WHEN t.tlx_ok THEN 'EAN' WHEN t.es = 'PLU' AND t.plu_code IS NOT NULL THEN 'PLU' ELSE 'PRODUCT_CODE' END,
       CASE WHEN t.tlx_ok THEN 'TLX' ELSE 'MANUAL' END,
       CASE WHEN t.tlx_ok THEN NULL
            WHEN t.es = 'PLU' THEN 'PLU or scale line: counted by PLU or product code'
            WHEN t.es = 'UNRESOLVED' THEN 'no proven barcode: counted by product code'
            WHEN t.es = 'REAL' THEN 'identity check: the classification key and the export key do not agree, so the line is held out of the TLX'
            ELSE 'no classification row: counted by product code' END,
       t.lcd, t.lsd, t.inr
FROM t
$$;

-- The confirmation list: counted inside the confirmation window, not yet normalised,
-- highest rand value first. Both routes. Same exclusions as the draw.
CREATE OR REPLACE FUNCTION public.stocktake_confirm_candidates_compute(p_store text)
 RETURNS TABLE (
   store_code text, product_code bigint, grp text, grp_prio integer, rank_overall integer,
   rand_value numeric, soh numeric, unit_cost numeric, description text, size_text text,
   dept_name text, subdept_name text, ean_status text, identifier text, identifier_kind text,
   route text, route_reason text, last_counted_date date, last_sale_date date, in_range boolean,
   count_days integer, latest_var_pct numeric)
 LANGUAGE sql STABLE
 SET search_path TO 'public'
AS $$
WITH cls AS (
  SELECT c.product_code AS pc, c.ean_status, c.ean_key, c.bucket
  FROM l2_classification c
  WHERE c.store_code = p_store
    AND c.snapshot_date = (SELECT MAX(x.snapshot_date) FROM l2_classification x WHERE x.store_code = p_store)
),
plu AS (
  SELECT DISTINCT ON (d.product_code) d.product_code AS pc, d.scan_code
  FROM v_scan_ref_decoded d WHERE d.store_code = p_store AND d.is_true_plu
  ORDER BY d.product_code, d.scan_code
),
ie AS (
  SELECT e.product_code AS pc, e.has_barcode, e.is_confirmed_plu, e.barcode_list
  FROM v_item_ean e WHERE e.store_code = p_store
),
base AS (
  SELECT v.store_code AS sc, v.product_code AS pc, v.soh AS soh_v, v.unit_cost AS uc, v.description AS descr,
         v.dept_name AS dept, v.subdept_name AS subdept, v.last_counted_date AS lcd, v.in_range AS inr,
         (v.soh * v.unit_cost) AS rv,
         COALESCE(NULLIF(btrim(a.pack_content), ''), NULLIF(btrim(a.unit), '')) AS sz,
         sp.last_sale_date AS lsd,
         COALESCE(c.ean_status,
                  CASE WHEN COALESCE(i.has_barcode, false) THEN 'REAL'
                       WHEN COALESCE(i.is_confirmed_plu, false) THEN 'PLU' ELSE 'UNRESOLVED' END) AS es,
         COALESCE(c.ean_key,
                  CASE WHEN COALESCE(i.has_barcode, false) THEN split_part(i.barcode_list, '|', 1) END) AS ek,
         k.export_key AS xk, COALESCE(k.export_eligible, false) AS xe,
         pl.scan_code AS plu_code, nn.count_days AS cdays, nn.latest_var_pct AS lvar
  FROM stocktake_not_normalised(p_store) nn
  JOIN v_stocktake_pool v ON v.store_code = p_store AND v.product_code = nn.product_code
  JOIN sigma_articles a ON a.store_code = v.store_code AND a.product_code = v.product_code
  JOIN l2_stock_position sp ON sp.store_code = v.store_code AND sp.product_code = v.product_code
  LEFT JOIN cls c ON c.pc = v.product_code
  LEFT JOIN ie i ON i.pc = v.product_code
  LEFT JOIN l2_export_key k ON k.store_code = v.store_code AND k.product_code = v.product_code
  LEFT JOIN plu pl ON pl.pc = v.product_code
  WHERE COALESCE(c.bucket, '') <> 'COST_ERROR'
),
t AS (
  SELECT b.*,
    (b.es = 'REAL' AND b.xe AND b.xk = b.ek
     AND CASE WHEN b.xk ~ '^([0-9]{8}|[0-9]{12,14})$'
              THEN right(b.xk, 1) = gs1_check_digit(left(b.xk, length(b.xk) - 1))::text
              ELSE false END) AS tlx_ok
  FROM base b
)
SELECT t.sc, t.pc, 'CONFIRM'::text, 1,
       (ROW_NUMBER() OVER (ORDER BY ABS(t.rv) DESC NULLS LAST, t.pc))::int,
       t.rv, t.soh_v, t.uc, t.descr, t.sz, t.dept, t.subdept, t.es,
       CASE WHEN t.tlx_ok THEN t.xk WHEN t.es = 'PLU' AND t.plu_code IS NOT NULL THEN t.plu_code ELSE t.pc::text END,
       CASE WHEN t.tlx_ok THEN 'EAN' WHEN t.es = 'PLU' AND t.plu_code IS NOT NULL THEN 'PLU' ELSE 'PRODUCT_CODE' END,
       CASE WHEN t.tlx_ok THEN 'TLX' ELSE 'MANUAL' END,
       CASE WHEN t.tlx_ok THEN NULL
            WHEN t.es = 'PLU' THEN 'PLU or scale line: counted by PLU or product code'
            WHEN t.es = 'UNRESOLVED' THEN 'no proven barcode: counted by product code'
            WHEN t.es = 'REAL' THEN 'identity check: the classification key and the export key do not agree, so the line is held out of the TLX'
            ELSE 'no classification row: counted by product code' END,
       t.lcd, t.lsd, t.inr, t.cdays, t.lvar
FROM t
$$;

REVOKE ALL ON FUNCTION public.stocktake_cfg(text, text), public.stocktake_actor(),
  public.stocktake_count_days(text, integer), public.stocktake_not_normalised(text),
  public.stocktake_candidates_compute(text), public.stocktake_confirm_candidates_compute(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stocktake_cfg(text, text), public.stocktake_actor(),
  public.stocktake_count_days(text, integer), public.stocktake_not_normalised(text),
  public.stocktake_candidates_compute(text), public.stocktake_confirm_candidates_compute(text) TO service_role;

COMMENT ON FUNCTION public.stocktake_candidates_compute(text) IS 'GRADE: RECOMMENDED. The count app''s draw for one store COMPUTED: the uncounted count pool in the ruled order (NEGATIVE, INACTIVE, SUSPECT by absolute rand value, then ZERO), cost errors out, each line carrying its identifier and its route (TLX or MANUAL). Runs only inside refresh_l2_stocktake_draw (11 to 16 s at 10116). Internal, service_role only.';
COMMENT ON FUNCTION public.stocktake_confirm_candidates_compute(text) IS 'GRADE: RECOMMENDED. The confirmation count list for one store: lines counted inside stocktake_confirm_window_days and not yet normalised, highest rand value first. Internal, service_role only.';
COMMENT ON FUNCTION public.stocktake_count_days(text, integer) IS 'GRADE: CALCULATED. DIWAINV counts of a store inside a window, one per product per day (the closing-day unit), with the correction and its size as a share of the larger of the stock before and after. Internal, service_role only.';

-- ---------------------------------------------------------------- RPCs
-- Generate one list. One open cycle per store, list type (and sub-department).
CREATE OR REPLACE FUNCTION public.rpc_stocktake_generate(p_store text, p_list_type text, p_subdept text DEFAULT NULL, p_supplier bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  v_today date;
  v_fmt text;
  v_n integer;
  v_open uuid;
  v_cycle uuid;
  v_isodow integer;
  v_dc_dows integer[];
  v_nc boolean;
  v_reason text;
  v_pool integer;
  v_lines integer;
  v_wait integer;
  v_basis text;
  v_groups jsonb;
  v_tlx integer;
  v_man integer;
  v_excl bigint[];
  v_drawn timestamptz;
  v_sup_name text;
  v_sup_rows integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  IF p_list_type NOT IN ('DAILY','CONFIRM','ADHOC','PLU','SUPPLIER') THEN
    RAISE EXCEPTION 'unknown list type %', p_list_type;
  END IF;
  SELECT s.store_type INTO v_fmt FROM stores s WHERE s.store_code = p_store AND s.is_active;
  IF v_fmt IS NULL THEN RAISE EXCEPTION 'unknown or inactive store %', p_store; END IF;
  IF p_list_type = 'ADHOC' AND (p_subdept IS NULL OR btrim(p_subdept) = '') THEN
    RAISE EXCEPTION 'an ad hoc batch needs a sub-department';
  END IF;
  IF p_list_type <> 'ADHOC' THEN p_subdept := NULL; END IF;
  -- A supplier count (asked 14-10-2026): the pool's own lines, in the pool's own order, cut to the products whose
  -- LATEST GRV supplier is this one (l2_received_placement, the one home, R33). Never a link, never a typed list.
  IF p_list_type = 'SUPPLIER' THEN
    IF p_supplier IS NULL THEN RAISE EXCEPTION 'a supplier count needs a supplier'; END IF;
    SELECT MAX(rp.supplier_name), COUNT(*) INTO v_sup_name, v_sup_rows
      FROM l2_received_placement rp WHERE rp.store_code = p_store AND rp.latest_grv_supplier_nr = p_supplier;
    IF v_sup_rows = 0 THEN RAISE EXCEPTION 'unknown_supplier:%', p_supplier USING ERRCODE = 'P0001'; END IF;
  ELSE
    p_supplier := NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('stocktake_gen:' || p_store));
  v_today := store_local_today(p_store);
  -- The draw is stocked nightly (refresh_l2_stocktake_draw). A store with no stocked draw is a build fault, not an empty pool.
  SELECT ps.refreshed_at INTO v_drawn FROM l2_stocktake_pool_summary ps WHERE ps.store_code = p_store;
  IF v_drawn IS NULL THEN RAISE EXCEPTION 'draw_not_built:%', p_store USING ERRCODE = 'P0001'; END IF;

  SELECT c.cycle_id INTO v_open FROM stocktake_cycle c
   WHERE c.store_code = p_store AND c.list_type = p_list_type
     AND COALESCE(c.subdept_name, '') = COALESCE(p_subdept, '')
     AND COALESCE(c.supplier_nr, 0) = COALESCE(p_supplier, 0)
     AND c.status IN ('PENDING_CAPTURE','CAPTURING')
   LIMIT 1;
  IF v_open IS NOT NULL THEN
    RAISE EXCEPTION 'open_cycle_exists:%', v_open USING ERRCODE = 'P0001';
  END IF;

  -- The count law's rest days: no FORCED count on Saturday, Sunday or the store's DC ambient
  -- delivery day (ruled 13-08, config driven). A person may still generate: it is flagged, not refused.
  v_isodow := EXTRACT(ISODOW FROM v_today)::int;
  SELECT sc.delivery_dows::int[] INTO v_dc_dows
    FROM supplier_calendar sc WHERE sc.store_code = p_store AND sc.route_key LIKE 'DC%'
    ORDER BY sc.effective_from DESC LIMIT 1;
  v_nc := v_isodow IN (6, 7) OR (v_dc_dows IS NOT NULL AND v_isodow = ANY (v_dc_dows));
  v_reason := CASE WHEN v_isodow IN (6, 7) THEN 'weekend' WHEN v_nc THEN 'DC delivery day' END;

  v_wait := stocktake_cfg('stocktake_posting_wait_days', p_store)::int;
  v_n := CASE p_list_type
           WHEN 'DAILY'   THEN stocktake_cfg('daily_count_volume', p_store)::int
           WHEN 'CONFIRM' THEN stocktake_cfg('daily_count_volume', p_store)::int
           WHEN 'ADHOC'   THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
           WHEN 'SUPPLIER' THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
           ELSE NULL END;
  v_basis := CASE p_list_type
               WHEN 'DAILY'   THEN 'RULED_2026-10-13_NEGATIVE_INACTIVE_SUSPECT_ZERO'
               WHEN 'CONFIRM' THEN 'RULED_2026-10-13_CONFIRMATION_COUNT_BY_VALUE'
               WHEN 'ADHOC'   THEN 'RULED_2026-10-13_SUBDEPARTMENT_BATCH_SAME_ORDER'
               WHEN 'SUPPLIER' THEN 'ASKED_2026-10-14_SUPPLIER_BATCH_SAME_ORDER'
               ELSE 'PLU_LIST_BY_DEPARTMENT_THEN_VALUE' END;

  INSERT INTO stocktake_cycle (store_code, list_type, subdept_name, supplier_nr, supplier_name, generated_by, generated_on,
                               target_size, ordering_basis, non_count_day, non_count_reason, params)
  VALUES (p_store, p_list_type, p_subdept, p_supplier, v_sup_name, v_actor, v_today, v_n, v_basis, v_nc, v_reason,
          jsonb_build_object('posting_wait_days', v_wait, 'draw_refreshed_at', v_drawn,
                             'inactive_days', stocktake_cfg('stocktake_inactive_days', p_store)))
  RETURNING cycle_id INTO v_cycle;

  -- Lines already on an open cycle, or finalised and waiting for Sigma's I-movement, stay out.
  SELECT COALESCE(ARRAY_AGG(DISTINCT l.product_code), '{}'::bigint[]) INTO v_excl
  FROM stocktake_cycle_line l JOIN stocktake_cycle c ON c.cycle_id = l.cycle_id
  WHERE l.store_code = p_store AND c.cycle_id <> v_cycle
    AND (c.status IN ('PENDING_CAPTURE','CAPTURING')
         OR (c.status = 'FINALISED' AND c.finalised_at >= now() - make_interval(days => v_wait)));

  IF p_list_type = 'CONFIRM' THEN
    SELECT COUNT(*) INTO v_pool FROM stocktake_confirm_candidates(p_store) c
     WHERE NOT (c.product_code = ANY (v_excl));
    INSERT INTO stocktake_cycle_line (cycle_id, store_code, product_code, seq, group_tag, identifier, identifier_kind,
      route, route_reason, ean_status, description, size_text, dept_name, subdept_name, system_stock, unit_cost,
      system_value, last_counted_date, last_sale_date, story)
    SELECT v_cycle, c.store_code, c.product_code, ROW_NUMBER() OVER (ORDER BY c.rank_overall)::int, c.grp,
           c.identifier, c.identifier_kind, c.route, c.route_reason, c.ean_status, c.description, c.size_text,
           c.dept_name, c.subdept_name, c.soh, c.unit_cost, c.rand_value, c.last_counted_date, c.last_sale_date,
           format('Counted %s time%s in the last %s days and not yet confirmed (the latest correction was %s%% of the stock). A second count confirms the ledger tracks this line.',
                  c.count_days, CASE WHEN c.count_days = 1 THEN '' ELSE 's' END,
                  stocktake_cfg('stocktake_confirm_window_days', p_store)::int, ROUND(COALESCE(c.latest_var_pct, 0), 1))
    FROM stocktake_confirm_candidates(p_store) c
    WHERE NOT (c.product_code = ANY (v_excl))
    ORDER BY c.rank_overall
    LIMIT v_n;
  ELSE
    SELECT COUNT(*) INTO v_pool FROM stocktake_candidates(p_store) c
     WHERE NOT (c.product_code = ANY (v_excl))
       AND CASE p_list_type WHEN 'PLU' THEN c.route = 'MANUAL' ELSE c.route = 'TLX' END
       AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
       AND (p_list_type <> 'SUPPLIER' OR EXISTS (SELECT 1 FROM l2_received_placement rp
              WHERE rp.store_code = p_store AND rp.product_code = c.product_code AND rp.latest_grv_supplier_nr = p_supplier));
    INSERT INTO stocktake_cycle_line (cycle_id, store_code, product_code, seq, group_tag, identifier, identifier_kind,
      route, route_reason, ean_status, description, size_text, dept_name, subdept_name, system_stock, unit_cost,
      system_value, last_counted_date, last_sale_date, story)
    SELECT v_cycle, c.store_code, c.product_code,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN p_list_type = 'PLU' THEN c.dept_name END, c.rank_overall)::int,
           c.grp, c.identifier, c.identifier_kind, c.route, c.route_reason, c.ean_status, c.description, c.size_text,
           c.dept_name, c.subdept_name, c.soh, c.unit_cost, c.rand_value, c.last_counted_date, c.last_sale_date,
           CASE c.grp
             WHEN 'NEGATIVE' THEN format('The system shows %s on hand, below zero. Count what is on the shelf and enter 0 if there is none.', trim_scale(c.soh))
             WHEN 'INACTIVE' THEN format('The system shows %s on hand and nothing has sold in %s days.', trim_scale(c.soh), stocktake_cfg('stocktake_inactive_days', p_store)::int)
             WHEN 'SUSPECT'  THEN format('The system claims R%s of stock on this line, among the largest not counted in 91 days.', to_char(ROUND(COALESCE(c.rand_value, 0)), 'FM999G999G999'))
             ELSE 'The system shows none, but this line sold or was received in the last 91 days. Enter 0 if it is not on the shelf.' END
    FROM stocktake_candidates(p_store) c
    WHERE NOT (c.product_code = ANY (v_excl))
      AND CASE p_list_type WHEN 'PLU' THEN c.route = 'MANUAL' ELSE c.route = 'TLX' END
      AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
      AND (p_list_type <> 'SUPPLIER' OR EXISTS (SELECT 1 FROM l2_received_placement rp
             WHERE rp.store_code = p_store AND rp.product_code = c.product_code AND rp.latest_grv_supplier_nr = p_supplier))
    ORDER BY CASE WHEN p_list_type = 'PLU' THEN c.dept_name END, c.rank_overall
    LIMIT v_n;
  END IF;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE l.route = 'TLX'), COUNT(*) FILTER (WHERE l.route = 'MANUAL')
    INTO v_lines, v_tlx, v_man
    FROM stocktake_cycle_line l WHERE l.cycle_id = v_cycle;
  SELECT COALESCE(jsonb_object_agg(g, n), '{}'::jsonb) INTO v_groups
    FROM (SELECT l.group_tag AS g, COUNT(*) AS n FROM stocktake_cycle_line l WHERE l.cycle_id = v_cycle GROUP BY l.group_tag) q;

  IF v_lines = 0 THEN
    DELETE FROM stocktake_cycle WHERE cycle_id = v_cycle;
    RAISE EXCEPTION 'nothing_to_count:%', p_list_type USING ERRCODE = 'P0001';
  END IF;

  UPDATE stocktake_cycle SET line_count = v_lines, pool_size = v_pool WHERE cycle_id = v_cycle;

  INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
  VALUES (v_cycle, p_store, 'GENERATE', v_actor,
          jsonb_build_object('list_type', p_list_type, 'subdept', p_subdept, 'supplier_nr', p_supplier, 'supplier_name', v_sup_name, 'lines', v_lines,
                             'tlx_lines', v_tlx, 'manual_lines', v_man, 'groups', v_groups,
                             'pool_available', v_pool, 'target_size', v_n, 'ordering_basis', v_basis,
                             'non_count_day', v_nc, 'non_count_reason', v_reason, 'draw_refreshed_at', v_drawn));

  RETURN jsonb_build_object('cycle_id', v_cycle, 'store_code', p_store, 'list_type', p_list_type,
    'subdept_name', p_subdept, 'supplier_nr', p_supplier, 'supplier_name', v_sup_name, 'line_count', v_lines, 'tlx_lines', v_tlx, 'manual_lines', v_man,
    'groups', v_groups, 'pool_available', v_pool, 'target_size', v_n, 'ordering_basis', v_basis,
    'non_count_day', v_nc, 'non_count_reason', v_reason, 'draw_refreshed_at', v_drawn, 'generated_by', v_actor, 'status', 'PENDING_CAPTURE');
END;
$function$;

-- One cycle with all its lines, as one jsonb document (never a SETOF: the 1,000-row cap).
CREATE OR REPLACE FUNCTION public.rpc_stocktake_cycle_get(p_cycle uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c stocktake_cycle%ROWTYPE;
  v_lines jsonb;
  v_counts jsonb;
  v_n integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'line_id', l.line_id, 'seq', l.seq, 'group_tag', l.group_tag, 'identifier', l.identifier,
      'identifier_kind', l.identifier_kind, 'route', l.route, 'route_reason', l.route_reason,
      'product_code', l.product_code, 'description', l.description, 'size', l.size_text,
      'dept_name', l.dept_name, 'subdept_name', l.subdept_name,
      'system_stock', l.system_stock, 'system_now', sp.soh, 'unit_cost', l.unit_cost,
      'front', l.front, 'back', l.back, 'count_qty', l.count_qty,
      'variance_qty', l.variance_qty, 'variance_value', l.variance_value, 'variance_pct', l.variance_pct,
      'flagged', l.flagged, 'review_state', l.review_state, 'recount_count', l.recount_count,
      'captured_by', l.captured_by, 'captured_at', l.captured_at, 'story', l.story,
      'last_counted_date', l.last_counted_date)
      ORDER BY l.dept_name NULLS LAST, l.seq), '[]'::jsonb)
    INTO v_lines
    FROM stocktake_cycle_line l
    LEFT JOIN l2_stock_position sp ON sp.store_code = l.store_code AND sp.product_code = l.product_code
   WHERE l.cycle_id = p_cycle;

  SELECT COUNT(*), jsonb_build_object(
      'lines', COUNT(*),
      'captured', COUNT(*) FILTER (WHERE count_qty IS NOT NULL),
      'blank', COUNT(*) FILTER (WHERE count_qty IS NULL),
      'flagged', COUNT(*) FILTER (WHERE flagged),
      'flagged_open', COUNT(*) FILTER (WHERE flagged AND review_state <> 'CONFIRMED'),
      'confirmed', COUNT(*) FILTER (WHERE review_state = 'CONFIRMED'),
      'recounts', COUNT(*) FILTER (WHERE review_state = 'RECOUNT'),
      'tlx_lines', COUNT(*) FILTER (WHERE route = 'TLX'),
      'manual_lines', COUNT(*) FILTER (WHERE route = 'MANUAL'))
    INTO v_n, v_counts
    FROM stocktake_cycle_line WHERE cycle_id = p_cycle;

  RETURN jsonb_build_object(
    'cycle', jsonb_build_object('cycle_id', c.cycle_id, 'store_code', c.store_code, 'list_type', c.list_type,
      'subdept_name', c.subdept_name, 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
      'status', c.status, 'generated_by', c.generated_by,
      'generated_at', c.generated_at, 'generated_on', c.generated_on, 'target_size', c.target_size,
      'pool_size', c.pool_size, 'line_count', c.line_count, 'ordering_basis', c.ordering_basis,
      'non_count_day', c.non_count_day, 'non_count_reason', c.non_count_reason,
      'finalised_by', c.finalised_by, 'finalised_at', c.finalised_at,
      'cancelled_by', c.cancelled_by, 'cancelled_at', c.cancelled_at, 'cancel_reason', c.cancel_reason),
    'counts', v_counts, 'lines', v_lines, 'line_count', c.line_count, 'served', v_n);
END;
$function$;

-- Capture counts. Each element {line_id, front, back, clear}. A null front or back leaves that
-- box alone, clear:true empties both. Count = front + back, both blank = uncounted.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_capture(p_cycle uuid, p_lines jsonb, p_source text DEFAULT 'TYPED', p_unread integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  c stocktake_cycle%ROWTYPE;
  r record;
  l stocktake_cycle_line%ROWTYPE;
  v_front numeric;
  v_back numeric;
  v_cnt numeric;
  v_old numeric;
  v_var numeric;
  v_pct numeric;
  v_tol numeric;
  v_set integer := 0;
  v_same integer := 0;
  v_rej jsonb := '[]'::jsonb;
  v_blank integer;
  v_max numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  IF p_source NOT IN ('TYPED','UPLOAD') THEN RAISE EXCEPTION 'unknown source %', p_source; END IF;
  IF p_unread IS NULL OR p_unread < 0 THEN RAISE EXCEPTION 'unread must be zero or more'; END IF;
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  IF c.status IN ('FINALISED','CANCELLED') THEN
    RAISE EXCEPTION 'cycle_closed:%', c.status USING ERRCODE = 'P0001';
  END IF;
  v_tol := COALESCE(stocktake_cfg('stocktake_flag_tolerance_pct', c.store_code), 0);
  v_max := stocktake_cfg('stocktake_count_max_qty', c.store_code);
  IF v_max IS NULL THEN RAISE EXCEPTION 'count ceiling config missing'; END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(line_id bigint, front numeric, back numeric, clear boolean) LOOP
    SELECT * INTO l FROM stocktake_cycle_line WHERE line_id = r.line_id AND cycle_id = p_cycle FOR UPDATE;
    IF NOT FOUND THEN
      v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'line is not on this cycle');
      CONTINUE;
    END IF;
    IF COALESCE(r.front, 0) < 0 OR COALESCE(r.back, 0) < 0 THEN
      v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'a count cannot be negative');
      CONTINUE;
    END IF;
    IF COALESCE(r.front, 0) > v_max OR COALESCE(r.back, 0) > v_max THEN
      v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'a count above ' || trim_scale(v_max)::text || ' is not accepted, check the box and the scanner');
      CONTINUE;
    END IF;

    v_old := l.count_qty;
    IF COALESCE(r.clear, false) THEN
      v_front := NULL; v_back := NULL; v_cnt := NULL;
    ELSE
      v_front := COALESCE(r.front, l.front);
      v_back  := COALESCE(r.back,  l.back);
      v_cnt := CASE WHEN v_front IS NULL AND v_back IS NULL THEN NULL ELSE COALESCE(v_front, 0) + COALESCE(v_back, 0) END;
    END IF;

    IF v_front IS NOT DISTINCT FROM l.front AND v_back IS NOT DISTINCT FROM l.back THEN
      v_same := v_same + 1;
      CONTINUE;
    END IF;

    IF v_cnt IS NULL THEN
      UPDATE stocktake_cycle_line SET front = NULL, back = NULL, count_qty = NULL,
        variance_qty = NULL, variance_value = NULL, variance_pct = NULL, flagged = false,
        review_state = 'OPEN', captured_by = v_actor, captured_at = now()
      WHERE line_id = l.line_id;
    ELSE
      v_var := v_cnt - l.system_stock;
      v_pct := CASE WHEN l.system_stock <> 0 THEN ROUND(100 * v_var / ABS(l.system_stock), 2)
                    WHEN v_var = 0 THEN 0 ELSE NULL END;
      UPDATE stocktake_cycle_line SET front = v_front, back = v_back, count_qty = v_cnt,
        variance_qty = v_var,
        variance_value = CASE WHEN l.unit_cost IS NULL THEN NULL ELSE ROUND(v_var * l.unit_cost, 2) END,
        variance_pct = v_pct,
        flagged = (v_var <> 0 AND (v_pct IS NULL OR ABS(v_pct) > v_tol)),
        review_state = CASE WHEN review_state = 'RECOUNT' THEN 'OPEN'
                            WHEN review_state = 'CONFIRMED' THEN 'OPEN' ELSE review_state END,
        captured_by = v_actor, captured_at = now()
      WHERE line_id = l.line_id;
    END IF;
    v_set := v_set + 1;

    INSERT INTO stocktake_event (cycle_id, store_code, event_type, line_id, actor, detail)
    VALUES (p_cycle, c.store_code, 'EDIT', l.line_id, v_actor,
            jsonb_build_object('product_code', l.product_code, 'source', p_source,
              'from', v_old, 'to', v_cnt, 'front', v_front, 'back', v_back));
  END LOOP;

  IF p_source = 'UPLOAD' THEN
    INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
    VALUES (p_cycle, c.store_code, 'UPLOAD', v_actor,
            jsonb_build_object('lines_set', v_set, 'unchanged', v_same, 'rejected', jsonb_array_length(v_rej),
                            'unread', p_unread, 'sent', jsonb_array_length(p_lines)));
  END IF;

  IF c.status = 'PENDING_CAPTURE' AND EXISTS (SELECT 1 FROM stocktake_cycle_line WHERE cycle_id = p_cycle AND count_qty IS NOT NULL) THEN
    UPDATE stocktake_cycle SET status = 'CAPTURING' WHERE cycle_id = p_cycle;
  ELSIF c.status = 'CAPTURING' AND NOT EXISTS (SELECT 1 FROM stocktake_cycle_line WHERE cycle_id = p_cycle AND count_qty IS NOT NULL) THEN
    UPDATE stocktake_cycle SET status = 'PENDING_CAPTURE' WHERE cycle_id = p_cycle;
  END IF;

  SELECT COUNT(*) INTO v_blank FROM stocktake_cycle_line WHERE cycle_id = p_cycle AND count_qty IS NULL;
  RETURN jsonb_build_object('set', v_set, 'unchanged', v_same, 'rejected', v_rej, 'blank', v_blank,
                            'saved_at', now());
END;
$function$;

-- Confirm a flagged line or send it for a recount.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_review(p_cycle uuid, p_actions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  c stocktake_cycle%ROWTYPE;
  r record;
  l stocktake_cycle_line%ROWTYPE;
  v_done integer := 0;
  v_rej jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  IF c.status IN ('FINALISED','CANCELLED') THEN RAISE EXCEPTION 'cycle_closed:%', c.status USING ERRCODE = 'P0001'; END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(p_actions) AS x(line_id bigint, action text) LOOP
    SELECT * INTO l FROM stocktake_cycle_line WHERE line_id = r.line_id AND cycle_id = p_cycle FOR UPDATE;
    IF NOT FOUND THEN
      v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'line is not on this cycle');
      CONTINUE;
    END IF;
    IF r.action = 'CONFIRM' THEN
      IF l.count_qty IS NULL THEN
        v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'a blank line cannot be confirmed');
        CONTINUE;
      END IF;
      UPDATE stocktake_cycle_line SET review_state = 'CONFIRMED', reviewed_by = v_actor, reviewed_at = now()
       WHERE line_id = l.line_id;
      INSERT INTO stocktake_event (cycle_id, store_code, event_type, line_id, actor, detail)
      VALUES (p_cycle, c.store_code, 'CONFIRM', l.line_id, v_actor,
              jsonb_build_object('product_code', l.product_code, 'count', l.count_qty,
                                 'variance_qty', l.variance_qty, 'variance_value', l.variance_value));
      v_done := v_done + 1;
    ELSIF r.action = 'RECOUNT' THEN
      UPDATE stocktake_cycle_line SET front = NULL, back = NULL, count_qty = NULL, variance_qty = NULL,
        variance_value = NULL, variance_pct = NULL, flagged = false, review_state = 'RECOUNT',
        recount_count = recount_count + 1, reviewed_by = v_actor, reviewed_at = now()
       WHERE line_id = l.line_id;
      INSERT INTO stocktake_event (cycle_id, store_code, event_type, line_id, actor, detail)
      VALUES (p_cycle, c.store_code, 'RECOUNT', l.line_id, v_actor,
              jsonb_build_object('product_code', l.product_code, 'prior_count', l.count_qty,
                                 'prior_variance_qty', l.variance_qty));
      v_done := v_done + 1;
    ELSE
      v_rej := v_rej || jsonb_build_object('line_id', r.line_id, 'reason', 'unknown action ' || COALESCE(r.action, 'null'));
    END IF;
  END LOOP;

  IF c.status = 'PENDING_CAPTURE' AND EXISTS (SELECT 1 FROM stocktake_cycle_line WHERE cycle_id = p_cycle AND count_qty IS NOT NULL) THEN
    UPDATE stocktake_cycle SET status = 'CAPTURING' WHERE cycle_id = p_cycle;
  END IF;
  RETURN jsonb_build_object('done', v_done, 'rejected', v_rej);
END;
$function$;

-- Finalise. Refuses while any line is blank or any flagged line is unconfirmed, and names them.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_finalise(p_cycle uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  c stocktake_cycle%ROWTYPE;
  v_blank jsonb;
  v_open jsonb;
  v_tlx integer;
  v_man integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  IF c.status = 'FINALISED' THEN
    RETURN jsonb_build_object('ok', true, 'already', true, 'status', c.status);
  END IF;
  IF c.status = 'CANCELLED' THEN RAISE EXCEPTION 'cycle_closed:%', c.status USING ERRCODE = 'P0001'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('line_id', l.line_id, 'product_code', l.product_code,
           'identifier', l.identifier, 'description', l.description, 'seq', l.seq) ORDER BY l.seq), '[]'::jsonb)
    INTO v_blank FROM stocktake_cycle_line l WHERE l.cycle_id = p_cycle AND l.count_qty IS NULL;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('line_id', l.line_id, 'product_code', l.product_code,
           'identifier', l.identifier, 'description', l.description, 'seq', l.seq,
           'variance_qty', l.variance_qty, 'variance_value', l.variance_value) ORDER BY l.seq), '[]'::jsonb)
    INTO v_open FROM stocktake_cycle_line l
   WHERE l.cycle_id = p_cycle AND l.count_qty IS NOT NULL AND l.flagged AND l.review_state <> 'CONFIRMED';

  IF jsonb_array_length(v_blank) > 0 OR jsonb_array_length(v_open) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'blank_lines', v_blank, 'unconfirmed_lines', v_open);
  END IF;

  SELECT COUNT(*) FILTER (WHERE route = 'TLX'), COUNT(*) FILTER (WHERE route = 'MANUAL')
    INTO v_tlx, v_man FROM stocktake_cycle_line WHERE cycle_id = p_cycle;
  UPDATE stocktake_cycle SET status = 'FINALISED', finalised_by = v_actor, finalised_at = now() WHERE cycle_id = p_cycle;
  INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
  VALUES (p_cycle, c.store_code, 'FINALISE', v_actor,
          jsonb_build_object('lines', c.line_count, 'tlx_lines', v_tlx, 'manual_lines', v_man));
  RETURN jsonb_build_object('ok', true, 'status', 'FINALISED', 'tlx_lines', v_tlx, 'manual_lines', v_man);
END;
$function$;

-- The two exports of a finalised cycle. TLX: STORECODE++EAN+QTY+EAN+QTY (real EANs only,
-- every counted line, a counted 0 included). MANUAL: PLU, scale and held lines for capture in Sigma.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_export(p_cycle uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  c stocktake_cycle%ROWTYPE;
  v_content text;
  v_n integer;
  v_frac integer;
  v_rows jsonb;
  v_name text;
  v_expected integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  IF p_kind NOT IN ('TLX','MANUAL') THEN RAISE EXCEPTION 'unknown export kind %', p_kind; END IF;
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  IF c.status <> 'FINALISED' THEN RAISE EXCEPTION 'cycle_not_finalised:%', c.status USING ERRCODE = 'P0001'; END IF;
  v_name := c.store_code || '_stocktake_' || to_char(c.generated_on, 'YYYY-MM-DD') || '_' || c.list_type
            || CASE WHEN c.subdept_name IS NOT NULL THEN '_' || regexp_replace(c.subdept_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END
            || CASE WHEN c.supplier_name IS NOT NULL THEN '_' || regexp_replace(c.supplier_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END;

  IF p_kind = 'TLX' THEN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE l.count_qty <> trunc(l.count_qty)),
           string_agg(l.identifier || '+' || trim_scale(l.count_qty)::text, '+' ORDER BY l.seq)
      INTO v_n, v_frac, v_content
      FROM stocktake_cycle_line l WHERE l.cycle_id = p_cycle AND l.route = 'TLX' AND l.count_qty IS NOT NULL;
    SELECT COUNT(*) INTO v_expected FROM stocktake_cycle_line WHERE cycle_id = p_cycle AND route = 'TLX';
    IF v_n IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'tlx_count_mismatch: % counted TLX lines against % TLX lines on the cycle', v_n, v_expected;
    END IF;
    IF v_n = 0 THEN RAISE EXCEPTION 'no_tlx_lines'; END IF;
    v_content := c.store_code || '++' || v_content;
    INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
    VALUES (p_cycle, c.store_code, 'EXPORT_TLX', v_actor,
            jsonb_build_object('line_count', v_n, 'fractional_lines', v_frac, 'filename', v_name || '.tlx',
                               'md5', md5(v_content)));
    RETURN jsonb_build_object('kind', 'TLX', 'filename', v_name || '.tlx', 'content', v_content,
                              'line_count', v_n, 'fractional_lines', v_frac);
  END IF;

  SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object(
           'identifier', l.identifier, 'identifier_kind', l.identifier_kind, 'product_code', l.product_code,
           'description', l.description, 'size', l.size_text, 'dept_name', l.dept_name,
           'system_stock', l.system_stock, 'count_qty', l.count_qty, 'variance_qty', l.variance_qty,
           'variance_value', l.variance_value, 'route_reason', l.route_reason)
           ORDER BY l.dept_name NULLS LAST, l.seq), '[]'::jsonb)
    INTO v_n, v_rows
    FROM stocktake_cycle_line l WHERE l.cycle_id = p_cycle AND l.route = 'MANUAL';
  INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
  VALUES (p_cycle, c.store_code, 'EXPORT_PLU', v_actor,
          jsonb_build_object('line_count', v_n, 'filename', v_name || '_PLU.csv'));
  RETURN jsonb_build_object('kind', 'MANUAL', 'filename', v_name || '_PLU.csv', 'rows', v_rows, 'line_count', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_stocktake_cancel(p_cycle uuid, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor text;
  c stocktake_cycle%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  v_actor := stocktake_actor();
  SELECT * INTO c FROM stocktake_cycle WHERE cycle_id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  IF c.status IN ('FINALISED','CANCELLED') THEN RAISE EXCEPTION 'cycle_closed:%', c.status USING ERRCODE = 'P0001'; END IF;
  UPDATE stocktake_cycle SET status = 'CANCELLED', cancelled_by = v_actor, cancelled_at = now(), cancel_reason = p_reason
   WHERE cycle_id = p_cycle;
  INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
  VALUES (p_cycle, c.store_code, 'CANCEL', v_actor, jsonb_build_object('reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'status', 'CANCELLED');
END;
$function$;

-- Log an event the database cannot see happening (the sheet download).
CREATE OR REPLACE FUNCTION public.rpc_stocktake_log_event(p_cycle uuid, p_type text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_store text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  IF p_type <> 'DOWNLOAD' THEN RAISE EXCEPTION 'only DOWNLOAD may be logged from outside; % is logged by its own function', p_type; END IF;
  SELECT store_code INTO v_store FROM stocktake_cycle WHERE cycle_id = p_cycle;
  IF v_store IS NULL THEN RAISE EXCEPTION 'unknown cycle %', p_cycle; END IF;
  INSERT INTO stocktake_event (cycle_id, store_code, event_type, actor, detail)
  VALUES (p_cycle, v_store, 'DOWNLOAD', stocktake_actor(), COALESCE(p_detail, '{}'::jsonb));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- The dashboard: every active store, its pool, its open cycles, its rest-day state.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'store_code'), '[]'::jsonb) INTO v_out FROM (
    SELECT jsonb_build_object(
      'store_code', s.store_code, 'store_name', s.store_name, 'format', s.store_type,
      'daily_volume', stocktake_cfg('daily_count_volume', s.store_code),
      'adhoc_batch', stocktake_cfg('stocktake_adhoc_batch_size', s.store_code),
      'today', store_local_today(s.store_code),
      'pool', (SELECT jsonb_build_object(
                 'pool', ps.pool, 'in_range', ps.in_range, 'counted_91', ps.counted_91,
                 'uncounted', ps.uncounted, 'negative', ps.negative, 'zero_stock', ps.zero_stock,
                 'cost_errors_out', ps.cost_errors_out, 'refreshed_at', ps.refreshed_at)
               FROM l2_stocktake_pool_summary ps WHERE ps.store_code = s.store_code),
      'open_cycles', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                 'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name,
                 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
                 'status', c.status, 'generated_by', c.generated_by, 'generated_at', c.generated_at,
                 'line_count', c.line_count,
                 'captured', (SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.count_qty IS NOT NULL),
                 'flagged_open', (SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.flagged AND l.review_state <> 'CONFIRMED'))
                 ORDER BY c.generated_at DESC), '[]'::jsonb)
               FROM stocktake_cycle c WHERE c.store_code = s.store_code AND c.status IN ('PENDING_CAPTURE','CAPTURING')),
      'last_finalised', (SELECT jsonb_build_object('cycle_id', c.cycle_id, 'list_type', c.list_type, 'finalised_at', c.finalised_at,
                 'finalised_by', c.finalised_by, 'line_count', c.line_count)
               FROM stocktake_cycle c WHERE c.store_code = s.store_code AND c.status = 'FINALISED'
               ORDER BY c.finalised_at DESC LIMIT 1),
      'awaiting_posting', (SELECT COUNT(DISTINCT l.product_code) FROM stocktake_cycle_line l JOIN stocktake_cycle c ON c.cycle_id = l.cycle_id
               WHERE c.store_code = s.store_code AND c.status = 'FINALISED'
                 AND c.finalised_at >= now() - make_interval(days => stocktake_cfg('stocktake_posting_wait_days', s.store_code)::int)),
      'rest_day', (SELECT jsonb_build_object('is_rest_day', v.nc, 'reason', v.reason) FROM (
                 SELECT (EXTRACT(ISODOW FROM store_local_today(s.store_code))::int IN (6,7)
                         OR COALESCE(EXTRACT(ISODOW FROM store_local_today(s.store_code))::int = ANY (dc.dows), false)) AS nc,
                        CASE WHEN EXTRACT(ISODOW FROM store_local_today(s.store_code))::int IN (6,7) THEN 'weekend'
                             WHEN COALESCE(EXTRACT(ISODOW FROM store_local_today(s.store_code))::int = ANY (dc.dows), false) THEN 'DC delivery day' END AS reason
                 FROM (SELECT (SELECT sc.delivery_dows::int[] FROM supplier_calendar sc WHERE sc.store_code = s.store_code AND sc.route_key LIKE 'DC%' ORDER BY sc.effective_from DESC LIMIT 1) AS dows) dc) v)
    ) AS x
    FROM stores s WHERE s.is_active
  ) q;
  RETURN v_out;
END;
$function$;

-- The draw preview for one store: how many lines each list could take today.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_store_state(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_wait integer;
  v_out jsonb;
  v_excl bigint[];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM stores WHERE store_code = p_store AND is_active) THEN RAISE EXCEPTION 'unknown or inactive store %', p_store; END IF;
  v_wait := stocktake_cfg('stocktake_posting_wait_days', p_store)::int;
  SELECT COALESCE(ARRAY_AGG(DISTINCT l.product_code), '{}'::bigint[]) INTO v_excl
  FROM stocktake_cycle_line l JOIN stocktake_cycle c ON c.cycle_id = l.cycle_id
   WHERE l.store_code = p_store AND (c.status IN ('PENDING_CAPTURE','CAPTURING')
         OR (c.status = 'FINALISED' AND c.finalised_at >= now() - make_interval(days => v_wait)));
  -- The draw is read ONCE (materialised) and every figure below is cut from that one read.
  WITH cand AS MATERIALIZED (
    SELECT c.product_code, c.grp, c.route, c.subdept_name
    FROM stocktake_candidates(p_store) c WHERE NOT (c.product_code = ANY (v_excl))
  ), conf AS MATERIALIZED (
    SELECT c.product_code FROM stocktake_confirm_candidates(p_store) c WHERE NOT (c.product_code = ANY (v_excl))
  )
  SELECT jsonb_build_object(
    'store_code', p_store,
    'draw', (SELECT COALESCE(jsonb_object_agg(q.g, q.n), '{}'::jsonb) FROM (
               SELECT c.grp AS g, COUNT(*) AS n FROM cand c WHERE c.route = 'TLX' GROUP BY c.grp) q),
    'plu_lines', (SELECT COUNT(*) FROM cand c WHERE c.route = 'MANUAL'),
    'confirm_lines', (SELECT COUNT(*) FROM conf),
    'cost_errors_out', (SELECT ps.cost_errors_out FROM l2_stocktake_pool_summary ps WHERE ps.store_code = p_store),
    'draw_refreshed_at', (SELECT ps.refreshed_at FROM l2_stocktake_pool_summary ps WHERE ps.store_code = p_store),
    'subdepts', (SELECT COALESCE(jsonb_agg(jsonb_build_object('subdept_name', q.subdept_name, 'lines', q.n) ORDER BY q.n DESC), '[]'::jsonb) FROM (
               SELECT c.subdept_name, COUNT(*) AS n FROM cand c
                WHERE c.route = 'TLX' AND c.subdept_name IS NOT NULL
                GROUP BY c.subdept_name) q),
    -- Count by supplier: the pool's lines grouped by the LATEST GRV supplier of each product (l2_received_placement).
    'suppliers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('supplier_nr', q.nr, 'supplier_name', q.nm, 'lines', q.n)
                                           ORDER BY q.n DESC, q.nm), '[]'::jsonb) FROM (
               SELECT rp.latest_grv_supplier_nr AS nr, MAX(rp.supplier_name) AS nm, COUNT(*) AS n
                 FROM cand c JOIN l2_received_placement rp ON rp.store_code = p_store AND rp.product_code = c.product_code
                WHERE c.route = 'TLX'
                GROUP BY rp.latest_grv_supplier_nr
                ORDER BY COUNT(*) DESC, MAX(rp.supplier_name) LIMIT 100) q)
  ) INTO v_out;
  RETURN v_out;
END;
$function$;

-- History: the store's cycles and its adherence by day.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_history(p_store text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cycles jsonb;
  v_days jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name, 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
      'status', c.status,
      'generated_by', c.generated_by, 'generated_at', c.generated_at, 'finalised_by', c.finalised_by,
      'finalised_at', c.finalised_at, 'line_count', c.line_count,
      'captured', (SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.count_qty IS NOT NULL),
      'flagged', (SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.flagged),
      'variance_value', (SELECT ROUND(SUM(l.variance_value), 2) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id))
      ORDER BY c.generated_at DESC), '[]'::jsonb)
    INTO v_cycles
    FROM (SELECT * FROM stocktake_cycle WHERE store_code = p_store ORDER BY generated_at DESC LIMIT GREATEST(p_limit, 1)) c;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('day', d.day, 'cycles_generated', d.gen, 'lines_issued', d.issued,
      'cycles_finalised', d.fin, 'lines_counted', d.counted) ORDER BY d.day DESC), '[]'::jsonb)
    INTO v_days FROM (
      SELECT c.generated_on AS day, COUNT(*) AS gen, SUM(c.line_count) AS issued,
             COUNT(*) FILTER (WHERE c.status = 'FINALISED') AS fin,
             SUM((SELECT COUNT(*) FROM stocktake_cycle_line l WHERE l.cycle_id = c.cycle_id AND l.count_qty IS NOT NULL)) AS counted
      FROM stocktake_cycle c WHERE c.store_code = p_store AND c.status <> 'CANCELLED'
      GROUP BY c.generated_on ORDER BY c.generated_on DESC LIMIT 60) d;
  RETURN jsonb_build_object('store_code', p_store, 'cycles', v_cycles, 'by_day', v_days);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_stocktake_events(p_cycle uuid DEFAULT NULL, p_store text DEFAULT NULL, p_limit integer DEFAULT 300)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  IF p_cycle IS NULL AND p_store IS NULL THEN RAISE EXCEPTION 'name a cycle or a store'; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id', e.event_id, 'cycle_id', e.cycle_id, 'store_code', e.store_code,
      'event_type', e.event_type, 'line_id', e.line_id, 'actor', e.actor, 'at', e.at, 'detail', e.detail)
      ORDER BY e.at DESC, e.event_id DESC), '[]'::jsonb)
    INTO v_out
    FROM (SELECT * FROM stocktake_event
           WHERE (p_cycle IS NULL OR cycle_id = p_cycle) AND (p_store IS NULL OR store_code = p_store)
           ORDER BY at DESC, event_id DESC LIMIT LEAST(GREATEST(p_limit, 1), 1000)) e;
  RETURN v_out;
END;
$function$;

-- One line's count history: the app's own counts (cycle, date, system, count, variance) beside
-- the ledger's DIWAINV count days.
CREATE OR REPLACE FUNCTION public.rpc_stocktake_line_history(p_store text, p_product bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000'; END IF;
  RETURN jsonb_build_object(
    'app', (SELECT COALESCE(jsonb_agg(jsonb_build_object('cycle_id', c.cycle_id, 'list_type', c.list_type, 'date', c.generated_on,
              'status', c.status, 'system_stock', l.system_stock, 'count_qty', l.count_qty,
              'variance_qty', l.variance_qty, 'variance_value', l.variance_value, 'captured_by', l.captured_by)
              ORDER BY c.generated_at DESC), '[]'::jsonb)
            FROM stocktake_cycle_line l JOIN stocktake_cycle c ON c.cycle_id = l.cycle_id
           WHERE l.store_code = p_store AND l.product_code = p_product),
    'ledger', (SELECT COALESCE(jsonb_agg(jsonb_build_object('date', d.count_date, 'correction', d.correction,
              'soh_before', d.soh_before, 'soh_after', d.soh_after, 'correction_pct', ROUND(d.var_pct, 2))
              ORDER BY d.count_date DESC), '[]'::jsonb)
            FROM stocktake_count_days(p_store, 400) d WHERE d.product_code = p_product));
END;
$function$;

-- Grants (R30 addendum extension): both the PUBLIC and the direct anon grant, then authenticated.
REVOKE EXECUTE ON FUNCTION
  public.rpc_stocktake_generate(text, text, text, bigint), public.rpc_stocktake_cycle_get(uuid),
  public.rpc_stocktake_capture(uuid, jsonb, text, integer), public.rpc_stocktake_review(uuid, jsonb),
  public.rpc_stocktake_finalise(uuid), public.rpc_stocktake_export(uuid, text),
  public.rpc_stocktake_cancel(uuid, text), public.rpc_stocktake_log_event(uuid, text, jsonb),
  public.rpc_stocktake_overview(), public.rpc_stocktake_store_state(text),
  public.rpc_stocktake_history(text, integer), public.rpc_stocktake_events(uuid, text, integer),
  public.rpc_stocktake_line_history(text, bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.rpc_stocktake_generate(text, text, text, bigint), public.rpc_stocktake_cycle_get(uuid),
  public.rpc_stocktake_capture(uuid, jsonb, text, integer), public.rpc_stocktake_review(uuid, jsonb),
  public.rpc_stocktake_finalise(uuid), public.rpc_stocktake_export(uuid, text),
  public.rpc_stocktake_cancel(uuid, text), public.rpc_stocktake_log_event(uuid, text, jsonb),
  public.rpc_stocktake_overview(), public.rpc_stocktake_store_state(text),
  public.rpc_stocktake_history(text, integer), public.rpc_stocktake_events(uuid, text, integer),
  public.rpc_stocktake_line_history(text, bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_stocktake_generate(text, text, text, bigint) IS 'GRADE: RECOMMENDED. Generate one count list for a store (DAILY, CONFIRM, ADHOC, PLU, SUPPLIER) in the ruled order. One open cycle per store, list type, sub-department and supplier. A SUPPLIER list is the pool cut to the products whose latest GRV supplier is the one asked for (l2_received_placement). SB-CC-STOCKTAKE-001, ENG-241.';
COMMENT ON FUNCTION public.rpc_stocktake_cycle_get(uuid) IS 'GRADE: RAW. One cycle and all its lines as a single jsonb document (never a SETOF, the 1,000-row cap).';
COMMENT ON FUNCTION public.rpc_stocktake_capture(uuid, jsonb, text, integer) IS 'GRADE: RAW. Capture counts against a cycle (typed or upload). Count = front + back, both blank = uncounted. Writes the variance and an EDIT event per changed line. An UPLOAD event records lines_set, unchanged, rejected (the database''s refusals), unread (rows the route could not read and never sent, p_unread) and sent.';
COMMENT ON FUNCTION public.rpc_stocktake_review(uuid, jsonb) IS 'GRADE: RAW. Confirm a counted line or send it for a recount.';
COMMENT ON FUNCTION public.rpc_stocktake_finalise(uuid) IS 'GRADE: RAW. Finalise a cycle. Refuses while any line is blank or any flagged line is unconfirmed and names them.';
COMMENT ON FUNCTION public.rpc_stocktake_export(uuid, text) IS 'GRADE: RAW. The TLX (real EANs only, every counted line) or the manual PLU / scale rows of a finalised cycle. The TLX line count is checked against the cycle.';
COMMENT ON FUNCTION public.rpc_stocktake_overview() IS 'GRADE: CALCULATED. The count dashboard: per store the pool, open cycles, awaiting posting and the rest-day state.';

NOTIFY pgrst, 'reload schema';
