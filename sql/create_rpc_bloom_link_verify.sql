-- =====================================================================
-- rpc_bloom_link_verify -- SB-CC-BLOOM-026 PART (e), LINK AMBIGUITY AS VERIFY
--
-- Ref:    Bloom/SB-CC-BLOOM-026_Order-Population-Completeness.md, part 5(e)
-- Date:   2026-08-19
-- Owner:  Claude Code
-- Canon:  R21 SS5 - R22 - R25/SS0h - R29 - ORDERING-CANON SSA2, SSA5 7d
--         (receipts never links), SS12c (the cost-error class)
-- Class:  read-only, quantity-neutral, additive, reversible. No recipe touch.
--
-- WHAT THE MEASUREMENT CHANGED ABOUT THIS PART.
-- Part (e) was scoped as a TIEBREAK fix: move the link key off the hardcoded
-- supplier_nr 1339 onto receipts. Simulated across all five stores before
-- touching anything, the tiebreak is not the defect:
--   products where the old key passed over a RECEIPTING link, group-wide:   1
--   products with two receipting suppliers competing:                       0
--   products where ONE receipting supplier carries several pack sizes:    181
-- The ambiguity is INSIDE one supplier's own link set, not between suppliers,
-- so no ordering key can resolve it. Only surfacing, or a fix at source, can.
--
-- AND THE LARGER DEFECT FOUND WHILE BUILDING IT: ZERO-COST LINKS.
-- Many links carry list_cost = R0.00. If the tiebreak lands on one, the engine
-- prices that line at NOTHING -- it contributes R0 to the order value and to
-- budget consumption, so the order reads cheaper than it is and Fit-to-Budget
-- passes more through on the strength of it. Measured 2026-08-19:
--   lines in the DC pools currently priced off a zero-cost link:          242
--   of those, on last night's cached orders with packs > 0:               13
--   (10116 9 lines / 10 packs, 80579 3 / 4, 80176 1 / 1, all at R0.00)
-- The 242 is POOL EXPOSURE. The 13 is TODAY'S ORDER IMPACT. They are different
-- numbers and are never to be quoted as one.
--
-- THIS OBJECT DOES NOT RE-PICK. It names the ambiguity, lists every candidate
-- with its implied unit cost and its receipt count, flags whether the link the
-- engine actually chose carries no cost, and shows the spread between the
-- dearest and cheapest COSTED readings of the same need. A human resolves it at
-- source (SS5e: "it is not that the engine cannot price it, it is that the
-- chosen pack may be wrong").
--
-- SPREAD IS COMPUTED ON COSTED LINKS ONLY. The first build divided by the
-- minimum unit cost, which is zero wherever a zero-cost link exists -- so the
-- metric went NULL on precisely the rows that matter most. Fixed, and zero-cost
-- links now carry their own reason code and sort first.
--
-- WORKED CASE NOTE, RECORDED SO IT IS NOT REPEATED. SPAR SC COOK DRK 70 TRIPE
-- (63914 @ 80175) drove this part through two rounds of ruling and is NOT a
-- valid case for it: it is department 6 HMR, outside the DC ambient dept set
-- {9..18,29}, range_state EXCLUDED. It is World-2 production output and SS4's
-- hard boundary forbids it entering a DC ambient desk at all. Its six links and
-- three pack sizes are real, but they are not this desk's problem. A valid
-- in-pool case at the same store is HOC HUG MUG CAPP (827380): pack 10 @ R478.81
-- (unit R47.88) against pack 96 @ R692.49 (unit R7.21), both under 1339, both
-- receipting, a 564% unit spread.
--
-- ⚠️ TRACKED DEBTS, same as part (b): the pool gate is REPRODUCED from the live
-- recipe rather than shared (R25 SS2), and the recipe's own 1339 literal is
-- reproduced in `chosen` so this card describes the order the buyer is actually
-- looking at. Both are fixed in one place when the recipe is opened.
--
-- ⚠️ SECURITY DEFINER IS LOAD-BEARING: l2_soh_daily and sigma_movements both
-- carry RLS with no policies, so an invoker-rights build returns zero rows as
-- anon and reports a confident "no ambiguity" (the ENG-068 / ENG-074 shape).
-- ⚠️ NOT STABLE on purpose: it issues SET LOCAL statement_timeout.
-- ⚠️ Every CTE output is ALIASED (pc/sup/ps/lc) because RETURNS TABLE declares
-- product_code, which shadows bare CTE references in plpgsql (42702) -- the same
-- trap DB-SCHEMA records against rpc_bloom_order_direct_beer.
-- =====================================================================

DROP FUNCTION IF EXISTS public.rpc_bloom_link_verify(text,text);

CREATE FUNCTION public.rpc_bloom_link_verify(
  p_store_code text,
  p_route      text
)
RETURNS TABLE (
  product_code         bigint,
  description          text,
  dept_name            text,
  range_state          text,
  soh                  numeric,
  verify_reason        text,
  chosen_supplier_nr   bigint,
  chosen_pack_size     smallint,
  chosen_pack_cost     numeric,
  chosen_unit_cost     numeric,
  chosen_is_zero_cost  boolean,
  candidate_links      integer,
  distinct_packs       integer,
  receipting_suppliers integer,
  zero_cost_links      integer,
  unit_cost_spread_pct numeric,
  candidates           text,
  reason               text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_dept_nrs smallint[]; v_direct bigint[]; v_is_dc boolean; v_soh_dt date;
BEGIN
  SET LOCAL statement_timeout = '25s';

  SELECT d.is_dc INTO v_is_dc FROM public.rpc_bloom_desks(p_store_code) d
   WHERE d.route_key = p_route;
  IF v_is_dc IS NULL THEN
    RAISE EXCEPTION 'no desk % at store % -- see rpc_bloom_desks', p_route, p_store_code;
  END IF;

  IF v_is_dc THEN
    SELECT dc.dc_cycle_dept_nrs INTO v_dept_nrs FROM public.bloom_dc_config dc
     WHERE dc.store_code=p_store_code AND dc.status='RULED';
  ELSE
    SELECT rc.direct_supplier_nrs INTO v_direct FROM public.bloom_route_config rc
     WHERE rc.store_code=p_store_code AND rc.route_key=p_route;
  END IF;

  SELECT MAX(sd.snapshot_date) INTO v_soh_dt
    FROM public.l2_soh_daily sd WHERE sd.store_code=p_store_code;

  RETURN QUERY
  WITH recv AS (
    SELECT m.product_code AS pc, m.supplier_nr AS sup, count(*) AS n
      FROM public.sigma_movements m
      JOIN public.sigma_supplier_master sm2
        ON sm2.store_code=m.store_code AND sm2.supplier_nr=m.supplier_nr
     WHERE m.store_code=p_store_code
       AND m.movement_type IN ('R','W') AND m.module='DIWAREPR' AND m.qty > 0
       AND m.movement_date > CURRENT_DATE - 364
       AND sm2.supplier_type='Z'
     GROUP BY 1,2
  ),
  cand AS (
    SELECT sl.product_code AS pc, sl.supplier_nr AS sup, sl.pack_size AS ps,
           sl.list_cost AS lc, sl.cost_date AS cd, r.n AS recv_n,
           CASE WHEN COALESCE(sl.list_cost,0) > 0
                THEN sl.list_cost / NULLIF(GREATEST(sl.pack_size,1),0) END AS uc_nz
      FROM public.sigma_supplier_link sl
      JOIN public.sigma_supplier_master sm
        ON sm.store_code=sl.store_code AND sm.supplier_nr=sl.supplier_nr
      LEFT JOIN recv r ON r.pc=sl.product_code AND r.sup=sl.supplier_nr
     WHERE sl.store_code=p_store_code
       AND COALESCE(sl.status,'')<>'S'
       AND (sl.valid_to IS NULL OR sl.valid_to>=CURRENT_DATE)
       AND ( (v_is_dc AND sm.supplier_type='Z')
             OR ((NOT v_is_dc) AND sl.supplier_nr = ANY(v_direct)) )
  ),
  agg AS (
    SELECT x.pc AS pc,
           count(*)::int AS links,
           count(DISTINCT x.ps)::int AS packs,
           count(DISTINCT x.sup) FILTER (WHERE x.recv_n IS NOT NULL)::int AS recv_sups,
           count(*) FILTER (WHERE COALESCE(x.lc,0) = 0)::int AS zero_links,
           min(x.uc_nz) AS uc_min, max(x.uc_nz) AS uc_max,
           string_agg(DISTINCT 'sup '||x.sup||' pack '||COALESCE(x.ps,0)||
                      ' @R'||to_char(COALESCE(x.lc,0),'FM999999990.00')||
                      CASE WHEN COALESCE(x.lc,0)=0 THEN ' <ZERO COST>'
                           ELSE ' (unit R'||to_char(x.uc_nz,'FM999999990.00')||')' END||
                      CASE WHEN x.recv_n IS NOT NULL THEN ' [receipts '||x.recv_n||']' ELSE '' END, ' | ')
             AS cands
      FROM cand x GROUP BY x.pc
  ),
  chosen AS (
    SELECT DISTINCT ON (y.pc)
           y.pc AS pc, y.sup AS sup, y.ps AS ps, y.lc AS lc, y.uc_nz AS uc
      FROM cand y
     ORDER BY y.pc, (y.sup=1339) DESC, y.cd DESC NULLS LAST
  )
  SELECT c.pc, sp.description, sp.dept_name,
         COALESCE(rs.range_state,'SLOW'),
         ROUND(COALESCE(so.soh,0),2),
         CASE WHEN COALESCE(c.lc,0) = 0        THEN 'PRICED_OFF_ZERO_COST_LINK'
              WHEN g.recv_sups > 1             THEN 'TWO_RECEIPTING_SUPPLIERS'
              WHEN g.zero_links > 0            THEN 'ZERO_COST_LINK_PRESENT'
              WHEN g.recv_sups = 1             THEN 'PACK_AMBIGUOUS'
              ELSE 'PACK_AMBIGUOUS_NO_RECEIPT' END,
         c.sup, c.ps, ROUND(c.lc,2), ROUND(c.uc,4),
         (COALESCE(c.lc,0) = 0),
         g.links, g.packs, g.recv_sups, g.zero_links,
         ROUND(((g.uc_max - g.uc_min) / NULLIF(g.uc_min,0) * 100)::numeric, 1),
         g.cands,
         format('%s active DC links across %s pack sizes%s. The engine prices this line off pack %s at R%s%s.%s Resolve the link at source. The engine is not re-picking it.',
                g.links, g.packs,
                CASE WHEN g.recv_sups > 1 THEN ', '||g.recv_sups||' suppliers receipting'
                     WHEN g.recv_sups = 1 THEN ', one receipting supplier'
                     ELSE ', no DC receipt in 364 days to arbitrate' END,
                c.ps, to_char(COALESCE(c.lc,0),'FM999999990.00'),
                CASE WHEN COALESCE(c.lc,0)=0 THEN ' WHICH CARRIES NO COST -- this line prices at zero'
                     ELSE ' (unit R'||to_char(c.uc,'FM999999990.00')||')' END,
                CASE WHEN g.zero_links > 0
                     THEN ' '||g.zero_links||' of its links carry R0.00 and would price the line at nothing if chosen.'
                     WHEN g.uc_min IS NOT NULL AND g.uc_max > g.uc_min
                     THEN ' Dearest and cheapest costed readings differ by '||
                          ROUND(((g.uc_max-g.uc_min)/NULLIF(g.uc_min,0)*100)::numeric,0)||'% per unit.'
                     ELSE '' END)
    FROM chosen c
    JOIN agg g ON g.pc=c.pc
    JOIN public.l2_stock_band b ON b.store_code=p_store_code AND b.product_code=c.pc
    LEFT JOIN public.l2_stock_position sp ON sp.store_code=p_store_code AND sp.product_code=c.pc
    LEFT JOIN public.l2_range_state rs ON rs.store_code=p_store_code AND rs.product_code=c.pc
    LEFT JOIN public.l2_soh_daily so ON so.store_code=p_store_code AND so.product_code=c.pc
                                    AND so.snapshot_date=v_soh_dt
   WHERE COALESCE(rs.range_state,'') <> 'EXCLUDED'
     AND ( (v_is_dc AND sp.department_nr = ANY(v_dept_nrs)) OR (NOT v_is_dc) )
     AND (g.packs > 1 OR g.recv_sups > 1 OR g.zero_links > 0)
   ORDER BY (COALESCE(c.lc,0) = 0) DESC,          -- priced at zero today: worst first
            g.zero_links DESC,
            ((g.uc_max - g.uc_min)/NULLIF(g.uc_min,0)) DESC NULLS LAST,
            c.pc;
END $fn$;

-- A READ rpc. Grants stated explicitly (R30 addendum); anon-executable by design.
REVOKE ALL ON FUNCTION public.rpc_bloom_link_verify(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_bloom_link_verify(text,text) TO anon, authenticated, service_role;

SELECT pg_notify('pgrst', 'reload schema');
