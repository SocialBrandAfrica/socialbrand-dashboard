-- eng082_h14_stage2_cutoff_reads_one_home.sql
-- RECORD of migration eng082_h14_stage2_cutoff_reads_one_home, applied 2026-09-14 by CC through the Supabase
-- connector. The text below is the migration as applied. The live body it produced, ec5d1e41 / 6,978, is carried
-- hash-gated in sql/create_rpc_derive_order_cutoff.sql. The cutoffs it derives are enacted by
-- refresh_supplier_calendar_cutoff, run for all five stores in the same pass (18 rows written, the three
-- floor_attested rows skipped).

-- ENG-082 H14 stage 2 (CC 2026-09-14). ORDERING-CANON A5 and -REGISTERS H14 item 14, PM ruling 2026-09-10; scope,
-- Pieter RULING 2026-09-10: the placement derivation and its VERIFY bind DC routes only. The bound is unchanged.
-- Where no pair clears the evidence floor: a DC route reads the ONE placement home, rpc_derive_placement_day, in
-- place of the modal +/-1 set this function carried; a direct or dropship route takes order_cutoff_floor_days.
-- Simulated as a pg_temp copy against the live body on all 21 calendar rows before applying: five direct cutoffs
-- move to the 2-day floor (10116 Coca-Cola 3, 10116 Simba 3, 21355 Coca-Cola 3, 80175 Clover 5, 80175 Simba 3), every
-- DC cutoff holds on demonstrated_pair_lead, and the placement VERIFY drops at 10116 Clover, 80175 Clover and 80175
-- Coca-Cola. The two SAB rows stamped floor_attested derive 2 with VERIFY and are not enacted: the refresh still skips
-- attested rows (ENG-160), and removing that skip is ENG-110 add.2 step 1, a separate pass.
DO $gate$
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'rpc_derive_order_cutoff') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one overload of rpc_derive_order_cutoff';
  END IF;
  IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'rpc_derive_order_cutoff') <> '846f9a31e12d27a572b054317aca740b' THEN
    RAISE EXCEPTION 'live rpc_derive_order_cutoff moved since the simulation';
  END IF;
END $gate$;

