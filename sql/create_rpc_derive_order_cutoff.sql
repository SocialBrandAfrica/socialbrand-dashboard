-- create_rpc_derive_order_cutoff.sql
--   public.rpc_derive_order_cutoff          -- derives the cutoff (STABLE, writes nothing)
--   public.refresh_supplier_calendar_cutoff -- writes it onto supplier_calendar
--
-- REGENERATED FROM LIVE 2026-09-14 by CC (ENG-082 H14 stage 2). Both bodies below are pg_get_functiondef output
-- carried by base64 and hash-gated on disk: rpc_derive_order_cutoff ec5d1e41d94243a88949619240072657 / 6,978 and
-- refresh_supplier_calendar_cutoff 9065b88220b601896e790bdec40df631 / 2,659.
--
-- THIS FILE WAS STALE BEFORE THIS PASS, AND NOTHING FLAGGED IT (the ENG-115 class). It carried the ENG-048 body of
-- 2026-08-30 (the MEDIAN lead, percentile_disc) and a writer with no ENG-160 attested-row skip, so neither object
-- hashed to live (846f9a31... and 9065b882...). ENG-125 (the bound) and ENG-160 (the skip) reached the database and
-- never this file.
--
-- STAGE 2 (migration eng082_h14_stage2_cutoff_reads_one_home, record sql/eng082_h14_stage2_cutoff_reads_one_home.sql;
-- ORDERING-CANON A5, -REGISTERS H14 item 14; scope Pieter RULING 2026-09-10: the placement derivation and its VERIFY
-- bind DC routes only). The bound is unchanged. Where no pair clears the evidence floor, a DC route reads the ONE
-- placement home, rpc_derive_placement_day, in place of the modal +/-1 set this function carried, and a direct or
-- dropship route takes order_cutoff_floor_days (2, RULING) with no placement weekday binding. VERIFY on a direct route
-- only where the ledger holds too few dated placements to derive a lead at all (ENG-110 add.2, the SAB rows).
-- R22 at ship, all 21 calendar rows: five direct cutoffs move to the floor (10116 Coca-Cola 3, 10116 Simba 3, 21355
-- Coca-Cola 3, 80175 Clover 5, 80175 Simba 3), every DC cutoff holds on demonstrated_pair_lead, the placement VERIFY
-- drops at 10116 Clover, 80175 Clover and 80175 Coca-Cola, and 80579 SAB carries the lead VERIFY. The three
-- floor_attested rows are not rewritten: the writer still skips them (ENG-160), and removing that skip is ENG-110
-- add.2 step 1. Offered dates and caches: BUG-LOG ENG-082 addendum 12.
--
-- THE ENG-048 HEADER BELOW IS LINEAGE (R28), true of the 2026-08-30 body and kept as written.
--
-- REPLACED FROM LIVE 2026-08-30 (ENG-115 class rule). The previous file was
-- hand-authored and still described the RETIRED typed `placement_dows` seed, so
-- it could never have been hash-gated -- only replaced. Gated in the same pass.
--
-- Migration that shaped the current body:
--   eng048_placement_dows_derived_from_ledger (2026-08-30)
--
-- ENG-048 (widened) / ORDERING-CANON §A5 v1.14 / SB-PM-RULING-002.
--
-- WHAT CHANGED. `unnest(ARRAY[1,2])` -- a typed Mon/Tue placement-day seed -- is
-- GONE. It sat in the `base` CTE under a comment reading *"the bounded fallback:
-- placement_dows (v9 7l, direct+dropship Mon/Tue)"* while v9 item 7l's own last
-- sentence reads **"No date/day literal in any function."** The comment cited the
-- rule the code beneath it broke. No `placement_dows` object has ever existed.
--
-- ⚠️ IT WAS NOT PROSE, IT WAS WIRED -- on 8 of 20 routes, not 7. Measured at
-- source 2026-08-30: SEVEN rows on `(no derivable pair)` plus ONE on `(6a
-- fallback)` = 8 of 20 = 40%. Canon §A5 says n=8 and is right; a 7/35% figure in
-- circulation is one route light. The count matters because it IS the population
-- the ruling weighed.
--
-- THE DECIDING FACT: `no derivable pair` means the order->GRV PAIR is missing,
-- NOT the placement day. Those routes carry 26-60 observed placements. The engine
-- typed a guess where the ledger could have told it the answer.
--
-- THE DERIVATION. `extract(isodow from sigma_orders.order_date)` per route, over
-- the same `in_transit_lead_window_days` window the pair leg already uses. The
-- modal day plus its +/- `dow_tolerance_days` scatter, and the share of placements
-- inside that set must clear `dow_confidence_min` (60) -- the SAME floor and
-- tolerance the delivery dow has used since v9 item 7i. **No new config key and no
-- new table: the derivation and its floor were already law, and the literal was
-- the whole defect.**
--
-- ⚠️ `sigma_orders` IS HEADER GRAIN -- verified, not assumed: 5,495 rows against
-- 5,495 distinct (store, order_nr), 1.00 rows per order. One row is one placement.
-- Counting order LINES here would inflate every confidence share it computes.
--
-- ⚠️ THE BELOW-FLOOR ROUTE KEEPS ITS CUTOFF AND IS FLAGGED. IT IS NEVER NULLED,
-- AND THIS IS THE LOAD-BEARING DESIGN DECISION IN THE FILE. `rpc_bloom_next_
-- deliveries` reads this column through `COALESCE(v_cutoff, 2)` at THREE sites, so
-- a NULL would not surface VERIFY -- it would silently substitute the literal 2
-- that ENG-048 exists to retire, moving the guess out of a visible column and into
-- a default nobody can see. Flagging beats nulling wherever a consumer defaults.
--
-- R22 AT SHIP, all 20 routes, before -> after in DAYS:
--   19 of 20 unchanged. Delivery date moved on ZERO of 20 desks.
--   Five routes newly carry a flag: four VERIFY + the pre-existing 6a anomaly.
--   On the four routes clearing both gates the DERIVED cutoff equalled the TYPED
--   one exactly (3=3, 1=1, 3=3, 3=3) -- the literal was right everywhere it was
--   checkable and unknowable everywhere else. The win here is honesty, not
--   accuracy: four routes stop asserting a number they cannot support.
--
-- ⚠️ ONE ROUTE DID MOVE, AND IT IS NOT THIS CHANGE: 10116 DC_AMBIENT 2 -> 3 days
-- (placement deadline 2026-08-27 -> 2026-08-26). Its basis is `demonstrated_pair_
-- lead` on BOTH sides -- a leg this work did not touch. Proven at source: the row
-- was last written 2026-07-28, the median pair lead was 2 as at 2026-07-31 and has
-- been 3 since at least 2026-08-16. The stored value was 33 days stale. This
-- change did not move it; it EXPOSED it.
--
-- 🔴 ROOT CAUSE OF THAT STALENESS, FILED NOT FIXED: `refresh_supplier_calendar_
-- cutoff` is on NO schedule. `refresh_l2_pipeline` contains zero references to
-- `supplier_calendar` (verified by line sweep). The cutoff is derived by hand and
-- then rots -- the `l2_last_counted` class again. Wiring it to the nightly chain
-- is its own ship under the ordering freeze, not a rider here.

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

