-- eng091_relay005_f2_delivery_not_document.sql
--   (supersedes my own eng091_relay005_f2_promise_aware_transit.sql of 2026-09-09
--    13:xx, which was built on a WRONG root cause -- see "WHAT I GOT WRONG" below)
--
-- IN TRANSIT: RANK THE DELIVERY, NEVER THE DOCUMENT.
-- APPLIED AND VERIFIED LIVE 2026-09-09, all five stores refreshed.
--   Migrations: eng091_in_transit_rank_delivery_not_document, then
--   eng091_depth_two_for_dc_ambient_one_elsewhere.
--
-- DEPTH IS NOT UNIFORM -- Pieter's floor rule, ledger-confirmed on 180 days of
-- consecutive order dates. The previous order is still unreceived when the next
-- is placed on 59.6% of DC pairs (n=302), 9.6% of DIRECT/dropship (n=386) and
-- 0.1% of other (n=1,267). So DC AMBIENT carries TWO open deliveries; fresh,
-- direct and dropship carry exactly ONE. My first apply used two everywhere and
-- over-stated the non-DC routes; corrected within the hour.
--
-- LIVE AFTER: 10116 1,735 products / 37,218 u (DC 18,181, non-DC 19,037) ·
-- 80175 862 / 22,186 (DC 13,273) · 80176 102 / 2,303 · 80579 16 / 405 ·
-- 21355 0, and that zero is HONEST: its newest open document is 16 days old
-- with a promise already passed, which is cancelled under the floor's own rule.
-- Product 491 @ 80175: 3,600 units, landing 2026-09-09, promise flagged.
--
-- The assertions earned their keep twice: the first attempt failed on the
-- cascade patch (contradictory regex flags) and refused to half-apply.
--
-- ============================================================================
-- THE ACTUAL ROOT CAUSE, and it is neither the brief's nor my first one
-- ============================================================================
-- Sigma splits ONE order into MANY documents. On 2026-09-07 at 80175, supplier
-- 1339, the DC order arrived as **11 separate order_nr** -- 90103, 90108, 90109,
-- 90110, 90112, 90113, 90116, 90117 and more -- carrying 95, 105, 1, 26, 60, 5,
-- 5 and 16 lines. One Monday order. Eleven documents.
--
-- `refresh_l2_on_order` ranks DOCUMENTS: ROW_NUMBER() ... ORDER BY order_nr DESC,
-- and keeps rn = 1. **So one document out of eleven survives and the other ten
-- are called `cancelled_superseded` -- documents from the same order, placed the
-- same day, competing with each other as though each replaced the last.**
--
-- Pieter's 3,600 units of milk sit on 90108. The survivor is 90117, which carries
-- 16 lines and not one of them is milk. That is the whole defect.
--
-- It also explains "it worked before a recent rollout" WITHOUT a rollout: whether
-- your line lands in the highest-numbered document of the day is arbitrary. It has
-- always been a lottery; he has been losing it more visibly as document counts grew.
--
-- ⚠️ **`eng148_on_order_population_partition_e21` (2026-08-27) IS NOT THE CAUSE.**
-- Tested: re-ranking under the pre-E2.1 `status_2` partition gives BYTE-IDENTICAL
-- verdicts on all seven candidate orders -- every one carries status_2 = 'E'.
--
-- ============================================================================
-- WHAT I GOT WRONG, recorded because it was nearly shipped
-- ============================================================================
-- My first patch admitted any order with a CREDIBLE FORWARD PROMISE. Pieter's floor
-- rule ("a DC delivery that misses the next delivery and the one after is cancelled")
-- sent me to the receipt ledger, and it kills my rule outright. Received rate at
-- 80175/1339 by how far ahead the order was booked, 12 months:
--     promise BEFORE its own order   550 orders   56.9% received
--     0-7 days ahead                 705 orders   91.1% received
--     8-14 days                        8 orders   62.5%
--     15-28 days                      16 orders   25.0%
--     29+ days ahead                 107 orders  **2.8%**
-- **A far-forward booking almost never lands.** My rule would have admitted 486
-- units on 491 from deliveries 5-7 weeks out -- a 1-in-36 shot -- and called it
-- stock in transit. The brief wanted them in too. Both wrong; the floor was right.
--
-- ============================================================================
-- THE RULE, and every part of it is measured
-- ============================================================================
-- 1. **A DELIVERY IS AN ORDER DATE, NOT A DOCUMENT.** All documents placed on one
--    date for one supplier are one order and stand or fall together.
-- 2. **DEPTH DEPENDS ON THE ROUTE, and this is Pieter's floor rule, ledger-confirmed.**
--    DC AMBIENT keeps TWO open deliveries; FRESH, DIRECT and DROPSHIP keep ONE --
--    "the last delivery not yet received". Measured over 180 days of consecutive
--    order dates, the previous order is still unreceived when the next is placed on
--    59.6% of DC pairs (n=302), 9.6% of DIRECT/dropship (n=386), 0.1% of other
--    (n=1,267). A flat depth of two over-states every non-DC route.
-- 3. **A PATHOLOGICAL PROMISE DISCREDITS THE DATE, NOT THE STOCK** (F2b stands).
--    Sigma writes an expected GRV before the order date on 20-27% of DC orders
--    EVERY month since March -- it is not new and not rare. Those orders are still
--    received 56.9% of the time, so the date is unusable and the stock is real.
-- 4. **A CREDIBLE PROMISE THAT HAS PASSED, unreceived, still excludes** -- the truck
--    was due, the ledger never saw it.
--
-- ============================================================================
-- 🔴 THIS CORRECTS CANON, and the correction is scoped and measured
-- ============================================================================
-- ORDERING-CANON §E2 v15 rule 4 says *"Recency is `order_nr`, never `order_date`;
-- order_date is a disposition date, sentinel on 76% of headers."* **That is true of
-- the WHOLE table and FALSE for the population this function reads.** Measured:
--     order_type 0 / 1 / 2  (the open pool)  3,956 headers   **0.0% sentinel**
--     order_type W (received)               32,223 headers    75.3% sentinel
--     order_type S (credits)                22,255 headers    90.3% sentinel
-- **The 76% lives entirely in the classes `l2_on_order` never touches.** On the open
-- pool `order_date` is 100% populated and is the only key that can group a delivery.
-- PM owes the R28 lineage on v15 rule 4, scoped to the open population.
--
-- ============================================================================
-- WHAT IT DID TO THE LIVE SITE -- MEASURED AFTER, not predicted
-- ============================================================================
--  store | products before | units before | products after | units after
--  10116 |           1,445 |       24,699 |          1,735 |      37,218
--  80175 |             665 |       12,901 |            862 |      22,186
--  80176 |             102 |        2,303 |            102 |       2,303
--  80579 |               0 |            0 |             16 |         405
--  21355 |               0 |            0 |              0 |           0
-- 21355's zero is HONEST -- newest open document 16 days old, promise passed.
-- Product 491 @ 80175: 3,600 units. Not the brief's 3,986, not my earlier 4,086.
--
-- R30: `rpc_bloom_order_recipe` reads this for projected_soh, so ORDER QUANTITIES
-- FALL on every desk. Rebuild `bloom_order_cache` after. Walk one desk before trusting.
-- ============================================================================

