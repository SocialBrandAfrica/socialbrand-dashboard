-- ENG-183 (A) -- the desk split by receipts, VERDICT half. ORDERING-CANON v1.22 SSA2 / -REGISTERS v1.5 SSH11.
-- Pieter 2026-09-10: 'received from is the obvious supplier. grv led. then supplier column in sigma' / 'DC is the
-- preferred supplier always where there are multiple suppliers' / 'tops sab is the exception' / 'if it's sab and dc
-- then it's an anomaly' / 'we also cannot make a platform-wide call on one anomaly line' / the supplier column
-- decides 'only if never received in our history horizon'. So a product on more than one desk rides ONE desk:
-- received in desk_receipt_window_days (SEED 182, the regime) from one desk, that desk; from more than one, DC (the
-- DC-and-true-direct case is labelled ANOMALY and stays on DC); not received in the regime, the desk whose supplier
-- delivered it last in our history; never received in our history, Sigma's supplier column (Supp. Cd.), interim from the
-- DIWAAIS copy in product_catalog pulled 2026-05-24 until ENG-184 extracts it nightly; nothing, DC first, VERIFY.
-- A line whose only receiving supplier has no desk here is FLAGGED and moves nothing; the consolidated desk is ENG-202.
-- APPLY ORDER IS LOAD-BEARING: ENG-185 (the 80579 SAB desk) -> (A) -> refresh_l2_population_verdict x5 -> check -> (B).
-- (B) first would read the stale verdict and strip SAB-receipted lines off the SAB desk.
-- refresh_l2_population_verdict 14cf23ea7807709c7580a09c64d72051 -> 54b02e1d35a922af3b56e33019089dc7 ; rpc_bloom_stock_state d0921900fb2598240f01ea1295c57a12 -> (warning text only)
-- Generated 2026-09-10 by CC from md5-verified live bodies; every patch asserts exactly one match.

INSERT INTO public.forge_config (config_key, store_format, value_num, scope, effective_from, notes)
VALUES ('desk_receipt_window_days', '*', 182, 'DEMO_CALIBRATION', (now() AT TIME ZONE 'Africa/Johannesburg')::date,
        'SEED, UNDERIVED. ORDERING-CANON SSA2 (2026-09-10), ENG-183: the window (the current regime) in which a desk must have RECEIPTED a product (R/W via DIWAREPR) to own it when the product is linked on more than one desk. Beyond it the last delivery in our whole receipt history decides, and only a line never received in that history falls to the Sigma supplier column (Pieter 2026-09-10). 182 matches cadence_window_days and in_transit_lead_window_days (canon 7d); chosen, not derived. ENG-182 reads the same regime. Read by refresh_l2_population_verdict.');

ALTER TABLE public.l2_population_verdict ADD COLUMN desk_basis text, ADD COLUMN receipting_desks text[];
COMMENT ON COLUMN public.l2_population_verdict.desk_basis IS 'ENG-183 (ORDERING-CANON SSA2). Why the row sits on route_key (Pieter 2026-09-10: the supplier is who the line was received from, GRV-led, then the supplier column in Sigma). SOLE_DESK: one desk links it. RECEIPTS: exactly one linked desk received it in desk_receipt_window_days (the current regime). DC_PREFERRED: DC and another desk both received it in the regime, DC is the preferred supplier always where there are multiple suppliers. ANOMALY_DC_AND_DIRECT: DC and a true DIRECT supplier (type F, outside the DC account) both received it in the regime; it stays on DC, labelled, and its DC link goes on the Sigma correction list. MULTI_RECEIPT: two direct desks received it in the regime, surfaced. HISTORY_RECEIPT: no desk received it in the regime, so the desk whose supplier delivered it last in our whole receipt history owns it (DC on a same-day tie). SUPP_CD: never received in our history, so Sigma supplier column (Supp. Cd.) decided it; interim source product_catalog, the DIWAAIS copy pulled 2026-05-24, until ENG-184. NO_RECEIPT: never received and no supplier column match, DC first else desk_sort, VERIFY. SOLE_DESK_OFF_DESK_RECEIPT: one desk, but only a supplier with no desk here received it in the regime, flagged, nothing moves until the store consolidated desk (ENG-202).';
COMMENT ON COLUMN public.l2_population_verdict.receipting_desks IS 'ENG-183. The linked desks whose own supplier set receipted the product in desk_receipt_window_days (the current regime), alphabetical. NULL means none did in the regime.';

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
  v_rcpt_from date;
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

  -- ENG-183 (ORDERING-CANON SSA2): the window (the current regime) a desk must have receipted a product in to own it.
  SELECT fc.value_num::int INTO v_rcpt_days FROM forge_config fc WHERE fc.config_key = 'desk_receipt_window_days' AND fc.store_format = '*' AND fc.retired_on IS NULL;
  IF v_rcpt_days IS NULL THEN
    RAISE EXCEPTION 'forge_config desk_receipt_window_days is missing -- ENG-183 cannot choose a desk without it';
  END IF;
  v_rcpt_from := public.store_local_today(p_store_code) - v_rcpt_days;
