-- =============================================================================
-- STOCKTAKE ENG-241 follow-up: COUNT BY SUPPLIER (Pieter, 14-10-2026: "we should be able to count by supplier,
-- ad hoc counts"). A SUPPLIER list is the count pool's own lines, in the pool's own order, cut to the products
-- whose LATEST GRV supplier is the chosen one (l2_received_placement, BLOOM-035 E1: the one home, R33). The
-- supplier never comes from a link and nothing is typed. The size is the ad hoc batch size.
--
-- WHAT CHANGES: stocktake_cycle gains supplier_nr and supplier_name and the list type SUPPLIER; the open-list
-- uniqueness gains the supplier; rpc_stocktake_generate gains p_supplier (a NEW signature, the old three-argument
-- one is DROPPED so a call by name cannot be ambiguous); rpc_stocktake_store_state returns `suppliers`;
-- cycle_get, overview, history and export carry the supplier name. Every body change is an ASSERTED REPLACE on the
-- live definition (each anchor must occur exactly once or the whole migration raises).
-- The same replacements were applied to sql/eng241_stocktake_count_app_core.sql, the source of record.
-- ROLLBACK: restore the six bodies from git (sql/eng241_stocktake_count_app_core.sql at ecca2eb), drop the two
-- columns, the SUPPLIER list type and the supplier part of the index, re-create the three-argument generate.
-- =============================================================================

ALTER TABLE public.stocktake_cycle DROP CONSTRAINT IF EXISTS stocktake_cycle_list_type_check;
ALTER TABLE public.stocktake_cycle ADD CONSTRAINT stocktake_cycle_list_type_check
  CHECK (list_type IN ('DAILY','CONFIRM','ADHOC','PLU','SUPPLIER'));
ALTER TABLE public.stocktake_cycle ADD COLUMN IF NOT EXISTS supplier_nr bigint;
ALTER TABLE public.stocktake_cycle ADD COLUMN IF NOT EXISTS supplier_name text;
DROP INDEX IF EXISTS public.stocktake_cycle_one_open;
CREATE UNIQUE INDEX stocktake_cycle_one_open
  ON public.stocktake_cycle (store_code, list_type, COALESCE(subdept_name, ''), COALESCE(supplier_nr, 0))
  WHERE status IN ('PENDING_CAPTURE','CAPTURING');

DO $mig$
DECLARE
  def text;
  n int;
BEGIN
  -- ---------------------------------------------------------------- rpc_stocktake_cycle_get(uuid)
  def := pg_get_functiondef('public.rpc_stocktake_cycle_get(uuid)'::regprocedure);
  n := (length(def) - length(replace(def, $a$      'subdept_name', c.subdept_name, 'status', c.status, 'generated_by', c.generated_by,
      'generated_at', c.generated_at, 'generated_on', c.generated_on, 'target_size', c.target_size,$a$, ''))) / length($a$      'subdept_name', c.subdept_name, 'status', c.status, 'generated_by', c.generated_by,
      'generated_at', c.generated_at, 'generated_on', c.generated_on, 'target_size', c.target_size,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'cycle_get anchor 1 found % times', n; END IF;
  def := replace(def, $a$      'subdept_name', c.subdept_name, 'status', c.status, 'generated_by', c.generated_by,
      'generated_at', c.generated_at, 'generated_on', c.generated_on, 'target_size', c.target_size,$a$, $b$      'subdept_name', c.subdept_name, 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
      'status', c.status, 'generated_by', c.generated_by,
      'generated_at', c.generated_at, 'generated_on', c.generated_on, 'target_size', c.target_size,$b$);

  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_stocktake_overview()
  def := pg_get_functiondef('public.rpc_stocktake_overview()'::regprocedure);
  n := (length(def) - length(replace(def, $a$                 'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name,
                 'status', c.status, 'generated_by', c.generated_by,$a$, ''))) / length($a$                 'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name,
                 'status', c.status, 'generated_by', c.generated_by,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'overview anchor 1 found % times', n; END IF;
  def := replace(def, $a$                 'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name,
                 'status', c.status, 'generated_by', c.generated_by,$a$, $b$                 'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name,
                 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
                 'status', c.status, 'generated_by', c.generated_by,$b$);

  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_stocktake_history(text, integer)
  def := pg_get_functiondef('public.rpc_stocktake_history(text, integer)'::regprocedure);
  n := (length(def) - length(replace(def, $a$      'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name, 'status', c.status,
      'generated_by', c.generated_by, 'generated_at', c.generated_at, 'finalised_by', c.finalised_by,$a$, ''))) / length($a$      'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name, 'status', c.status,
      'generated_by', c.generated_by, 'generated_at', c.generated_at, 'finalised_by', c.finalised_by,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'history anchor 1 found % times', n; END IF;
  def := replace(def, $a$      'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name, 'status', c.status,
      'generated_by', c.generated_by, 'generated_at', c.generated_at, 'finalised_by', c.finalised_by,$a$, $b$      'cycle_id', c.cycle_id, 'list_type', c.list_type, 'subdept_name', c.subdept_name, 'supplier_nr', c.supplier_nr, 'supplier_name', c.supplier_name,
      'status', c.status,
      'generated_by', c.generated_by, 'generated_at', c.generated_at, 'finalised_by', c.finalised_by,$b$);

  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_stocktake_export(uuid, text)
  def := pg_get_functiondef('public.rpc_stocktake_export(uuid, text)'::regprocedure);
  n := (length(def) - length(replace(def, $a$            || CASE WHEN c.subdept_name IS NOT NULL THEN '_' || regexp_replace(c.subdept_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END;$a$, ''))) / length($a$            || CASE WHEN c.subdept_name IS NOT NULL THEN '_' || regexp_replace(c.subdept_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'export anchor 1 found % times', n; END IF;
  def := replace(def, $a$            || CASE WHEN c.subdept_name IS NOT NULL THEN '_' || regexp_replace(c.subdept_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END;$a$, $b$            || CASE WHEN c.subdept_name IS NOT NULL THEN '_' || regexp_replace(c.subdept_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END
            || CASE WHEN c.supplier_name IS NOT NULL THEN '_' || regexp_replace(c.supplier_name, '[^A-Za-z0-9]+', '-', 'g') ELSE '' END;$b$);

  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_stocktake_store_state(text)
  def := pg_get_functiondef('public.rpc_stocktake_store_state(text)'::regprocedure);
  n := (length(def) - length(replace(def, $a$                GROUP BY c.subdept_name) q)
  ) INTO v_out;$a$, ''))) / length($a$                GROUP BY c.subdept_name) q)
  ) INTO v_out;$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'store_state anchor 1 found % times', n; END IF;
  def := replace(def, $a$                GROUP BY c.subdept_name) q)
  ) INTO v_out;$a$, $b$                GROUP BY c.subdept_name) q),
    -- Count by supplier: the pool's lines grouped by the LATEST GRV supplier of each product (l2_received_placement).
    'suppliers', (SELECT COALESCE(jsonb_agg(jsonb_build_object('supplier_nr', q.nr, 'supplier_name', q.nm, 'lines', q.n)
                                           ORDER BY q.n DESC, q.nm), '[]'::jsonb) FROM (
               SELECT rp.latest_grv_supplier_nr AS nr, MAX(rp.supplier_name) AS nm, COUNT(*) AS n
                 FROM cand c JOIN l2_received_placement rp ON rp.store_code = p_store AND rp.product_code = c.product_code
                WHERE c.route = 'TLX'
                GROUP BY rp.latest_grv_supplier_nr
                ORDER BY COUNT(*) DESC, MAX(rp.supplier_name) LIMIT 100) q)
  ) INTO v_out;$b$);

  EXECUTE def;

  -- ---------------------------------------------------------------- rpc_stocktake_generate: a NEW signature
  def := pg_get_functiondef('public.rpc_stocktake_generate(text, text, text)'::regprocedure);
  n := (length(def) - length(replace(def, $a$p_subdept text DEFAULT NULL::text)$a$, ''))) / length($a$p_subdept text DEFAULT NULL::text)$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate signature found % times', n; END IF;
  def := replace(def, $a$p_subdept text DEFAULT NULL::text)$a$, $b$p_subdept text DEFAULT NULL::text, p_supplier bigint DEFAULT NULL::bigint)$b$);
  n := (length(def) - length(replace(def, $a$  v_drawn timestamptz;
BEGIN$a$, ''))) / length($a$  v_drawn timestamptz;
BEGIN$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 1 found % times', n; END IF;
  def := replace(def, $a$  v_drawn timestamptz;
BEGIN$a$, $b$  v_drawn timestamptz;
  v_sup_name text;
  v_sup_rows integer;
BEGIN$b$);

  n := (length(def) - length(replace(def, $a$  IF p_list_type NOT IN ('DAILY','CONFIRM','ADHOC','PLU') THEN$a$, ''))) / length($a$  IF p_list_type NOT IN ('DAILY','CONFIRM','ADHOC','PLU') THEN$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 2 found % times', n; END IF;
  def := replace(def, $a$  IF p_list_type NOT IN ('DAILY','CONFIRM','ADHOC','PLU') THEN$a$, $b$  IF p_list_type NOT IN ('DAILY','CONFIRM','ADHOC','PLU','SUPPLIER') THEN$b$);

  n := (length(def) - length(replace(def, $a$  IF p_list_type <> 'ADHOC' THEN p_subdept := NULL; END IF;
$a$, ''))) / length($a$  IF p_list_type <> 'ADHOC' THEN p_subdept := NULL; END IF;
$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 3 found % times', n; END IF;
  def := replace(def, $a$  IF p_list_type <> 'ADHOC' THEN p_subdept := NULL; END IF;
$a$, $b$  IF p_list_type <> 'ADHOC' THEN p_subdept := NULL; END IF;
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
$b$);

  n := (length(def) - length(replace(def, $a$     AND COALESCE(c.subdept_name, '') = COALESCE(p_subdept, '')
     AND c.status IN ('PENDING_CAPTURE','CAPTURING')$a$, ''))) / length($a$     AND COALESCE(c.subdept_name, '') = COALESCE(p_subdept, '')
     AND c.status IN ('PENDING_CAPTURE','CAPTURING')$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 4 found % times', n; END IF;
  def := replace(def, $a$     AND COALESCE(c.subdept_name, '') = COALESCE(p_subdept, '')
     AND c.status IN ('PENDING_CAPTURE','CAPTURING')$a$, $b$     AND COALESCE(c.subdept_name, '') = COALESCE(p_subdept, '')
     AND COALESCE(c.supplier_nr, 0) = COALESCE(p_supplier, 0)
     AND c.status IN ('PENDING_CAPTURE','CAPTURING')$b$);

  n := (length(def) - length(replace(def, $a$           WHEN 'ADHOC'   THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
$a$, ''))) / length($a$           WHEN 'ADHOC'   THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 5 found % times', n; END IF;
  def := replace(def, $a$           WHEN 'ADHOC'   THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
$a$, $b$           WHEN 'ADHOC'   THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
           WHEN 'SUPPLIER' THEN stocktake_cfg('stocktake_adhoc_batch_size', p_store)::int
$b$);

  n := (length(def) - length(replace(def, $a$               WHEN 'ADHOC'   THEN 'RULED_2026-10-13_SUBDEPARTMENT_BATCH_SAME_ORDER'
$a$, ''))) / length($a$               WHEN 'ADHOC'   THEN 'RULED_2026-10-13_SUBDEPARTMENT_BATCH_SAME_ORDER'
$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 6 found % times', n; END IF;
  def := replace(def, $a$               WHEN 'ADHOC'   THEN 'RULED_2026-10-13_SUBDEPARTMENT_BATCH_SAME_ORDER'
$a$, $b$               WHEN 'ADHOC'   THEN 'RULED_2026-10-13_SUBDEPARTMENT_BATCH_SAME_ORDER'
               WHEN 'SUPPLIER' THEN 'ASKED_2026-10-14_SUPPLIER_BATCH_SAME_ORDER'
$b$);

  n := (length(def) - length(replace(def, $a$  INSERT INTO stocktake_cycle (store_code, list_type, subdept_name, generated_by, generated_on,
                               target_size, ordering_basis, non_count_day, non_count_reason, params)
  VALUES (p_store, p_list_type, p_subdept, v_actor, v_today, v_n, v_basis, v_nc, v_reason,$a$, ''))) / length($a$  INSERT INTO stocktake_cycle (store_code, list_type, subdept_name, generated_by, generated_on,
                               target_size, ordering_basis, non_count_day, non_count_reason, params)
  VALUES (p_store, p_list_type, p_subdept, v_actor, v_today, v_n, v_basis, v_nc, v_reason,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 7 found % times', n; END IF;
  def := replace(def, $a$  INSERT INTO stocktake_cycle (store_code, list_type, subdept_name, generated_by, generated_on,
                               target_size, ordering_basis, non_count_day, non_count_reason, params)
  VALUES (p_store, p_list_type, p_subdept, v_actor, v_today, v_n, v_basis, v_nc, v_reason,$a$, $b$  INSERT INTO stocktake_cycle (store_code, list_type, subdept_name, supplier_nr, supplier_name, generated_by, generated_on,
                               target_size, ordering_basis, non_count_day, non_count_reason, params)
  VALUES (p_store, p_list_type, p_subdept, p_supplier, v_sup_name, v_actor, v_today, v_n, v_basis, v_nc, v_reason,$b$);

  n := (length(def) - length(replace(def, $a$       AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept);
    INSERT INTO$a$, ''))) / length($a$       AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept);
    INSERT INTO$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 8 found % times', n; END IF;
  def := replace(def, $a$       AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept);
    INSERT INTO$a$, $b$       AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
       AND (p_list_type <> 'SUPPLIER' OR EXISTS (SELECT 1 FROM l2_received_placement rp
              WHERE rp.store_code = p_store AND rp.product_code = c.product_code AND rp.latest_grv_supplier_nr = p_supplier));
    INSERT INTO$b$);

  n := (length(def) - length(replace(def, $a$      AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
    ORDER BY CASE WHEN p_list_type = 'PLU'$a$, ''))) / length($a$      AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
    ORDER BY CASE WHEN p_list_type = 'PLU'$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 9 found % times', n; END IF;
  def := replace(def, $a$      AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
    ORDER BY CASE WHEN p_list_type = 'PLU'$a$, $b$      AND (p_list_type <> 'ADHOC' OR c.subdept_name = p_subdept)
      AND (p_list_type <> 'SUPPLIER' OR EXISTS (SELECT 1 FROM l2_received_placement rp
             WHERE rp.store_code = p_store AND rp.product_code = c.product_code AND rp.latest_grv_supplier_nr = p_supplier))
    ORDER BY CASE WHEN p_list_type = 'PLU'$b$);

  n := (length(def) - length(replace(def, $a$          jsonb_build_object('list_type', p_list_type, 'subdept', p_subdept, 'lines', v_lines,$a$, ''))) / length($a$          jsonb_build_object('list_type', p_list_type, 'subdept', p_subdept, 'lines', v_lines,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 10 found % times', n; END IF;
  def := replace(def, $a$          jsonb_build_object('list_type', p_list_type, 'subdept', p_subdept, 'lines', v_lines,$a$, $b$          jsonb_build_object('list_type', p_list_type, 'subdept', p_subdept, 'supplier_nr', p_supplier, 'supplier_name', v_sup_name, 'lines', v_lines,$b$);

  n := (length(def) - length(replace(def, $a$    'subdept_name', p_subdept, 'line_count', v_lines,$a$, ''))) / length($a$    'subdept_name', p_subdept, 'line_count', v_lines,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'generate anchor 11 found % times', n; END IF;
  def := replace(def, $a$    'subdept_name', p_subdept, 'line_count', v_lines,$a$, $b$    'subdept_name', p_subdept, 'supplier_nr', p_supplier, 'supplier_name', v_sup_name, 'line_count', v_lines,$b$);

  EXECUTE def;
  DROP FUNCTION public.rpc_stocktake_generate(text, text, text);
END
$mig$;

REVOKE EXECUTE ON FUNCTION public.rpc_stocktake_generate(text, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_stocktake_generate(text, text, text, bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_stocktake_generate(text, text, text, bigint) IS 'GRADE: RECOMMENDED. Generate one count list for a store (DAILY, CONFIRM, ADHOC, PLU, SUPPLIER) in the ruled order. One open cycle per store, list type, sub-department and supplier. A SUPPLIER list is the pool cut to the products whose latest GRV supplier is the one asked for (l2_received_placement).';
SELECT pg_notify('pgrst', 'reload schema');