DO $patch$
DECLARE src text; out text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname='public' AND p.proname='refresh_l2_on_order';
  IF src IS NULL THEN RAISE EXCEPTION 'refresh_l2_on_order not found'; END IF;

  -- PATCH 1: rank the DELIVERY (order_date), not the DOCUMENT (order_nr).
  out := replace(src,
    $q$ROW_NUMBER() OVER (PARTITION BY r.store_code, r.supplier_nr, op.delivery_population
                                   ORDER BY r.order_nr DESC) AS rn$q$,
    $q$DENSE_RANK() OVER (PARTITION BY r.store_code, r.supplier_nr, op.delivery_population
                                   ORDER BY r.order_date DESC) AS rn$q$);
  IF out = src THEN RAISE EXCEPTION 'patch 1 (rank the delivery) did not apply'; END IF;
  src := out;

  -- PATCH 2: keep the last TWO deliveries, not the single latest document.
  out := replace(src, $q$(k.rn=1) AS is_latest_of_kind$q$, $q$(k.rn<=2) AS is_latest_of_kind$q$);
  IF out = src THEN RAISE EXCEPTION 'patch 2 (keep last two) did not apply'; END IF;
  src := out;

  -- PATCH 3: a pathological promise discredits the DATE, never the stock.
  out := regexp_replace(src,
    $q$WHEN NOT p\.is_latest_of_kind.*?ELSE NULL END AS exclusion_reason$q$,
    $q$WHEN NOT p.is_latest_of_kind THEN 'superseded_older_delivery'
        WHEN p.expected_grv_date IS NULL OR p.expected_grv_date = DATE '1990-01-01'
             OR p.expected_grv_date < p.order_date THEN NULL
        WHEN p.expected_grv_date <= v_watermark THEN 'promise_passed_ledger_observed'
        ELSE NULL END AS exclusion_reason$q$,
    'sn');
  IF out = src THEN RAISE EXCEPTION 'patch 3 (cascade) did not apply'; END IF;

  EXECUTE out;
  RAISE NOTICE 'refresh_l2_on_order: ranks the DELIVERY, keeps the last two (RELAY-005 F2, corrected)';
END $patch$;