-- The WRITER, live 9065b882. It writes every derived row except one whose order_cutoff_basis starts
-- floor_attested (ENG-160), where it appends a divergence note and never the value. ENG-110 add.2 step 1 removes
-- that skip; not yet done. `order_cutoff_seeded_prior` is the lineage column (R28): written once and never
-- overwritten twice, so the original seed stays recoverable after any number of re-derivations.
CREATE OR REPLACE FUNCTION public.refresh_supplier_calendar_cutoff(p_store_code text, p_route_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_moved int; v_anom int;
BEGIN
  UPDATE supplier_calendar c
     SET order_cutoff_seeded_prior = COALESCE(c.order_cutoff_seeded_prior, c.order_cutoff_days), -- lineage, never overwritten twice
         order_cutoff_days    = d.cutoff_days,
         order_cutoff_basis   = d.basis,
         order_cutoff_anomaly = d.anomaly,
         source_note = COALESCE(c.source_note,'')
           || format(' | cutoff derived %s: %s = %s day(s), basis %s, pairs %s, dow_lead %s, seeded prior %s (canon s14 v15 rule 6/6a).',
                     CURRENT_DATE, c.route_key, d.cutoff_days, d.basis, d.pairs_observed, d.dow_lead_days,
                     COALESCE(c.order_cutoff_seeded_prior, c.order_cutoff_days)),
         updated_at = now()
    FROM public.rpc_derive_order_cutoff(p_store_code, p_route_key) d
   WHERE c.store_code = d.store_code AND c.route_key = d.route_key
     -- ENG-160: an attested cutoff is a RULING (R28 evidence class), not a
     -- derivation, and a derivation may not overwrite it. Divergence is
     -- surfaced by the statement below, never enacted here.
     AND COALESCE(c.order_cutoff_basis, '') NOT LIKE 'floor_attested%';
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  -- ENG-160: the attested rows are skipped above. Where the derivation now
  -- DISAGREES with what was attested, say so on the row: both numbers, the
  -- basis the derivation reached, and the date. Never rewrite the value.
  UPDATE supplier_calendar c
     SET source_note = COALESCE(c.source_note,'')
           || format(' | %s DERIVATION DIVERGES from the attested cutoff: derived %s day(s) (basis %s) against the attested %s. Attestation STANDS and is not overwritten (ENG-160). Re-attest or clear the floor_attested basis if the ledger has genuinely moved.',
                     CURRENT_DATE, d.cutoff_days, d.basis, c.order_cutoff_days),
         updated_at = now()
    FROM public.rpc_derive_order_cutoff(p_store_code, p_route_key) d
   WHERE c.store_code = d.store_code AND c.route_key = d.route_key
     AND COALESCE(c.order_cutoff_basis, '') LIKE 'floor_attested%'
     AND d.cutoff_days IS DISTINCT FROM c.order_cutoff_days;
  SELECT count(*) INTO v_anom FROM supplier_calendar
   WHERE store_code=p_store_code AND order_cutoff_anomaly IS NOT NULL;
  RETURN jsonb_build_object('store_code', p_store_code, 'rows_written', v_moved,
                            'anomalies_flagged', v_anom, 'derived_on', CURRENT_DATE);
END;
$function$;

-- Grants stated explicitly and matching live (R30 addendum). The deriver is STABLE and writes nothing but is not a
-- browser surface, so anon is not granted; the writer is mutating, so PUBLIC and anon are both revoked.
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) TO service_role;
