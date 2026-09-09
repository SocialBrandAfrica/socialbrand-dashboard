-- eng091_relay005_f2_promise_aware_transit.sql
--
-- RELAY-005 DEFECT 2 -- GOODS IN TRANSIT. F2a + F2b, and they are ONE cascade change.
-- ⚠️ NOT YET APPLIED. The DB write was refused by the harness classifier on
--    2026-09-09; this file is the reviewed, measured form, ready to apply.
--
-- ============================================================================
-- WHAT THE BRIEF GOT RIGHT, AND THE ONE PLACE IT IS WRONG
-- ============================================================================
-- RIGHT: l2_on_order reports 0 for product 491 @ 80175 while units are genuinely
-- coming. Verified at source: on_order_qty = 0.0000, open_order_count = 0.
-- The seven orders in the brief's table reproduce EXACTLY.
--
-- WRONG, and it changes what to build: the brief says the supersede rule is the
-- cause and lists F2a first. Rule 1 ALREADY carries an escape hatch --
--     NOT (expected_grv_date >= watermark AND age_days <= lead_days * mult)
-- -- so a forward-dated order is meant to survive it. Measured at source, the
-- hatch is closed by the SECOND half, not the first:
--     lead_days = 2 (route median, n=401, well founded) x in_transit_lead_multiple 2
--     = a 4-DAY BOUND.
-- The six programme orders were placed 2026-09-01, so age_days = 8. 8 > 4.
--
-- PROVEN by evaluating the live cascade per order: fixing the supersede rule
-- ALONE moves ranks 2-7 from 'cancelled_superseded' to 'stale_beyond_lead'.
-- THEY STAY EXCLUDED. F2a on its own delivers ZERO units on this line.
-- The binding constraint is age-vs-lead, which the brief ranked third (F2c).
--
-- THE STRUCTURAL POINT: `age_days > lead * mult` conflates "this document is
-- stale" with "this delivery is scheduled far ahead". A DC programme books six
-- deliveries out to seven weeks on one day. Age says stale; the promise says
-- 16-09, 23-09, 30-09, 14-10, 21-10, 28-10. The promise is the better witness
-- and it is already in the row.
--
-- ============================================================================
-- THE RULE, three parts
-- ============================================================================
-- 1. A promise that is ABSENT, sentinel (1990-01-01), or dated BEFORE its own
--    order is PATHOLOGICAL. It discredits the DATE, never the stock (F2b).
--    Fall back to age-vs-lead, which is what the date was standing in for.
--    `promise_basis` still records 'promise_before_own_order_date', so the date
--    is flagged rather than trusted -- the flag was always the right output,
--    dropping the quantity never was.
-- 2. A CREDIBLE FORWARD promise (> ledger watermark) says when it lands. It is
--    neither stale nor superseded.
-- 3. Supersession SURVIVES and is not deleted -- the brief is right that the
--    double-count risk is real. It now partitions on the PROMISED DELIVERY as
--    well, so a genuine re-send of the SAME delivery is still dropped while a
--    programme of six different deliveries is not. Pathological and absent
--    dates share one bucket, so they still supersede each other by order_nr.
--
-- ============================================================================
-- R22 -- MEASURED WHOLE-POPULATION BEFORE WRITING, which is the gate PM set
-- ============================================================================
-- "Say how much of the rise is genuine programme stock and how much is old
--  documents the supersede rule was right to drop. Do not trade a gate that
--  never fires for one that always does."
--
--  store | on_order now | proposed |  rise | of which forward-promise | discredited-date
--  10116 |       24,699 |   52,039 | +27,340 |            18,058       |     9,282
--  80175 |       12,901 |   50,557 | +37,656 |            29,868       |     7,788
--  80176 |        2,303 |    2,303 |       0 |                 0       |         0
--  21355 |            0 |        0 |       0 |                 0       |         0
--  80579 |            0 |      405 |    +405 |                 0       |       405
--
-- AND WHAT STAYS OUT, which is the half that proves the gate still discriminates:
--  2,343,104 units group-wide remain excluded as 'promise_passed_ledger_observed'
--  (the promised date came and the ledger never saw the truck) plus
--  2,025,-odd thousand as 'stale_age' where there is no usable promise at all.
--  10116 keeps 1,540,307 + 619,616 out. 80175 keeps 755,631 + 305,364 out.
--
-- ⚠️ THE BRIEF'S "151,303 units invisible / 78.6%" AT 80175 IS NOT THE
--    RECOVERABLE FIGURE. It counts everything excluded, including years of dead
--    paperwork. The honest recoverable number is 37,656 units -- about a QUARTER
--    of what the brief implies. Stated here so nobody sizes a decision on 151,303.
--
-- ON THE NAMED LINE, product 491 @ 80175:
--    3,600 (rank 1, date discredited) + 486 (six forward-promise deliveries)
--    = 4,086 units counted; 11,760 stale + 5,346 past-promise correctly stay out.
--
-- ⚠️ THE BRIEF'S DoD SAYS 3,986. THE MEASURED FIGURE IS 4,086 -- 100 UNITS MORE.
--    Judge the screen against 4,086.
--
-- ============================================================================
-- R30 DEPENDENTS, warned
-- ============================================================================
-- `rpc_bloom_order_recipe` reads l2_on_order for projected_soh, so ORDERING
-- QUANTITIES MOVE ON EVERY DESK when this lands (ENG-155). They move DOWN --
-- more visible in-transit means less need. `bloom_order_cache` / `_line` must be
-- rebuilt after. ENG-061's landed + in-transit money book reads it.
-- `SB-AP-BUDGET-002` is unaffected: it reads GRV receipts, not on-order.
--
-- AFTER APPLYING, in order:
--   SELECT refresh_l2_on_order('80175');   -- and each other store
--   SELECT on_order_qty, open_order_count FROM l2_on_order
--    WHERE store_code='80175' AND product_code=491;   -- expect 4086 / 7
--   SELECT refresh_bloom_order_cache_all();           -- rebuild the desks
-- ============================================================================

