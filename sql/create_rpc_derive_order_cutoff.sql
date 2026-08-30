-- create_rpc_derive_order_cutoff.sql
--   public.rpc_derive_order_cutoff        -- derives the cutoff (STABLE, writes nothing)
--   public.refresh_supplier_calendar_cutoff -- writes it onto supplier_calendar
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
  WITH min_n AS (SELECT value_num::int AS n FROM forge_config
                  WHERE config_key='in_transit_min_received_orders' AND store_format='*' AND retired_on IS NULL),
  win AS (SELECT value_num::int AS d FROM forge_config
           WHERE config_key='in_transit_lead_window_days' AND store_format='*' AND retired_on IS NULL),
  -- the SAME confidence floor and scatter tolerance the delivery dow already uses
  -- (canon A5 v9 item 7i). No new config key: the derivation and its floor are
  -- already law, and the literal was the whole defect.
  conf AS (SELECT value_num::numeric AS c FROM forge_config
            WHERE config_key='dow_confidence_min' AND store_format='*' AND retired_on IS NULL),
  tol AS (SELECT value_num::int AS t FROM forge_config
           WHERE config_key='dow_tolerance_days' AND store_format='*' AND retired_on IS NULL),
  route_of AS (
    SELECT o.store_code AS s, o.order_date AS od, o.grv_date AS gd, o.grv_nr AS gn,
           COALESCE((SELECT rc.route_key FROM bloom_route_config rc
                      WHERE rc.store_code=o.store_code AND o.supplier_nr=ANY(rc.direct_supplier_nrs) LIMIT 1),
                    CASE WHEN sc.supplier_class='DC' THEN 'DC' ELSE NULL END) AS route_family
    FROM sigma_orders o
    LEFT JOIN v_supplier_class sc ON sc.store_code=o.store_code AND sc.supplier_nr=o.supplier_nr
    WHERE o.store_code = p_store_code),
  -- ============ THE DERIVED PLACEMENT DAY (SB-PM-RULING-002) ============
  -- Directly observable: extract(isodow from sigma_orders.order_date) per route.
  -- sigma_orders is HEADER grain (verified: 5,495 rows = 5,495 distinct orders),
  -- so one row is one placement -- counting lines would inflate every share.
  plc AS (
    SELECT cc.store_code AS s, cc.route_key AS rk, extract(isodow from r.od)::int AS dw
    FROM supplier_calendar cc
    JOIN route_of r ON r.s = cc.store_code
     AND ((cc.route_key LIKE 'DC%' AND r.route_family='DC')
       OR (cc.route_key NOT LIKE 'DC%' AND r.route_family = cc.route_key))
    WHERE cc.store_code = p_store_code
      AND (p_route_key IS NULL OR cc.route_key = p_route_key)
      AND r.od IS NOT NULL AND r.od <> DATE '1990-01-01'
      AND r.od >= CURRENT_DATE - (SELECT win.d FROM win)),
  plc_n AS (SELECT plc.s, plc.rk, plc.dw, count(*)::int AS n FROM plc GROUP BY 1,2,3),
  plc_tot AS (SELECT plc_n.s, plc_n.rk, sum(plc_n.n)::int AS total FROM plc_n GROUP BY 1,2),
  plc_modal AS (SELECT DISTINCT ON (plc_n.s, plc_n.rk) plc_n.s, plc_n.rk, plc_n.dw AS modal
                  FROM plc_n ORDER BY plc_n.s, plc_n.rk, plc_n.n DESC, plc_n.dw),
  -- the stable day plus its +/- dow_tolerance_days scatter, exactly as 7i treats
  -- delivery: the tolerance is logistics noise around ONE day, never a second day.
  plc_set AS (
    SELECT pm.s, pm.rk, pm.modal, pt.total,
           ARRAY(SELECT DISTINCT x.dw FROM plc_n x, tol
                  WHERE x.s=pm.s AND x.rk=pm.rk
                    AND LEAST((x.dw - pm.modal + 7) % 7, (pm.modal - x.dw + 7) % 7) <= tol.t
                  ORDER BY 1)::smallint[] AS dset,
           (SELECT COALESCE(sum(x2.n),0) FROM plc_n x2, tol
             WHERE x2.s=pm.s AND x2.rk=pm.rk
               AND LEAST((x2.dw - pm.modal + 7) % 7, (pm.modal - x2.dw + 7) % 7) <= tol.t)::int AS in_tol
    FROM plc_modal pm JOIN plc_tot pt ON pt.s=pm.s AND pt.rk=pm.rk),
  base AS (
    SELECT c.store_code AS s, c.route_key AS rk, c.delivery_dows AS ddows,
           c.cycle_weeks AS cyc, c.order_cutoff_days AS seeded,
           d.pairs, d.med_lead,
           ps.total AS placements, ps.dset, ps.modal,
           ROUND(100.0 * ps.in_tol / NULLIF(ps.total,0), 1) AS conf_pct,
           -- the lead off the DERIVED placement set against delivery_dows
           (SELECT min(((dd - pd) % 7 + 7) % 7)::smallint
              FROM unnest(c.delivery_dows) dd, unnest(ps.dset) pd
             WHERE ((dd - pd) % 7 + 7) % 7 > 0) AS dow_lead
    FROM supplier_calendar c
    LEFT JOIN plc_set ps ON ps.s = c.store_code AND ps.rk = c.route_key
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS pairs,
             percentile_disc(0.5) WITHIN GROUP (ORDER BY (r.gd - r.od))::smallint AS med_lead
      FROM route_of r, win
      WHERE r.od <> DATE '1990-01-01' AND r.od IS NOT NULL
        AND r.gn <> 0 AND r.gd IS NOT NULL AND r.gd <> DATE '1990-01-01'
        AND r.gd >= r.od AND r.od >= CURRENT_DATE - win.d
        AND ((c.route_key LIKE 'DC%' AND r.route_family='DC')
          OR (c.route_key NOT LIKE 'DC%' AND r.route_family = c.route_key))
    ) d ON true
    WHERE c.store_code = p_store_code
      AND (p_route_key IS NULL OR c.route_key = p_route_key)),
  flagged AS (
    SELECT b.*,
           (b.pairs >= (SELECT min_n.n FROM min_n) AND b.med_lead < b.cyc * 7)      AS pair_ok,
           (COALESCE(b.placements,0) >= (SELECT min_n.n FROM min_n)
             AND COALESCE(b.conf_pct,0) >= (SELECT conf.c FROM conf)
             AND b.dow_lead IS NOT NULL)                                            AS dow_ok
      FROM base b)
  SELECT f.s, f.rk,
         CASE WHEN f.pair_ok THEN f.med_lead
              WHEN f.dow_ok  THEN f.dow_lead
              -- Below floor or unevidenced: NOT enacted. The route KEEPS its
              -- current enacted cutoff and is flagged for a human. It is never
              -- nulled: rpc_bloom_next_deliveries reads this column through
              -- COALESCE(v_cutoff, 2), so a NULL would not surface VERIFY -- it
              -- would silently substitute the very literal 2 this work removes,
              -- moving the guess somewhere nobody can see it.
              ELSE f.seeded END::smallint AS cutoff_days,
         CASE WHEN f.pair_ok THEN 'demonstrated_pair_lead'
              WHEN f.dow_ok AND f.pairs >= (SELECT min_n.n FROM min_n)
                   THEN 'derived_placement_dow_x_delivery_dows (6a fallback)'
              WHEN f.dow_ok
                   THEN 'derived_placement_dow_x_delivery_dows (no derivable pair)'
              ELSE 'placement_dow_below_floor (VERIFY, not enacted)' END AS basis,
         NULLIF(concat_ws(' ',
           CASE WHEN f.pairs >= (SELECT min_n.n FROM min_n) AND f.med_lead >= f.cyc * 7
                THEN format('ANOMALY: demonstrated lead %s days >= its own %s-week cycle, so the desk could never order for the NEXT delivery. Value NOT enacted (canon 6a); derived placement-dow basis used. Human read, not a calculation input.',
                            f.med_lead, f.cyc) END,
           CASE WHEN NOT f.pair_ok AND NOT f.dow_ok THEN
                CASE WHEN COALESCE(f.placements,0) < (SELECT min_n.n FROM min_n)
                     THEN format('VERIFY: this route has no derivable placement day -- only %s placement(s) observed in the window, below the %s-order evidence floor. Cutoff %s day(s) is CARRIED, not derived, and is not evidence. Human read.',
                                 COALESCE(f.placements,0), (SELECT min_n.n FROM min_n), f.seeded)
                     ELSE format('VERIFY: no stable placement day. The modal day (isodow %s) with its +/-1 scatter accounts for only %s%% of %s placements, below the %s%% confidence floor. Cutoff %s day(s) is CARRIED, not derived, and is not evidence. Human read.',
                                 f.modal, f.conf_pct, f.placements, (SELECT conf.c FROM conf), f.seeded)
                END END), '') AS anomaly,
         f.med_lead, f.pairs, f.dow_lead, f.cyc, f.ddows, f.seeded
  FROM flagged f ORDER BY f.rk;
$function$;

-- The WRITER. Unchanged by ENG-048; included so the file carries both objects, as
-- it always has. `order_cutoff_seeded_prior` is the lineage column (R28) and is
-- written once and never overwritten twice, so the ORIGINAL literal-2 seed stays
-- recoverable after any number of re-derivations.
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
   WHERE c.store_code = d.store_code AND c.route_key = d.route_key;
  GET DIAGNOSTICS v_moved = ROW_COUNT;
  SELECT count(*) INTO v_anom FROM supplier_calendar
   WHERE store_code=p_store_code AND order_cutoff_anomaly IS NOT NULL;
  RETURN jsonb_build_object('store_code', p_store_code, 'rows_written', v_moved,
                            'anomalies_flagged', v_anom, 'derived_on', CURRENT_DATE);
END;
$function$;

-- Grants stated explicitly and matching live (R30 addendum). The deriver is STABLE
-- and writes nothing but is not a browser surface, so anon is not granted; the
-- writer is mutating, so PUBLIC and anon are both revoked.
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) TO service_role;
