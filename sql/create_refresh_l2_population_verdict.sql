-- create_refresh_l2_population_verdict.sql
--
-- REPLACED FROM LIVE 2026-08-30 (ENG-115 class rule: a sql/ file that was not
-- generated from live can never be hash-gated, only replaced). Hash-gated against
-- the database in the same pass.
--
-- Migration that shaped the current body:
--   eng106_leg_a_per_line_cost_demand_columns (2026-08-27)
--
-- WHAT IT IS. The CROSS-APP POPULATION FACT (SB-CC-BLOOM-026 §12 / R33 clause 3):
-- ONE fact per (client, store, product) carrying the standing population state
-- and its reason, so Bloom (order sheet), Forge (count list), Pulse (diagnoses)
-- and Capital Tied stop re-implementing the same rule.
--
-- ⚠️ population_state is FIRST-MATCH-WINS (§2 cascade discipline). The flag_*
-- booleans are INDEPENDENT, because one line can be a hidden seller AND priced
-- off a zero-cost link. Read the flags for the conditions, the state for the
-- headline. They are not interchangeable.
--
-- ⚠️ NEVER SUM cost_demand_28d FOR A ROUTE TOTAL. §D6.1: "a category or route
-- total is NEVER published off l2_population_verdict." Measured 2026-08-30,
-- summing the pool understates the route by 33.9% (10116), 34.8% (80175) and
-- 53.3-58.7% across the TOPS trio -- R260,148.85 at 10116 alone. The route
-- benchmark is a SEPARATE dept-scope leg and it lives in
-- rpc_bloom_route_benchmark (ENG-106 leg b).
--
-- ENG-106 leg (a), the columns this file added: cost_demand_28d and
-- cost_demand_anchor_date, written by APPEND-AFTER-COMPUTE -- a plain join AFTER
-- every verdict row is committed, so the leg is STRUCTURALLY INCAPABLE of moving
-- a population_state, a flag, or any figure the verdict computes. Anchored on the
-- LEDGER WATERMARK per §D6.1 clause 2, never CURRENT_DATE: storing a
-- CURRENT_DATE-anchored figure in a nightly column would bake the retired anchor
-- into the pantry and put these columns ~3% out of step with the benchmark by
-- construction. Only the FACT is stored, not its divisions -- daily is /28,
-- weekly is /4, and a recipe picks its own divisor (R27 §2).
--
-- ⚠️ A pool line with no sales in the window is written as a REAL ZERO, never left
-- NULL. NULL would let a consumer read "not measured" as "no demand".
--
-- ⚠️ THE `1339` LITERAL IN THE `chosen` CTE IS DELIBERATE AND IS A NAMED §0h DEBT.
-- supplier_nr is store-local and collides: 1339 is SPAR SOUTHRAND (the DC) at
-- 80175 ONLY, and a DROPSHIP at the other four stores. This fact reproduces the
-- recipe's own link pick INCLUDING that literal ON PURPOSE, so the fact describes
-- the order the buyer is actually looking at. It does NOT re-pick. ORDERING-CANON
-- §H8 v1.5: the recipe is not changed and the literal is removed only when the
-- recipe is next legitimately opened -- which is the §H opening gate, bundled.
--
-- ⚠️ ENG-099: NEW_RANGE requires never_sold AND (first receipt <=120d OR
-- created_date <=120d). Without the receipt leg a never-sold, never-RECEIVED line
-- reads as new when it is a catalogue stub -- that was 8,387 at 80175 alone.
-- sigma_supplier_link.cost_date stays TESTED AND REJECTED as the ranging signal:
-- the DC re-prices routinely (§A5 7d).

