-- ENG-183 (A) -- the desk split by receipts, VERDICT half. ORDERING-CANON v1.20 SSA2 / -REGISTERS v1.3 SSH11.
-- Pieter 2026-09-10, four statements, one rule: 'received from is the obvious supplier. grv led. then supplier
-- column in sigma' / 'DC is the preferred supplier always where there are multiple suppliers' / 'tops sab is the
-- exception' / 'if it's sab and dc then it's an anomaly'. So a product on more than one desk rides the ONE desk
-- whose supplier it was RECEIVED from in desk_receipt_window_days (SEED 182). Received from more than one: DC.
-- Received from DC and a true DIRECT supplier (type F, outside the DC account; today SAB at TOPS): ANOMALY, kept on
-- DC and surfaced. Received from nobody: the Sigma supplier column is NOT in the mirror, so interim DC first,
-- desk_basis NO_RECEIPT (VERIFY), the extract owed. The DC-preferred ruling lived only in rpc_bloom_stock_state.
-- The 80579 case (sole desk, receipts only from a supplier with no desk here) is FLAGGED and moves nothing.
-- APPLY ORDER IS LOAD-BEARING: (A) -> refresh_l2_population_verdict x5 -> check -> (B). (B) first would read the
-- stale verdict and strip SAB-receipted lines off the SAB desk.
-- refresh_l2_population_verdict 14cf23ea7807709c7580a09c64d72051 -> b62580be7dcd3da2c8424ac0538e13e5 ; rpc_bloom_stock_state d0921900fb2598240f01ea1295c57a12 -> (warning text only)
-- Generated 2026-09-10 by CC from md5-verified live bodies; every patch asserts exactly one match.

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES ('desk_receipt_window_days', '*', 182, 'DEMO_CALIBRATION', (now() AT TIME ZONE 'Africa/Johannesburg')::date,
        'SEED, UNDERIVED. ORDERING-CANON SSA2 (2026-09-10), ENG-183: the window in which a desk must have RECEIPTED a product (R/W via DIWAREPR) to own it when the product is linked on more than one desk. 182 matches cadence_window_days and in_transit_lead_window_days (canon 7d); chosen, not derived. ENG-182 reads the same regime. Read by refresh_l2_population_verdict.');

ALTER TABLE public.l2_population_verdict ADD COLUMN desk_basis text, ADD COLUMN receipting_desks text[];
COMMENT ON COLUMN public.l2_population_verdict.desk_basis IS 'ENG-183 (ORDERING-CANON SSA2). Why the row sits on route_key (Pieter 2026-09-10: the supplier is who the line was received from, GRV-led). SOLE_DESK: one desk links it. RECEIPTS: exactly one linked desk received it in desk_receipt_window_days, that desk owns it. DC_PREFERRED: DC and another desk both received it, DC is the preferred supplier always where there are multiple suppliers. ANOMALY_DC_AND_DIRECT: DC and a true DIRECT supplier (type F, outside the DC account) both received it, an anomaly, kept on DC and surfaced. MULTI_RECEIPT: two direct desks received it, desk_sort, VERIFY. NO_RECEIPT: nobody received it, interim DC first else desk_sort, VERIFY, until the Sigma supplier column is extracted. SOLE_DESK_OFF_DESK_RECEIPT: one desk, but only a supplier with no desk here received it, flagged, nothing moved.';
COMMENT ON COLUMN public.l2_population_verdict.receipting_desks IS 'ENG-183. The linked desks whose own supplier set receipted the product in desk_receipt_window_days, alphabetical. NULL means none did.';

