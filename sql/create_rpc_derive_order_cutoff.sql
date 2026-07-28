-- rpc_derive_order_cutoff + refresh_supplier_calendar_cutoff
-- SB-CC-BLOOM-017 Wave 1 item 1.3, canon CLEANUP-ENGINE-CANON s14 ADDENDUM v15 rule 6 + 6a.
-- Effective 2026-07-28. Scope: formula GENERAL, constants DEMO_CALIBRATION (forge_config).
--
-- RULE 6  -- the order cutoff is DERIVED, never seeded. The route's own demonstrated
--            placement-to-GRV lead where the ledger carries real pairs; placement_dows
--            against delivery_dows (v9 item 7l) where it does not. The seeded literal 2
--            retires with lineage into supplier_calendar.order_cutoff_seeded_prior.
-- RULE 6a -- the anomaly is FLAGGED, never ENACTED (Pieter ruling 2026-07-28). Where the
--            derived cutoff is >= its own cycle length the desk could never order for the
--            NEXT delivery, so the value is not enacted: the bounded dow basis is used and
--            the row carries a flag naming the anomaly for a human to read (R29, R21 s4).
--            The model stops at useful. No further window or statistic tuning.
--
-- Minimum evidence before a route's own lead is trusted reuses in_transit_min_received_orders
-- rather than inventing a second threshold; the window reuses in_transit_lead_window_days.
--
-- Live derivation 2026-07-28, all 5 stores, 20 routes: 13 on demonstrated pair lead,
-- 7 on the dow basis, 1 anomaly flagged (10116 DIRECT_NATBRANDS, lead 8 on a weekly cycle,
-- fell back to 1). 17 of 20 cutoffs moved off the seeded 2; 8 desks' offered delivery dates
-- moved, every one LATER, none of them a desk delivering inside the current cutoff.

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
  route_of AS (
    SELECT o.store_code, o.order_date, o.grv_date, o.grv_nr,
           COALESCE((SELECT rc.route_key FROM bloom_route_config rc
                      WHERE rc.store_code=o.store_code AND o.supplier_nr=ANY(rc.direct_supplier_nrs) LIMIT 1),
                    CASE WHEN sc.supplier_class='DC' THEN 'DC' ELSE NULL END) AS route_family
    FROM sigma_orders o
    LEFT JOIN v_supplier_class sc ON sc.store_code=o.store_code AND sc.supplier_nr=o.supplier_nr
    WHERE o.store_code = p_store_code),
  base AS (
    SELECT c.store_code, c.route_key, c.delivery_dows, c.cycle_weeks, c.order_cutoff_days AS seeded,
           d.pairs, d.med_lead,
           -- the bounded fallback: placement_dows (v9 7l, direct+dropship Mon/Tue) against delivery_dows
           (SELECT min(((dd - pd) % 7 + 7) % 7)::smallint
              FROM unnest(c.delivery_dows) dd, unnest(ARRAY[1,2]) pd
             WHERE ((dd - pd) % 7 + 7) % 7 > 0) AS dow_lead
    FROM supplier_calendar c
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS pairs,
             percentile_disc(0.5) WITHIN GROUP (ORDER BY (r.grv_date - r.order_date))::smallint AS med_lead
      FROM route_of r, win
      WHERE r.order_date <> DATE '1990-01-01' AND r.order_date IS NOT NULL
        AND r.grv_nr <> 0 AND r.grv_date IS NOT NULL AND r.grv_date <> DATE '1990-01-01'
        AND r.grv_date >= r.order_date AND r.order_date >= CURRENT_DATE - win.d
        AND ((c.route_key LIKE 'DC%' AND r.route_family='DC')
          OR (c.route_key NOT LIKE 'DC%' AND r.route_family = c.route_key))
    ) d ON true
    WHERE c.store_code = p_store_code
      AND (p_route_key IS NULL OR c.route_key = p_route_key))
  SELECT b.store_code, b.route_key,
         CASE WHEN b.pairs >= (SELECT n FROM min_n)
                   AND b.med_lead <  b.cycle_weeks * 7 THEN b.med_lead      -- solid basis, inside its cycle
              ELSE b.dow_lead END AS cutoff_days,                            -- 6a fallback, and the no-pair route
         CASE WHEN b.pairs >= (SELECT n FROM min_n) AND b.med_lead < b.cycle_weeks * 7
                   THEN 'demonstrated_pair_lead'
              WHEN b.pairs >= (SELECT n FROM min_n)
                   THEN 'placement_dows_x_delivery_dows (6a fallback)'
              ELSE 'placement_dows_x_delivery_dows (no derivable pair)' END AS basis,
         CASE WHEN b.pairs >= (SELECT n FROM min_n) AND b.med_lead >= b.cycle_weeks * 7
              THEN format('ANOMALY: demonstrated lead %s days >= its own %s-week cycle, so the desk could never order for the NEXT delivery. Value NOT enacted (canon 6a); bounded dow basis used. Human read, not a calculation input.',
                          b.med_lead, b.cycle_weeks)
         END AS anomaly,
         b.med_lead, b.pairs, b.dow_lead, b.cycle_weeks, b.delivery_dows, b.seeded
  FROM base b ORDER BY b.route_key;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_derive_order_cutoff(text,text) TO authenticated;

-- The writer. Onboarding for store #6 is SELECT refresh_supplier_calendar_cutoff('<store>').
-- order_cutoff_seeded_prior is written ONCE (COALESCE guard) so the original seed survives
-- every later re-derivation -- R28 lineage, retired with a date and a successor, never deleted.
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

REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.refresh_supplier_calendar_cutoff(text,text) TO authenticated;

-- Columns this file depends on (added with it):
--   ALTER TABLE public.supplier_calendar ADD COLUMN IF NOT EXISTS order_cutoff_basis        text;
--   ALTER TABLE public.supplier_calendar ADD COLUMN IF NOT EXISTS order_cutoff_anomaly      text;
--   ALTER TABLE public.supplier_calendar ADD COLUMN IF NOT EXISTS order_cutoff_seeded_prior smallint;
