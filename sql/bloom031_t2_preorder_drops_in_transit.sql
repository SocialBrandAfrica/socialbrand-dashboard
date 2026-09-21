-- bloom031_t2_preorder_drops_in_transit.sql
--
-- MIGRATION (1) RETIRED 2026-09-21 19:4x, reversed byte-exact by sql/bloom031_tr_r1_reverse_t2.sql
-- (BLOOM-031 §T-R R1: a pre-order never counts in transit). Migration (2) stands.
--
-- SB-CC-BLOOM-031 §T2, applied 2026-09-21 ~13:40 SAST (Pieter: "the fix is the live state").
-- Two migrations, both asserted replace() on the live body with pinned md5, dry-run first as
-- pg_temp copies (control vs patched) on all five stores, zero live writes in the dry run.
--
-- (1) bloom031_t2_preorder_drops_in_transit -- refresh_l2_on_order
--     pin before d6655346f5d8c6cf889161fbbc031b7c, after 9c6e6ad85e6370c4d4fd6471a8043368 (12,542 b).
--     A promotion pre-order drop (order_type '2') still ahead of the ledger watermark, and not dated
--     before its own order, is never superseded and never expires on a lead estimate. It lands on its
--     own drop date and counts in transit when that date is on or before the store's next DC delivery
--     (rpc_bloom_next_deliveries on the store's DC route). A drop the ledger has passed keeps its old
--     verdict (not counted): Pieter 21-09, "past due is 1 and maybe 2 deliveries missed".
--     Dry run (control vs patched): 80175 +1,789 units on 74 products (#89906 59/59, #89908 15/15),
--     10116 +3,375 on 120 (#166828 120/120), 80176 0, 80579 0 qty (12 landings move to their drop
--     date), 21355 -72 on 1 (a 30-09 drop no longer counts against the 24-09 delivery). No other move.
--
-- (2) bloom031_t2_gear_path_counts_in_transit -- rpc_bloom_order_recipe
--     pin before c085128d9b767e471bf4d4d05924db22, after f6a4c5fc8e9e2cc291e41b35b343e112 (45,316 b).
--     The geared (promo) projection never added the counted on-order quantity the normal projection
--     adds, so a promo line re-suggested what was already in transit. needc now carries
--     oo_counted_qty and geared_calc adds it. Only promo-geared lines read geared_calc.
--     Dry run: 80175 23-09 387 -> 330 packs (R100,495 -> R81,761), 10116 24-09 1,308 -> 1,186
--     (R263,858 -> R238,755); 0 lines up, 0 normal_packs moved, 0 changes on a line without counted
--     transit. #89906's lines on the 80175 sheet: 24 -> 7 packs, 12 -> 6 lines with a quantity.
--
-- Caches rebuilt 21-09 13:4x on f6a4c5fc: 80175 DC_AMBIENT 23-09 (1542 unfitted, 1543 fitted),
-- 10116 DC_AMBIENT 24-09 (1544, 1545). The other desks pick both up at the nightly build.
-- The applied text follows, exactly as sent.

-- ===== migration (1) =====
DO $mig$ DECLARE d text; v_new text; o text; r text; BEGIN
  d := pg_get_functiondef('public.refresh_l2_on_order'::regproc);
  IF md5(d) <> 'd6655346f5d8c6cf889161fbbc031b7c' THEN RAISE EXCEPTION 'pin moved: %', md5(d); END IF;
  v_new := d;

  -- (1) declare the horizon
  o := $o$v_exc_n integer; v_exc_cost numeric; v_watermark date; v_est_past integer;$o$;
  r := $r$v_exc_n integer; v_exc_cost numeric; v_watermark date; v_est_past integer;
  v_horizon date;$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 1 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (2) the horizon: the store's next DC delivery, cutoff-respecting, from the same reader the desk uses
  o := $o$  SELECT count(*) INTO v_recv_in_open$o$;
  r := $r$  -- SB-CC-BLOOM-031 T2 (2026-09-21, Pieter: "the fix is the live state"). A promotion
  -- pre-order drop (order_type '2') counts in transit only up to the store's next DC delivery,
  -- the sheet the buyer is working. A DC route is a supplier_calendar route with no
  -- bloom_route_config row, the same test rpc_bloom_promo_for_delivery uses.
  SELECT nd.delivery_date INTO v_horizon
  FROM supplier_calendar sc
  CROSS JOIN LATERAL rpc_bloom_next_deliveries(sc.store_code, sc.route_key, CURRENT_DATE) nd
  WHERE sc.store_code = p_store
    AND NOT EXISTS (SELECT 1 FROM bloom_route_config rc WHERE rc.store_code = sc.store_code AND rc.route_key = sc.route_key)
  ORDER BY nd.delivery_date LIMIT 1;

  SELECT count(*) INTO v_recv_in_open$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 2 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (3) the landing state reads the line's own landing date; the type-2 verdict
  o := $o$      CASE WHEN (p.order_date + p.lead_days) <  v_watermark THEN 'estimate_elapsed'
           WHEN (p.order_date + p.lead_days) =  v_watermark THEN 'estimate_due_now'
           ELSE 'estimate_ahead' END AS landing_estimate_state,
      CASE
        WHEN NOT p.is_latest_of_kind THEN 'superseded_older_delivery'$o$;
  r := $r$      CASE WHEN (CASE WHEN p.order_type = '2' AND p.expected_grv_date > v_watermark AND p.expected_grv_date >= p.order_date
                      THEN p.expected_grv_date ELSE p.order_date + p.lead_days END) <  v_watermark THEN 'estimate_elapsed'
           WHEN (CASE WHEN p.order_type = '2' AND p.expected_grv_date > v_watermark AND p.expected_grv_date >= p.order_date
                      THEN p.expected_grv_date ELSE p.order_date + p.lead_days END) =  v_watermark THEN 'estimate_due_now'
           ELSE 'estimate_ahead' END AS landing_estimate_state,
      -- SB-CC-BLOOM-031 T2: a type-2 drop still ahead of the ledger lands on its own drop date
      -- (Sigma's expected_grv_date), never on order_date + lead. Every other line keeps order_date + lead.
      (CASE WHEN p.order_type = '2' AND p.expected_grv_date > v_watermark AND p.expected_grv_date >= p.order_date
            THEN p.expected_grv_date ELSE p.order_date + p.lead_days END) AS landing_date,
      CASE
        -- SB-CC-BLOOM-031 T2 (ENG-212, engine half). A promotion pre-order drop still ahead of the
        -- ledger watermark (and not dated before its own order) is never superseded by an ordinary
        -- document and never expires on a lead estimate: it is in transit, landing on its drop date,
        -- when that date is on or before the next DC delivery. A drop the ledger has passed keeps
        -- the verdict it had before this branch: the ledger shows what arrived (rule 5a), and whether
        -- a late drop is still coming is the buyer's call (T4). Ordinary documents never reach this
        -- branch, so no ordinary number moves.
        WHEN p.order_type = '2' AND p.expected_grv_date > v_watermark AND p.expected_grv_date >= p.order_date THEN CASE
             WHEN v_horizon IS NULL THEN 'preorder_no_dc_delivery_horizon'
             WHEN p.expected_grv_date > v_horizon THEN 'preorder_drop_after_next_dc_delivery'
             ELSE NULL END
        WHEN NOT p.is_latest_of_kind THEN 'superseded_older_delivery'$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 3 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (4) carry landing_date through the line grain
  o := $o$           j.landing_estimate_state, j.exclusion_reason, l.product_code,$o$;
  r := $r$           j.landing_estimate_state, j.exclusion_reason, l.product_code, j.landing_date,$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 4 count'; END IF;
  v_new := replace(v_new, o, r);

  o := $o$WHERE l.ordered_qty > 0 GROUP BY 1,2,3,4,5,6,7,8,9,10$o$;
  r := $r$WHERE l.ordered_qty > 0 GROUP BY 1,2,3,4,5,6,7,8,9,10,11$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 5 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (6) the product's landing is the earliest counted landing
  o := $o$MIN(order_date + lead_days) FILTER (WHERE exclusion_reason IS NULL),$o$;
  r := $r$MIN(landing_date) FILTER (WHERE exclusion_reason IS NULL),$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 6 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (7) engine version, both sites
  o := $o$'l2_on_order v17 E2.1 + ENG-188 landing estimate expires'$o$;
  r := $r$'l2_on_order v18 E2.1 + ENG-188 + BLOOM-031 T2 preorder drops in transit'$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 2 THEN RAISE EXCEPTION 'site 7 count'; END IF;
  v_new := replace(v_new, o, r);

  -- (8) report the horizon
  o := $o$'store_code', p_store, 'rows', v_rows, 'ledger_watermark', v_watermark,$o$;
  r := $r$'store_code', p_store, 'rows', v_rows, 'ledger_watermark', v_watermark, 'dc_delivery_horizon', v_horizon,$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site 8 count'; END IF;
  v_new := replace(v_new, o, r);
  EXECUTE v_new;
END $mig$;

-- ===== migration (2) =====
DO $mig$ DECLARE d text; v_new text; o text; r text; BEGIN
  d := pg_get_functiondef('public.rpc_bloom_order_recipe'::regproc);
  IF md5(d) <> 'c085128d9b767e471bf4d4d05924db22' THEN RAISE EXCEPTION 'pin moved: %', md5(d); END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_bloom_order_recipe') <> 1 THEN RAISE EXCEPTION 'overloads present'; END IF;
  v_new := d;
  o := $o$        GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s + COALESCE(oo.on_order_qty,0) AS proj,$o$;
  r := $r$        GREATEST((CASE WHEN t.band_blocked AND t.soh_raw < 0 THEN 0 ELSE t.soh_raw END),0) - t.ros_final * %9$s + COALESCE(oo.on_order_qty,0) AS proj,
        COALESCE(oo.on_order_qty,0) AS oo_counted_qty,$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site A count'; END IF;
  v_new := replace(v_new, o, r);
  o := $o$        GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s AS proj_geared,$o$;
  r := $r$        GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s + wg.oo_counted_qty AS proj_geared,$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site B count'; END IF;
  v_new := replace(v_new, o, r);
  o := $o$         ELSE GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s), 0)$o$;
  r := $r$         ELSE GREATEST(wg.target_level - (GREATEST(wg.soh_used,0) - (wg.ros_final*wg.gear) * %9$s + wg.oo_counted_qty), 0)$r$;
  IF (length(v_new) - length(replace(v_new, o, ''))) / length(o) <> 1 THEN RAISE EXCEPTION 'site C count'; END IF;
  v_new := replace(v_new, o, r);
  EXECUTE v_new;
END $mig$;