CREATE OR REPLACE FUNCTION public.refresh_l2_population_verdict(p_store_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_soh_dt date;
  v_client constant text := 'socialbrand';
  v_engine constant text := 'BLOOM-026 population-verdict v2.1 (ENG-099 new-range fix)';
  v_desk   record;
  v_dept   smallint[];
  v_direct bigint[];
  v_rows   int;
  v_out    jsonb;
BEGIN
  IF p_store_code IS NULL THEN
    RAISE EXCEPTION 'p_store_code is required';
  END IF;

  SELECT MAX(sd.snapshot_date) INTO v_soh_dt
    FROM l2_soh_daily sd WHERE sd.store_code = p_store_code;
  IF v_soh_dt IS NULL THEN
    RAISE EXCEPTION 'no l2_soh_daily rows for store % -- refusing to write a verdict with no stock position', p_store_code;
  END IF;

  DROP TABLE IF EXISTS _pv_recv;
  DROP TABLE IF EXISTS _pv_first;
  DROP TABLE IF EXISTS _pv_soh;
  DROP TABLE IF EXISTS _pv_pool;

  CREATE TEMP TABLE _pv_recv AS
    SELECT m.product_code AS pc, m.supplier_nr AS sup, count(*)::int AS n
      FROM sigma_movements m
      JOIN sigma_supplier_master sm2
        ON sm2.store_code = m.store_code AND sm2.supplier_nr = m.supplier_nr
     WHERE m.store_code = p_store_code
       AND m.movement_type IN ('R','W') AND m.module = 'DIWAREPR' AND m.qty > 0
       AND m.movement_date > CURRENT_DATE - 364
       AND sm2.supplier_type = 'Z'
     GROUP BY 1,2;
  CREATE INDEX ON _pv_recv (pc, sup);

  CREATE TEMP TABLE _pv_first AS
    SELECT m.product_code AS pc, MIN(m.movement_date) AS first_dt
      FROM sigma_movements m
     WHERE m.store_code = p_store_code
       AND m.movement_type IN ('R','W') AND m.qty > 0
     GROUP BY 1;
  CREATE INDEX ON _pv_first (pc);

  CREATE TEMP TABLE _pv_soh AS
    SELECT sd.product_code AS pc, sd.soh
      FROM l2_soh_daily sd
     WHERE sd.client_id = v_client AND sd.store_code = p_store_code
       AND sd.snapshot_date = v_soh_dt;
  CREATE INDEX ON _pv_soh (pc);

  CREATE TEMP TABLE _pv_pool (
    route_key text, is_dc boolean, product_code bigint,
    description text, dept_name text, department_nr smallint, tier text, kvi_band text,
    soh numeric, range_state text, passes_life_gate boolean,
    ros_56d numeric, ros_56d_corrected numeric, ros_56d_published numeric,
    ros_56d_guard text, removed smallint,
    last_sale_date date, never_sold boolean, first_dt date, created_dt date,
    sup bigint, ps smallint, lc numeric, uc numeric, valid_to date,
    links int, packs int, recv_sups int, zero_links int, uc_min numeric, uc_max numeric
  );

  ANALYZE _pv_recv;  ANALYZE _pv_first;  ANALYZE _pv_soh;

  FOR v_desk IN SELECT d.route_key, d.is_dc FROM rpc_bloom_desks(p_store_code) d LOOP

    v_dept := NULL; v_direct := NULL;
    IF v_desk.is_dc THEN
      SELECT dc.dc_cycle_dept_nrs INTO v_dept FROM bloom_dc_config dc
       WHERE dc.store_code = p_store_code AND dc.status = 'RULED';
      CONTINUE WHEN v_dept IS NULL;
    ELSE
      SELECT rc.direct_supplier_nrs INTO v_direct FROM bloom_route_config rc
       WHERE rc.store_code = p_store_code AND rc.route_key = v_desk.route_key;
      CONTINUE WHEN v_direct IS NULL;
    END IF;

    INSERT INTO _pv_pool
    WITH cand AS (
      SELECT sl.product_code AS pc, sl.supplier_nr AS sup, sl.pack_size AS ps,
             sl.list_cost AS lc, sl.cost_date AS cd, sl.valid_to,
             CASE WHEN COALESCE(sl.list_cost,0) > 0
                  THEN sl.list_cost / NULLIF(GREATEST(sl.pack_size,1),0) END AS uc_nz
        FROM sigma_supplier_link sl
        LEFT JOIN sigma_supplier_master sm
          ON sm.store_code = sl.store_code AND sm.supplier_nr = sl.supplier_nr
       WHERE sl.store_code = p_store_code
         AND COALESCE(sl.status,'') <> 'S'
         AND (sl.valid_to IS NULL OR sl.valid_to >= CURRENT_DATE)
         AND ( (v_desk.is_dc AND sm.supplier_type = 'Z')
               OR ((NOT v_desk.is_dc) AND sl.supplier_nr = ANY(v_direct)) )
    ),
    agg AS (
      SELECT x.pc,
             count(*)::int                                                   AS links,
             count(DISTINCT x.ps)::int                                        AS packs,
             count(DISTINCT x.sup) FILTER (WHERE r.n IS NOT NULL)::int         AS recv_sups,
             count(*) FILTER (WHERE COALESCE(x.lc,0) = 0)::int                AS zero_links,
             min(x.uc_nz) AS uc_min, max(x.uc_nz) AS uc_max
        FROM cand x LEFT JOIN _pv_recv r ON r.pc = x.pc AND r.sup = x.sup
       GROUP BY 1
    ),
    chosen AS (
      SELECT DISTINCT ON (y.pc) y.pc, y.sup, y.ps, y.lc, y.uc_nz AS uc, y.valid_to
        FROM cand y
       ORDER BY y.pc, (y.sup = 1339) DESC, y.cd DESC NULLS LAST
    )
    SELECT v_desk.route_key, v_desk.is_dc, b.product_code,
           sp.description, sp.dept_name, sp.department_nr, sp.tier, b.kvi_band,
           COALESCE(so.soh,0), COALESCE(rs.range_state,'SLOW'), kp.passes_life_gate,
           rop.ros_56d, rop.ros_56d_corrected, rop.ros_56d_published,
           rop.ros_56d_guard, rop.correction_days_removed_56d,
           ros.last_sale_date, ros.never_sold, fr.first_dt, sa.created_date,
           ch.sup, ch.ps, ch.lc, ch.uc, ch.valid_to,
           g.links, g.packs, g.recv_sups, g.zero_links, g.uc_min, g.uc_max
      FROM chosen ch
      JOIN agg g ON g.pc = ch.pc
      JOIN l2_stock_band b ON b.store_code = p_store_code AND b.product_code = ch.pc
      LEFT JOIN l2_stock_position sp ON sp.client_id = v_client AND sp.store_code = p_store_code
                                    AND sp.product_code = ch.pc
      LEFT JOIN l2_rate_of_sale  ros ON ros.client_id = v_client AND ros.store_code = p_store_code
                                    AND ros.product_code = ch.pc
      LEFT JOIN l2_range_state    rs ON rs.store_code = p_store_code AND rs.product_code = ch.pc
      LEFT JOIN l2_kvi_profile    kp ON kp.store_code = p_store_code AND kp.product_code = ch.pc
      LEFT JOIN l2_bloom_ros_pantry rop ON rop.store_code = p_store_code AND rop.product_code = ch.pc
      LEFT JOIN _pv_soh   so ON so.pc = ch.pc
      LEFT JOIN _pv_first fr ON fr.pc = ch.pc
      LEFT JOIN sigma_articles    sa ON sa.store_code = p_store_code AND sa.product_code = ch.pc
     WHERE COALESCE(rs.range_state,'') <> 'EXCLUDED'
       AND ( (v_desk.is_dc AND sp.department_nr = ANY(v_dept)) OR (NOT v_desk.is_dc) );

  END LOOP;

  ANALYZE _pv_pool;

  DELETE FROM l2_population_verdict WHERE store_code = p_store_code;

  INSERT INTO l2_population_verdict (
    client_id, store_code, product_code, description, dept_name, department_nr,
    route_key, is_dc, route_overlap, population_state, state_reason,
    flag_hidden_seller, flag_new_range, flag_dormant_empty, flag_phantom_claims_stock,
    flag_link_lapsed, flag_verify_link_pack, flag_cost_unpriced,
    soh, soh_date, range_state, kvi_band, tier, passes_life_gate,
    rate_raw_56d, rate_corrected_56d, rate_published_56d, rate_guard_56d,
    days_removed_56d, observable_days, observable_share,
    chosen_supplier_nr, chosen_pack_size, chosen_pack_cost, chosen_unit_cost,
    chosen_is_zero_cost, candidate_links, distinct_packs, receipting_suppliers,
    zero_cost_links, unit_cost_spread_pct, cost_basis,
    first_receipt_date, last_sale_date, never_sold, link_valid_to, engine_version
  )
  WITH ranked AS (
    SELECT p.*,
           row_number() OVER (PARTITION BY p.product_code ORDER BY p.is_dc DESC, p.route_key) AS rk,
           (count(*)   OVER (PARTITION BY p.product_code) > 1)                                AS overlap
      FROM _pv_pool p
  ),
  f AS (
    SELECT r.*,
      COALESCE(r.range_state IN ('HERO','CORE') AND r.ros_56d_guard = 'withheld_observable_floor'
        AND r.ros_56d_published IS NULL
        AND COALESCE(r.ros_56d_corrected,0) > COALESCE(r.ros_56d,0), false)    AS f_hidden,
      COALESCE(COALESCE(r.lc,0) = 0, false)                                    AS f_cost,
      COALESCE(r.range_state = 'VERIFY', false)                                AS f_phantom,
      COALESCE(COALESCE(r.never_sold,true)
        AND (   r.first_dt   >= CURRENT_DATE - 120
             OR r.created_dt >= CURRENT_DATE - 120), false)                    AS f_new,
      COALESCE(COALESCE(r.never_sold,true) = false AND r.last_sale_date >= CURRENT_DATE - 120
        AND COALESCE(r.soh,0) <= 0 AND COALESCE(r.passes_life_gate,false) = false, false) AS f_dormant,
      COALESCE(r.packs > 1 OR r.recv_sups > 1 OR r.zero_links > 0, false)      AS f_verify
      FROM ranked r WHERE r.rk = 1
  )
  SELECT v_client, p_store_code, f.product_code, f.description, f.dept_name, f.department_nr,
         f.route_key, f.is_dc, f.overlap,
         CASE WHEN f.f_hidden THEN 'HIDDEN_SELLER_SUPPRESSED'
              WHEN f.f_cost   THEN 'COST_UNPRICED'
              WHEN f.f_phantom THEN 'PHANTOM_CLAIMS_STOCK'
              WHEN f.f_new    THEN 'NEW_RANGE'
              WHEN f.f_dormant THEN 'DORMANT_EMPTY'
              WHEN f.f_verify THEN 'VERIFY_LINK_OR_PACK'
              WHEN COALESCE(f.passes_life_gate,false) THEN 'COVERED_TRUSTED_RATE'
              ELSE 'SLOW_BELOW_GATE' END,
         CASE WHEN f.f_hidden THEN
                format('Hidden seller. The 56-day correction was WITHHELD (%s of 56 days removed, %s observable). The order read %s/day, the corrector measured %s/day, so the line looks covered and computes need at or below zero. Keyed on the withheld flag, never band position.',
                  COALESCE(f.removed,0), 56-COALESCE(f.removed,0),
                  ROUND(COALESCE(f.ros_56d,0),2), ROUND(COALESCE(f.ros_56d_corrected,0),2))
              WHEN f.f_cost THEN
                format('Priced off a link carrying R0.00 (supplier %s, pack %s), so the engine values it at NOTHING and the budget reads low. %s of %s links carry no cost. R0.00 is a SENTINEL, never a price.',
                  f.sup, COALESCE(f.ps,0), f.zero_links, f.links)
              WHEN f.f_phantom THEN
                'Claims stock the ledger cannot support (range_state VERIFY, the DF-7 signature). Count before ordering, never order on the claim.'
              WHEN f.f_new THEN
                format('New range. Never sold, %s, catalogued %s. No history means no rate, so the life gate reads it exactly like a dead line and it never reaches the order sheet.',
                  CASE WHEN f.first_dt IS NULL THEN 'NEVER DELIVERED' ELSE 'first received '||f.first_dt::text END,
                  COALESCE(f.created_dt::text,'date unknown'))
              WHEN f.f_dormant THEN
                format('Dormant empty. Sold to %s, now at SOH %s and failing the life gate because it went empty. Invisible to reorder and to slow movers at once.',
                  f.last_sale_date::text, ROUND(COALESCE(f.soh,0),0))
              WHEN f.f_verify THEN
                format('Verify. %s links across %s pack sizes, %s receipting supplier(s). The chosen pack may be wrong, so the line is surfaced rather than silently re-picked.',
                  f.links, f.packs, f.recv_sups)
              WHEN COALESCE(f.passes_life_gate,false) THEN
                format('Accounted for on a trusted rate (%s/day published, guard %s).',
                  ROUND(COALESCE(f.ros_56d_published,0),2), COALESCE(f.ros_56d_guard,'none'))
              WHEN COALESCE(f.never_sold,true) AND f.first_dt IS NULL THEN
                format('Catalogue stub. Never sold and never received, catalogued %s. A listing with no trading history at all, so it is neither a new range nor a slow seller.',
                  COALESCE(f.created_dt::text,'date unknown'))
              ELSE 'Below the life gate on its own demand. Listed, no depth, correctly not ordered.' END,
         f.f_hidden, f.f_new, f.f_dormant, f.f_phantom, false, f.f_verify, f.f_cost,
         ROUND(f.soh,2), v_soh_dt, f.range_state, f.kvi_band, f.tier, f.passes_life_gate,
         ROUND(f.ros_56d,4), ROUND(f.ros_56d_corrected,4), ROUND(f.ros_56d_published,4), f.ros_56d_guard,
         COALESCE(f.removed,0)::smallint, (56-COALESCE(f.removed,0))::smallint,
         ROUND(((56-COALESCE(f.removed,0))::numeric/56),3),
         f.sup, f.ps, ROUND(f.lc,2), ROUND(f.uc,4), (COALESCE(f.lc,0)=0),
         f.links, f.packs, f.recv_sups, f.zero_links,
         ROUND(((f.uc_max-f.uc_min)/NULLIF(f.uc_min,0)*100),1),
         CASE WHEN COALESCE(f.lc,0)=0 THEN 'COST_UNPRICED' ELSE 'LINK' END,
         f.first_dt, f.last_sale_date, f.never_sold, f.valid_to, v_engine
    FROM f;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- ENG-106 leg (a). APPEND-AFTER-COMPUTE (DB-SCHEMA Architecture Rules): the
  -- per-line cost demand is written by a plain join AFTER every verdict row is
  -- already committed above, so this leg is STRUCTURALLY INCAPABLE of moving a
  -- population_state, a flag or any figure the verdict computes. Anchored on the
  -- ledger watermark per SSD6.1 clause 2, never CURRENT_DATE.
  WITH anchor AS (
    SELECT max(sale_date) AS a FROM sigma_sales
     WHERE store_code = p_store_code AND sale_date >= CURRENT_DATE - 90
  ),
  s AS (
    SELECT ss.product_code, SUM(ss.cost_value) AS cost28, (SELECT a FROM anchor) AS anch
      FROM sigma_sales ss, anchor
     WHERE ss.store_code = p_store_code
       AND ss.period_kind = 'T' AND ss.txn_kind = 1
       AND ss.sale_date >  anchor.a - 28
       AND ss.sale_date <= anchor.a
     GROUP BY 1
  )
  UPDATE l2_population_verdict v
     SET cost_demand_28d = ROUND(s.cost28, 4), cost_demand_anchor_date = s.anch
    FROM s
   WHERE v.store_code = p_store_code AND v.product_code = s.product_code;

  -- A pool line with no sales in the window is a REAL ZERO, not an unknown.
  -- Leaving it NULL would let a consumer read "not measured" as "no demand".
  UPDATE l2_population_verdict v
     SET cost_demand_28d = 0,
         cost_demand_anchor_date = (SELECT max(sale_date) FROM sigma_sales
                                     WHERE store_code = p_store_code
                                       AND sale_date >= CURRENT_DATE - 90)
   WHERE v.store_code = p_store_code AND v.cost_demand_anchor_date IS NULL;

  DROP TABLE IF EXISTS _pv_recv;
  DROP TABLE IF EXISTS _pv_first;
  DROP TABLE IF EXISTS _pv_soh;
  DROP TABLE IF EXISTS _pv_pool;

  SELECT jsonb_build_object(
    'store_code', p_store_code, 'soh_date', v_soh_dt, 'rows', v_rows, 'engine', v_engine,
    'by_state', COALESCE((SELECT jsonb_object_agg(population_state, c)
                            FROM (SELECT population_state, count(*) c FROM l2_population_verdict
                                   WHERE store_code = p_store_code GROUP BY 1) t), '{}'::jsonb),
    'route_overlap_lines', (SELECT count(*) FROM l2_population_verdict
                             WHERE store_code = p_store_code AND route_overlap)
  ) INTO v_out;

  RETURN v_out;
END $function$;

-- Grants stated explicitly (R30 addendum extension: PUBLIC and anon BOTH revoked
-- on a mutating function, because a role-specific grant survives a REVOKE FROM
-- PUBLIC -- the trap has fired three times on this project).
REVOKE EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) TO service_role;