DO $eng183v$
DECLARE
  src text;
  k int;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'refresh_l2_population_verdict') <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict: overloads <> 1'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'refresh_l2_population_verdict';
  IF md5(src) <> '14cf23ea7807709c7580a09c64d72051' THEN RAISE EXCEPTION 'refresh_l2_population_verdict: live pin is %, expected 14cf23ea7807709c7580a09c64d72051', md5(src); END IF;
  k := (length(src) - length(replace(src, $o1$  v_out    jsonb;
$o1$, ''))) / length($o1$  v_out    jsonb;
$o1$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 1 matched % times', k; END IF;
  src := replace(src, $o1$  v_out    jsonb;
$o1$, $n1$  v_out    jsonb;
  v_rcpt_days int;
$n1$);
  k := (length(src) - length(replace(src, $o2$with no stock position', p_store_code;
  END IF;
$o2$, ''))) / length($o2$with no stock position', p_store_code;
  END IF;
$o2$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 2 matched % times', k; END IF;
  src := replace(src, $o2$with no stock position', p_store_code;
  END IF;
$o2$, $n2$with no stock position', p_store_code;
  END IF;

  -- ENG-183 (ORDERING-CANON SSA2): the window a desk must have receipted a product in to own it.
  SELECT fc.value_num::int INTO v_rcpt_days FROM forge_config fc WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_rcpt_days IS NULL THEN
    RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing -- ENG-183 cannot choose a desk without it';
  END IF;
$n2$);
  k := (length(src) - length(replace(src, $o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$, ''))) / length($o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 3 matched % times', k; END IF;
  src := replace(src, $o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$, $n3$  CREATE INDEX ON _pv_recv (pc, sup);

  -- ENG-183: who RECEIPTED each product here in the window, any supplier class (SSA5 7d).
  DROP TABLE IF EXISTS _pv_rcpt;
  CREATE TEMP TABLE _pv_rcpt AS
    SELECT m.product_code AS pc, m.supplier_nr AS sup, COALESCE(sm3.supplier_type = 'Z', false) AS is_z,
           COALESCE(sm3.supplier_type = 'F', false) AS is_f
      FROM sigma_movements m
      LEFT JOIN sigma_supplier_master sm3 ON sm3.store_code = m.store_code AND sm3.supplier_nr = m.supplier_nr
     WHERE m.store_code = p_store_code
       AND m.movement_type IN ('R','W') AND m.module = 'DIWAREPR' AND m.qty > 0
       AND m.movement_date > public.store_local_today(p_store_code) - v_rcpt_days
     GROUP BY 1, 2, 3, 4;
  CREATE INDEX ON _pv_rcpt (pc);
  ANALYZE _pv_rcpt;
$n3$);
  k := (length(src) - length(replace(src, $o4$uc_min numeric, uc_max numeric
  );$o4$, ''))) / length($o4$uc_min numeric, uc_max numeric
  );$o4$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 4 matched % times', k; END IF;
  src := replace(src, $o4$uc_min numeric, uc_max numeric
  );$o4$, $n4$uc_min numeric, uc_max numeric,
    desk_sort smallint, desk_rcpt boolean, desk_rcpt_f boolean
  );$n4$);
  k := (length(src) - length(replace(src, $o5$SELECT d.route_key, d.is_dc FROM rpc_bloom_desks$o5$, ''))) / length($o5$SELECT d.route_key, d.is_dc FROM rpc_bloom_desks$o5$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 5 matched % times', k; END IF;
  src := replace(src, $o5$SELECT d.route_key, d.is_dc FROM rpc_bloom_desks$o5$, $n5$SELECT d.route_key, d.is_dc, d.desk_sort FROM rpc_bloom_desks$n5$);
  k := (length(src) - length(replace(src, $o6$g.uc_min, g.uc_max
      FROM chosen ch$o6$, ''))) / length($o6$g.uc_min, g.uc_max
      FROM chosen ch$o6$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 6 matched % times', k; END IF;
  src := replace(src, $o6$g.uc_min, g.uc_max
      FROM chosen ch$o6$, $n6$g.uc_min, g.uc_max,
           v_desk.desk_sort,
           EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = ch.pc AND ((v_desk.is_dc AND rr.is_z) OR ((NOT v_desk.is_dc) AND rr.sup = ANY(v_direct)))),
           EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = ch.pc AND (NOT v_desk.is_dc) AND rr.is_f AND rr.sup = ANY(v_direct))
      FROM chosen ch$n6$);
  k := (length(src) - length(replace(src, $o7$  WITH ranked AS (
    SELECT p.*,$o7$, ''))) / length($o7$  WITH ranked AS (
    SELECT p.*,$o7$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 7 matched % times', k; END IF;
  src := replace(src, $o7$  WITH ranked AS (
    SELECT p.*,$o7$, $n7$  WITH rcpt AS (
    -- ENG-183 (ORDERING-CANON SSA2, Pieter 2026-09-10). The supplier is who the line was RECEIVED from (GRV-led).
    -- One receiving desk owns it. More than one: DC, because DC is the preferred supplier always where there are
    -- multiple suppliers, except DC together with a true DIRECT supplier (type F), which is an ANOMALY, surfaced.
    SELECT q.product_code, array_agg(q.route_key ORDER BY q.route_key) FILTER (WHERE q.desk_rcpt) AS rcpt_desks,
           COALESCE(bool_or(q.desk_rcpt AND q.is_dc), false) AS dc_rcpt,
           COALESCE(bool_or(q.desk_rcpt_f), false) AS f_rcpt
      FROM _pv_pool q GROUP BY q.product_code
  ),
  ranked AS (
    SELECT p.*, rc.rcpt_desks, rc.dc_rcpt, rc.f_rcpt,$n7$);
  k := (length(src) - length(replace(src, $o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$, ''))) / length($o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 8 matched % times', k; END IF;
  src := replace(src, $o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$, $n8$ORDER BY p.desk_rcpt DESC, p.is_dc DESC, p.desk_sort NULLS LAST, p.route_key) AS rk,$n8$);
  k := (length(src) - length(replace(src, $o9$      FROM _pv_pool p
  ),$o9$, ''))) / length($o9$      FROM _pv_pool p
  ),$o9$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 9 matched % times', k; END IF;
  src := replace(src, $o9$      FROM _pv_pool p
  ),$o9$, $n9$      FROM _pv_pool p
      LEFT JOIN rcpt rc ON rc.product_code = p.product_code
  ),$n9$);
  k := (length(src) - length(replace(src, $o10$link_valid_to, engine_version
  )$o10$, ''))) / length($o10$link_valid_to, engine_version
  )$o10$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 10 matched % times', k; END IF;
  src := replace(src, $o10$link_valid_to, engine_version
  )$o10$, $n10$link_valid_to, engine_version,
    desk_basis, receipting_desks
  )$n10$);
  k := (length(src) - length(replace(src, $o11$f.valid_to, v_engine
    FROM f;$o11$, ''))) / length($o11$f.valid_to, v_engine
    FROM f;$o11$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 11 matched % times', k; END IF;
  src := replace(src, $o11$f.valid_to, v_engine
    FROM f;$o11$, $n11$f.valid_to, v_engine,
         CASE WHEN NOT f.overlap AND NOT f.desk_rcpt AND EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = f.product_code) THEN 'SOLE_DESK_OFF_DESK_RECEIPT'
              WHEN NOT f.overlap THEN 'SOLE_DESK'
              WHEN f.rcpt_desks IS NULL THEN 'NO_RECEIPT'
              WHEN cardinality(f.rcpt_desks) = 1 THEN 'RECEIPTS'
              WHEN f.dc_rcpt AND f.f_rcpt THEN 'ANOMALY_DC_AND_DIRECT'
              WHEN f.dc_rcpt THEN 'DC_PREFERRED'
              ELSE 'MULTI_RECEIPT' END,
         f.rcpt_desks
    FROM f;$n11$);
  k := (length(src) - length(replace(src, $o12$  DROP TABLE IF EXISTS _pv_pool;

  SELECT jsonb_build_object($o12$, ''))) / length($o12$  DROP TABLE IF EXISTS _pv_pool;

  SELECT jsonb_build_object($o12$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 12 matched % times', k; END IF;
  src := replace(src, $o12$  DROP TABLE IF EXISTS _pv_pool;

  SELECT jsonb_build_object($o12$, $n12$  DROP TABLE IF EXISTS _pv_pool;
  DROP TABLE IF EXISTS _pv_rcpt;

  SELECT jsonb_build_object($n12$);
  k := (length(src) - length(replace(src, $o13$AND route_overlap)
  ) INTO v_out;$o13$, ''))) / length($o13$AND route_overlap)
  ) INTO v_out;$o13$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 13 matched % times', k; END IF;
  src := replace(src, $o13$AND route_overlap)
  ) INTO v_out;$o13$, $n13$AND route_overlap),
    'by_desk_basis', COALESCE((SELECT jsonb_object_agg(desk_basis, c) FROM (SELECT desk_basis, count(*) c FROM l2_population_verdict WHERE store_code = p_store_code GROUP BY 1) t), '{}'::jsonb)
  ) INTO v_out;$n13$);
  k := (length(src) - length(replace(src, $o14$population-verdict v2.1 (ENG-099 new-range fix)$o14$, ''))) / length($o14$population-verdict v2.1 (ENG-099 new-range fix)$o14$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 14 matched % times', k; END IF;
  src := replace(src, $o14$population-verdict v2.1 (ENG-099 new-range fix)$o14$, $n14$population-verdict v2.2 (ENG-183 desk split, received-from)$n14$);
  IF md5(src) <> 'b62580be7dcd3da2c8424ac0538e13e5' THEN RAISE EXCEPTION 'refresh_l2_population_verdict: patched text md5 is %, expected b62580be7dcd3da2c8424ac0538e13e5', md5(src); END IF;
  EXECUTE src;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'refresh_l2_population_verdict';
  IF md5(src) <> 'b62580be7dcd3da2c8424ac0538e13e5' THEN RAISE EXCEPTION 'refresh_l2_population_verdict: installed pin is %, expected b62580be7dcd3da2c8424ac0538e13e5', md5(src); END IF;
END $eng183v$;

DO $sst$
DECLARE
  src text;
  k int;
  o text := $os$shared with a DC desk are counted on DC, not here. That is the RULE, not a shortfall: DC is the preferred supplier always (Pieter ruling 2026-08-23), so a line DC supplies is ordered on DC and belongs on the DC desk.$os$;
  nw text := $ns$linked on more than one desk are each counted on ONE desk: the one whose supplier the line was received from, DC where it was received from more than one because DC is the preferred supplier always where there are multiple suppliers (Pieter ruling 2026-08-23 and 2026-09-10), and an anomaly where DC and a true direct supplier both delivered (ORDERING-CANON SSA2, ENG-183).$ns$;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_stock_state') <> 1 THEN RAISE EXCEPTION 'rpc_bloom_stock_state: overloads <> 1'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_stock_state';
  IF md5(src) <> 'd0921900fb2598240f01ea1295c57a12' THEN RAISE EXCEPTION 'rpc_bloom_stock_state: live pin is %, expected d0921900fb2598240f01ea1295c57a12', md5(src); END IF;
  k := (length(src) - length(replace(src, o, ''))) / length(o);
  IF k <> 1 THEN RAISE EXCEPTION 'rpc_bloom_stock_state warning matched % times', k; END IF;
  EXECUTE replace(src, o, nw);
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'rpc_bloom_stock_state';
  IF position(nw IN src) = 0 OR position(o IN src) > 0 THEN RAISE EXCEPTION 'stock_state warning text did not land'; END IF;
END $sst$;

NOTIFY pgrst, 'reload schema';
