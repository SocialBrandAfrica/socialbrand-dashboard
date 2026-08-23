-- refresh_l2_population_verdict -- THE CROSS-APP POPULATION FACT
-- SB-CC-BLOOM-026 §12 / SB-CC-BLOOM-027 §3.2. R33 clause 3, R32.
--
-- ONE fact per (client, store, product): the standing population state with its
-- reason, so Bloom (order sheet), Forge (count list), Pulse (diagnoses) and
-- Capital Tied (classification scope) stop re-implementing the same rule.
--
-- v2.1  2026-08-23  ENG-099 FIXED. NEW_RANGE was over-inclusive because
--                   `first_dt IS NULL` swept in every never-RECEIVED catalogue
--                   stub -- absence of evidence read as evidence of absence
--                   (R23 §2). The ranging signal is now:
--                       never_sold AND (first_receipt <= 120d
--                                       OR sigma_articles.created_date <= 120d)
--                   so a never-DELIVERED new range still qualifies (brief §5(c),
--                   the Old Spice / Clere class) while a stub catalogued years
--                   ago does not. `sigma_supplier_link.cost_date` was TESTED AND
--                   REJECTED as the ranging signal -- the DC re-prices routinely
--                   (ORDERING-CANON §A5 7d).
--                   Stubs now fall to SLOW_BELOW_GATE carrying their OWN reason,
--                   never silently (R21 §5).
-- v2.0  2026-08-21  Desk loop in plpgsql with scalars. Killed the 329,640-run
--                   SubPlan and the seven-fold Materialize rescan (rpc_bloom_desks
--                   function-scans at rows=750 against 7 actual).
--
-- Signature UNCHANGED from v2.0, so CREATE OR REPLACE is the sanctioned form
-- (CLAUDE-CODE-RULES Rule 3). The DROP below is typed, never CASCADE, so it
-- cannot take a future dependent down with it (Rule 19 reproducibility).
--
-- Grants: PUBLIC and anon REVOKEd, authenticated + service_role granted.
-- The bound is armed by the CALLER, never in-body -- an in-body SET LOCAL
-- statement_timeout is DECORATIVE (BUG-LOG ENG-096, PM ruling 2026-08-20).

DROP FUNCTION IF EXISTS public.refresh_l2_population_verdict(text);

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

  -- ON COMMIT DROP does NOT clean up between calls inside one transaction (the
  -- l2_sales_budget collision). Explicit drops both ends, pre-empted not hit.
  DROP TABLE IF EXISTS _pv_recv;
  DROP TABLE IF EXISTS _pv_first;
  DROP TABLE IF EXISTS _pv_soh;
  DROP TABLE IF EXISTS _pv_pool;

  -- STORE-SCOPED, COMPUTED ONCE (v1 recomputed these per desk).
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

  -- ONE DESK AT A TIME. Scalars, so no SubPlan and no cross-join rescan.
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
      -- ENG-099: the catalogue-age leg of the ranging signal. TWO-KEY join --
      -- sigma_articles is grained on (store_code, product_code) and a one-key
      -- join fans out ~2.2x (RULE-BOOK §2 / PROJECT-LEXICON quantity family).
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
    -- EVERY flag is COALESCEd to false. The flag_* columns are NOT NULL, and a
    -- NULL boolean in a flag has no meaning anyway -- "did this fire" is a
    -- two-valued question. Learned the hard way on the v2.1 first run: with
    -- `first_dt IS NULL` removed, a stub with an old created_date evaluates
    -- `NULL OR false` = NULL, not false, and the INSERT failed the NOT NULL.
    -- f_hidden carried the SAME latent hazard (a HERO/CORE line with no pantry
    -- row has a NULL ros_56d_guard), so the contract is now satisfied
    -- structurally rather than by luck.
    SELECT r.*,
      COALESCE(r.range_state IN ('HERO','CORE') AND r.ros_56d_guard = 'withheld_observable_floor'
        AND r.ros_56d_published IS NULL
        AND COALESCE(r.ros_56d_corrected,0) > COALESCE(r.ros_56d,0), false)    AS f_hidden,
      COALESCE(COALESCE(r.lc,0) = 0, false)                                    AS f_cost,
      COALESCE(r.range_state = 'VERIFY', false)                                AS f_phantom,
      -- ENG-099 FIX. `first_dt IS NULL` is GONE: a never-received line is a
      -- catalogue stub, not a new range. A never-DELIVERED new range still
      -- qualifies on catalogue age, which is what brief §5(c) requires.
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
              -- ENG-099: the stubs displaced out of NEW_RANGE land here and say
              -- so in their own words. Same state, truthful reason (R21 §5, R29).
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

REVOKE EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_l2_population_verdict(text) TO service_role;