CREATE OR REPLACE FUNCTION public.rpc_derive_order_cutoff(p_store_code text, p_route_key text DEFAULT NULL::text)
 RETURNS TABLE(store_code text, route_key text, cutoff_days smallint, basis text, anomaly text, pair_lead_days smallint, pairs_observed integer, dow_lead_days smallint, cycle_weeks smallint, delivery_dows smallint[], seeded_prior smallint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- ENG-082 H14 stage 2, 2026-09-14 (ORDERING-CANON A5, -REGISTERS H14; scope Pieter 2026-09-10: DC routes only).
  -- The bound: GREATEST(order_cutoff_floor_days, the smallest placement-to-GRV lead demonstrated more than once),
  -- enacted when the pairs clear in_transit_min_received_orders and the lead fits inside the route's own cycle.
  -- Otherwise, on a DC route, the admitted placement weekdays of the one home (rpc_derive_placement_day) against
  -- delivery_dows; below its share floor the route keeps its enacted cutoff and surfaces VERIFY. On a direct or
  -- dropship route no placement weekday binds and the fallback is order_cutoff_floor_days (RULING); VERIFY there
  -- only where the ledger holds too few dated placements to derive a lead at all (ENG-110 add.2).
  WITH min_n AS (SELECT value_num::int AS n FROM forge_config
                  WHERE config_key='in_transit_min_received_orders' AND store_format='*' AND retired_on IS NULL),
  win AS (SELECT value_num::int AS d FROM forge_config
           WHERE config_key='in_transit_lead_window_days' AND store_format='*' AND retired_on IS NULL),
  flr AS (SELECT value_num::int AS f FROM forge_config
           WHERE config_key='order_cutoff_floor_days' AND store_format='*' AND retired_on IS NULL),
  route_of AS (
    SELECT o.store_code AS s, o.order_date AS od, o.grv_date AS gd, o.grv_nr AS gn,
           COALESCE((SELECT rc.route_key FROM bloom_route_config rc
                      WHERE rc.store_code=o.store_code AND o.supplier_nr=ANY(rc.direct_supplier_nrs) LIMIT 1),
                    CASE WHEN sc.supplier_class='DC' THEN 'DC' ELSE NULL END) AS route_family
    FROM sigma_orders o
    LEFT JOIN v_supplier_class sc ON sc.store_code=o.store_code AND sc.supplier_nr=o.supplier_nr
    WHERE o.store_code = p_store_code),
  base AS (
    SELECT c.store_code AS s, c.route_key AS rk, c.delivery_dows AS ddows,
           c.cycle_weeks AS cyc, c.order_cutoff_days AS seeded,
           NOT EXISTS (SELECT 1 FROM bloom_route_config rc WHERE rc.store_code = c.store_code AND rc.route_key = c.route_key) AS is_dc,
           d.pairs, d.bound_lead,
           (SELECT count(*)::int FROM route_of r, win
             WHERE r.od IS NOT NULL AND r.od <> DATE '1990-01-01' AND r.od >= CURRENT_DATE - win.d
               AND ((c.route_key LIKE 'DC%' AND r.route_family='DC')
                 OR (c.route_key NOT LIKE 'DC%' AND r.route_family = c.route_key))) AS dated,
           pd.admitted_dows AS dset, pd.admitted_share AS share, pd.placements, pd.verify AS pd_verify,
           (SELECT min(((dd - pw) % 7 + 7) % 7)::smallint
              FROM unnest(c.delivery_dows) dd, unnest(pd.admitted_dows) pw
             WHERE ((dd - pw) % 7 + 7) % 7 > 0) AS dow_lead
    FROM supplier_calendar c
    LEFT JOIN LATERAL (
      SELECT sum(g.c)::int AS pairs,
             GREATEST((SELECT fc.value_num::int FROM forge_config fc WHERE fc.config_key = 'order_cutoff_floor_days' AND fc.store_format = '*' AND fc.retired_on IS NULL), (min(g.lead) FILTER (WHERE g.c >= 2))::int)::smallint AS bound_lead
      FROM (SELECT (r.gd - r.od) AS lead, count(*) AS c
            FROM route_of r, win
            WHERE r.od <> DATE '1990-01-01' AND r.od IS NOT NULL
        AND r.gn <> 0 AND r.gd IS NOT NULL AND r.gd <> DATE '1990-01-01'
        AND r.gd >= r.od AND r.od >= CURRENT_DATE - win.d
        AND ((c.route_key LIKE 'DC%' AND r.route_family='DC')
          OR (c.route_key NOT LIKE 'DC%' AND r.route_family = c.route_key))
            GROUP BY 1) g
    ) d ON true
    LEFT JOIN LATERAL public.rpc_derive_placement_day(c.store_code, c.route_key, CURRENT_DATE) pd ON true
    WHERE c.store_code = p_store_code
      AND (p_route_key IS NULL OR c.route_key = p_route_key)),
  flagged AS (
    SELECT b.*,
           (b.pairs >= (SELECT min_n.n FROM min_n) AND b.bound_lead < b.cyc * 7) AS pair_ok,
           (b.is_dc AND NOT COALESCE(b.pd_verify, true) AND b.dow_lead IS NOT NULL) AS dow_ok
      FROM base b)
  SELECT f.s, f.rk,
         CASE WHEN f.pair_ok THEN f.bound_lead
              WHEN f.dow_ok  THEN GREATEST((SELECT flr.f FROM flr), f.dow_lead)
              WHEN NOT f.is_dc THEN (SELECT flr.f FROM flr)
              -- A DC route below the evidence floor is NOT enacted: it keeps its current enacted cutoff and is
              -- flagged for a human. It is never nulled: rpc_bloom_next_deliveries would substitute a literal.
              ELSE f.seeded END::smallint AS cutoff_days,
         CASE WHEN f.pair_ok THEN 'demonstrated_pair_lead'
              WHEN f.dow_ok AND f.pairs >= (SELECT min_n.n FROM min_n)
                   THEN 'derived_placement_day_x_delivery_dows (6a fallback, H14 one home)'
              WHEN f.dow_ok
                   THEN 'derived_placement_day_x_delivery_dows (no derivable pair, H14 one home)'
              WHEN NOT f.is_dc
                   THEN 'order_cutoff_floor_days (direct or dropship, no demonstrated pair, A5)'
              ELSE 'placement_dow_below_floor (VERIFY, not enacted)' END AS basis,
         NULLIF(concat_ws(' ',
           CASE WHEN f.pairs >= (SELECT min_n.n FROM min_n) AND f.bound_lead >= f.cyc * 7
                THEN format('ANOMALY: demonstrated lead %s days >= its own %s-week cycle, so the desk could never order for the NEXT delivery. Value NOT enacted (canon 6a); %s used. Human read, not a calculation input.',
                            f.bound_lead, f.cyc, CASE WHEN f.is_dc THEN 'the derived placement-day basis' ELSE 'the floor' END) END,
           CASE WHEN f.is_dc AND NOT f.pair_ok AND NOT f.dow_ok
                THEN format('VERIFY: no admitted placement weekday on this DC route clears dow_confidence_min (admitted %s, %s%% of %s placements, rpc_derive_placement_day). Cutoff %s day(s) is CARRIED, not derived, and is not evidence. Human read.',
                            COALESCE(f.dset::text, 'none'), COALESCE(f.share, 0), COALESCE(f.placements, 0), f.seeded)
                WHEN NOT f.is_dc AND NOT COALESCE(f.pair_ok, false) AND f.dated < (SELECT min_n.n FROM min_n)
                THEN format('VERIFY: the lead cannot be derived. %s dated placement(s) in the window, below the %s-order floor (an order raised at GRV carries the 1990 sentinel). Cutoff %s day(s) is the platform floor, a default and not evidence (ENG-110 add.2). Human read.',
                            f.dated, (SELECT min_n.n FROM min_n), (SELECT flr.f FROM flr))
           END), '') AS anomaly,
         f.bound_lead, f.pairs, f.dow_lead, f.cyc, f.ddows, f.seeded
  FROM flagged f ORDER BY f.rk;
$function$;

COMMENT ON FUNCTION public.rpc_derive_order_cutoff(text, text) IS
'GRADE: CALCULATED. The order cutoff as a BOUND, not an average: GREATEST(order_cutoff_floor_days, smallest placement-to-GRV lead the route has demonstrated MORE THAN ONCE). ENG-125 -- it was the MEDIAN, which measured the buyer''s own ordering discipline rather than the supplier''s constraint and cost a whole delivery cycle on the TOPS DC desks. No statistic over these leads can recover the true bound (the data is contaminated by the discipline that produced it), so the floor is a RULE and the demonstrated lead only RAISES it where the route has repeatedly failed to achieve it. The repeat requirement is R28 SS5: a single lucky delivery is not a bound. FALLBACK where no pair clears the evidence floor (ENG-082 H14 stage 2, 2026-09-14; ORDERING-CANON A5, -REGISTERS H14): on a DC route the admitted placement weekdays of the one home, rpc_derive_placement_day, against delivery_dows, or VERIFY with the enacted cutoff carried; on a direct or dropship route order_cutoff_floor_days (RULING), no placement weekday binds, and VERIFY only where the ledger holds too few dated placements to derive a lead at all (ENG-110 add.2). Supersedes the modal +/-1 placement set over in_transit_lead_window_days that this function carried until 2026-09-14.';

REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text, text) TO authenticated, service_role;