$n2$);
  k := (length(src) - length(replace(src, $o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$, ''))) / length($o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 3 matched % times', k; END IF;
  src := replace(src, $o3$  CREATE INDEX ON _pv_recv (pc, sup);
$o3$, $n3$  CREATE INDEX ON _pv_recv (pc, sup);

  -- ENG-183: who RECEIPTED each product here over our whole history (SSA5 7d), any supplier class. in_win marks
  -- the current regime, last_dt the last delivery. The supplier column decides only a line never received here.
  DROP TABLE IF EXISTS _pv_rcpt;
  CREATE TEMP TABLE _pv_rcpt AS
    SELECT m.product_code AS pc, m.supplier_nr AS sup, COALESCE(sm3.supplier_type = 'Z', false) AS is_z,
           COALESCE(sm3.supplier_type = 'F', false) AS is_f, bool_or(m.movement_date > v_rcpt_from) AS in_win,
           max(m.movement_date) AS last_dt
      FROM sigma_movements m
      LEFT JOIN sigma_supplier_master sm3 ON sm3.store_code = m.store_code AND sm3.supplier_nr = m.supplier_nr
     WHERE m.store_code = p_store_code
       AND m.movement_type IN ('R','W') AND m.module = 'DIWAREPR' AND m.qty > 0
     GROUP BY 1, 2, 3, 4;
  CREATE INDEX ON _pv_rcpt (pc);
  ANALYZE _pv_rcpt;

  -- ENG-183 / ENG-184: Sigma's own supplier column (Supp. Cd.), one supplier per product. INTERIM source: the
  -- DIWAAIS export copy in product_catalog (pulled 2026-05-24) until ENG-184 extracts the field nightly.
  DROP TABLE IF EXISTS _pv_supp;
  CREATE TEMP TABLE _pv_supp AS
    SELECT DISTINCT ON (x.pc) x.pc, x.sup, COALESCE(sm4.supplier_type = 'Z', false) AS is_z
      FROM (SELECT CASE WHEN pcat.sigma_product_code ~ '^[0-9]+$' THEN pcat.sigma_product_code::bigint END AS pc,
                   CASE WHEN pcat.supplier_code ~ '^[0-9]+$' THEN pcat.supplier_code::bigint END AS sup,
                   pcat.loaded_at
              FROM product_catalog pcat WHERE pcat.store_code = p_store_code) x
      LEFT JOIN sigma_supplier_master sm4 ON sm4.store_code = p_store_code AND sm4.supplier_nr = x.sup
     WHERE x.pc IS NOT NULL AND x.sup IS NOT NULL
     ORDER BY x.pc, x.loaded_at DESC;
  CREATE INDEX ON _pv_supp (pc);
  ANALYZE _pv_supp;
$n3$);
  k := (length(src) - length(replace(src, $o4$uc_min numeric, uc_max numeric
  );$o4$, ''))) / length($o4$uc_min numeric, uc_max numeric
  );$o4$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 4 matched % times', k; END IF;
  src := replace(src, $o4$uc_min numeric, uc_max numeric
  );$o4$, $n4$uc_min numeric, uc_max numeric,
    desk_sort smallint, desk_rcpt boolean, desk_rcpt_f boolean, desk_last date, supp_match boolean
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
           EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = ch.pc AND rr.in_win AND ((v_desk.is_dc AND rr.is_z) OR ((NOT v_desk.is_dc) AND rr.sup = ANY(v_direct)))),
           EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = ch.pc AND rr.in_win AND (NOT v_desk.is_dc) AND rr.is_f AND rr.sup = ANY(v_direct)),
           (SELECT max(rr.last_dt) FROM _pv_rcpt rr WHERE rr.pc = ch.pc AND ((v_desk.is_dc AND rr.is_z) OR ((NOT v_desk.is_dc) AND rr.sup = ANY(v_direct)))),
           EXISTS (SELECT 1 FROM _pv_supp ss WHERE ss.pc = ch.pc AND ((v_desk.is_dc AND ss.is_z) OR ((NOT v_desk.is_dc) AND ss.sup = ANY(v_direct))))
      FROM chosen ch$n6$);
  k := (length(src) - length(replace(src, $o7$  WITH ranked AS (
    SELECT p.*,$o7$, ''))) / length($o7$  WITH ranked AS (
    SELECT p.*,$o7$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 7 matched % times', k; END IF;
  src := replace(src, $o7$  WITH ranked AS (
    SELECT p.*,$o7$, $n7$  WITH rcpt AS (
    -- ENG-183 (ORDERING-CANON SSA2, Pieter 2026-09-10). The supplier is who the line was RECEIVED from (GRV-led).
    -- In the current regime: one receiving desk owns it, more than one goes to DC, because DC is the preferred
    -- supplier always where there are multiple suppliers. Not received in the regime: the desk whose supplier
    -- delivered it LAST in our history (DC on a same-day tie). Never received: Sigma's supplier column. Else DC, VERIFY.
    SELECT q.product_code, array_agg(q.route_key ORDER BY q.route_key) FILTER (WHERE q.desk_rcpt) AS rcpt_desks,
           COALESCE(bool_or(q.desk_rcpt AND q.is_dc), false) AS dc_rcpt,
           COALESCE(bool_or(q.desk_rcpt_f), false) AS f_rcpt,
           COALESCE(bool_or(q.desk_last IS NOT NULL), false) AS hist_any,
           COALESCE(bool_or(q.supp_match), false) AS supp_any
      FROM _pv_pool q GROUP BY q.product_code
  ),
  ranked AS (
    SELECT p.*, rc.rcpt_desks, rc.dc_rcpt, rc.f_rcpt, rc.hist_any, rc.supp_any,$n7$);
  k := (length(src) - length(replace(src, $o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$, ''))) / length($o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$);
  IF k <> 1 THEN RAISE EXCEPTION 'refresh_l2_population_verdict patch 8 matched % times', k; END IF;
  src := replace(src, $o8$ORDER BY p.is_dc DESC, p.route_key) AS rk,$o8$, $n8$ORDER BY p.desk_rcpt DESC, (rc.rcpt_desks IS NOT NULL AND p.is_dc) DESC, p.desk_last DESC NULLS LAST, (rc.hist_any AND p.is_dc) DESC, p.supp_match DESC, p.is_dc DESC, p.desk_sort NULLS LAST, p.route_key) AS rk,$n8$);
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
         CASE WHEN NOT f.overlap AND NOT f.desk_rcpt AND EXISTS (SELECT 1 FROM _pv_rcpt rr WHERE rr.pc = f.product_code AND rr.in_win) THEN 'SOLE_DESK_OFF_DESK_RECEIPT'
              WHEN NOT f.overlap THEN 'SOLE_DESK'
              WHEN f.rcpt_desks IS NULL AND f.hist_any THEN 'HISTORY_RECEIPT'
              WHEN f.rcpt_desks IS NULL AND f.supp_any THEN 'SUPP_CD'
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
  DROP TABLE IF EXISTS _pv_supp;

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
  src := replace(src, $o14$population-verdict v2.1 (ENG-099 new-range fix)$o14$, $n14$population-verdict v2.2 (ENG-183 desk split, received-from, history, supplier column)$n14$);
  IF md5(src) <> '54b02e1d35a922af3b56e33019089dc7' THEN RAISE EXCEPTION 'refresh_l2_population_verdict: patched text md5 is %, expected 54b02e1d35a922af3b56e33019089dc7', md5(src); END IF;
  EXECUTE src;
  SELECT pg_get_functiondef(p.oid) INTO src FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = 'refresh_l2_population_verdict';
  IF md5(src) <> '54b02e1d35a922af3b56e33019089dc7' THEN RAISE EXCEPTION 'refresh_l2_population_verdict: installed pin is %, expected 54b02e1d35a922af3b56e33019089dc7', md5(src); END IF;
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