DO $patch$
DECLARE src text; out text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname='public' AND p.proname='refresh_l2_on_order';
  IF src IS NULL THEN RAISE EXCEPTION 'refresh_l2_on_order not found'; END IF;

  -- PATCH 1 -- supersession partitions on the promised delivery as well.
  out := replace(src,
    $q$PARTITION BY r.store_code, r.supplier_nr, op.delivery_population$q$,
    $q$PARTITION BY r.store_code, r.supplier_nr, op.delivery_population, CASE WHEN r.expected_grv_date IS NULL OR r.expected_grv_date = DATE '1990-01-01' OR r.expected_grv_date < r.order_date THEN NULL ELSE r.expected_grv_date END$q$);
  IF out = src THEN RAISE EXCEPTION 'patch 1 (partition) did not apply'; END IF;
  src := out;

  -- PATCH 2 -- the exclusion cascade. A bad date discredits the DATE, not the stock.
  out := regexp_replace(src,
    $q$WHEN NOT p\.is_latest_of_kind.*?ELSE NULL END AS exclusion_reason$q$,
    $q$WHEN p.expected_grv_date IS NULL OR p.expected_grv_date = DATE '1990-01-01' OR p.expected_grv_date < p.order_date
          THEN CASE WHEN NOT p.is_latest_of_kind THEN 'cancelled_superseded'
                    WHEN p.age_days > p.lead_days * v_mult THEN 'stale_beyond_lead'
                    ELSE NULL END
        WHEN p.expected_grv_date > v_watermark
          THEN CASE WHEN NOT p.is_latest_of_kind THEN 'cancelled_superseded' ELSE NULL END
        ELSE 'promise_passed_ledger_observed' END AS exclusion_reason$q$,
    'sn');
  IF out = src THEN RAISE EXCEPTION 'patch 2 (cascade) did not apply'; END IF;

  EXECUTE out;
  RAISE NOTICE 'refresh_l2_on_order patched: promise-aware transit (RELAY-005 F2a+F2b)';
END $patch$;
