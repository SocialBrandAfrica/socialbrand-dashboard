-- eng082_relay005_f1b_promo_buyin_lead.sql
--
-- RELAY-005 DEFECT 1 -- THE PROMO BUY-IN WINDOW. F1b.
-- ⚠️ NOT YET APPLIED. The DB write was refused by the harness classifier on
--    2026-09-09; this file is the reviewed, measured form, ready to apply.
--
-- ============================================================================
-- TWO CORRECTIONS TO THE BRIEF, BOTH VERIFIED AT SOURCE, AND THEY MAKE THIS
-- SMALLER AND THE DoD HARDER
-- ============================================================================
--
-- CORRECTION 1 -- IT IS NOT A LITERAL IN THE RECIPE, SO NO DEPLOY IS NEEDED.
-- The brief says: "promo_buyin_lead_days is not in forge_config at all -- it's a
-- literal in the recipe, which is why nobody could change it without a deploy."
-- Read at source: `rpc_bloom_order_recipe` does
--     SELECT sc.delivery_dows, sc.promo_buyin_lead_days INTO v_dows, v_buyin_lead_days
--       FROM supplier_calendar sc WHERE ...
-- It is a PER-ROUTE COLUMN on `supplier_calendar`, already documented in
-- DB-SCHEMA, currently 7 on all 20 routes. **An UPDATE changes it. No deploy, no
-- migration, no code change.** A forge_config key is therefore NOT required and
-- is not created here -- adding one would give the value two homes (§0g).
--
-- CORRECTION 2 -- THE GATE KEYS ON THE DELIVERY DATE, NOT ON TODAY.
-- The brief argues from "today is 13 days before RI4 starts". The recipe gates on
--     p_delivery_date >= promo.start_date - promo_buyin_lead_days
-- so what matters is the delivery being ordered for. Measured for 491 @ 80175
-- (DC_AMBIENT delivers Wed + Sat), RI4 starting 2026-09-22:
--     lead  7 -> first admitted delivery 2026-09-16 (Wed)
--     lead 14 -> first admitted delivery 2026-09-12 (Sat)
-- **So the defect bites the SATURDAY 12-09 delivery and not the Wednesday one.**
-- If tomorrow's order targets Sat 12-09, lead 7 excludes RI4 and lead 14 admits
-- it. If it targets Wed 16-09, lead 7 ALREADY admits it and nothing was broken.
-- That is a narrower and more precise statement than the brief's, and it is the
-- one that decides the value.
--
-- ============================================================================
-- THE VALUE, AND IT IS A SEED -- SAID PLAINLY (§0h point 2)
-- ============================================================================
-- It CANNOT be derived from our data. ENG-082 B1/B2 already records that Sigma's
-- promotion-ORDER window ("Deadline for Order") is NOT EXTRACTED. Canon §C2 says
-- the same: the absence is in OUR FEED. So any number here is chosen, not derived.
--
-- CHOSEN: 14. Stated with its reason rather than picked silently --
--   * 14 is the MINIMUM that admits RI4 for the imminent Sat 12-09 delivery
--     (measured above). 13 would also do it; 14 gives one day of margin and
--     matches the "about a fortnight" the DC window is described as.
--   * It is not larger than needed. A bigger lead shows the buyer promo pricing
--     for stock they cannot yet order and gears quantities on it.
-- STAMPED **SEED, UNDERIVED**, DEMO_CALIBRATION, exactly like its four
-- in_transit_* siblings. The successor is F1a: extract Sigma's own order-window
-- field and match on it, after which this seed retires (R28).
--
-- ============================================================================
-- 🔴 THIS ALONE DOES NOT MEET THE DoD, AND THAT MUST BE SAID BEFORE IT SHIPS
-- ============================================================================
-- The DoD is "491 appears on the promo sheet AT THE RI4 PROMO COST".
-- Measured at source: **every RI4 row carries list_cost = 0.0000.** Both RI4 rows
-- are status '0' (skeleton). The completed RG4 and RH4 rows at status '2' carry
-- list_cost 15.9567. A future promo has NO payload row yet, so the cost does not
-- exist in the mirror at all.
--
-- **So lead 14 puts 491 ON the promo sheet, at cost ZERO, not at the RI4 cost.**
-- No code change can conjure it: this is canon §C2's known extraction debt
-- (`promo_cost_delta`, R23 §1), not a defect in the recipe.
--
-- What the sheet should do instead, and it needs a PM ruling before it is built:
-- show the line with its promo flag and its SELL price (19.99, which IS present),
-- and label the cost as NOT YET PUBLISHED BY THE DC -- with the last completed
-- promo cost (R15.9567, RG4 and RH4, both identical) shown as a LABELLED
-- REFERENCE, never as this promo's cost. A zero there is a false statement about
-- money and a silent fallback to the last cost is worse (R22 §3, R29).
--
-- ============================================================================
-- APPLY
-- ============================================================================
-- R22 after applying: re-generate the 80175 DC_AMBIENT order for delivery
-- 2026-09-12 and confirm 491 is present with promo_active true. Confirm the
-- other 19 routes are unchanged for a delivery inside their own 7-day window.

UPDATE supplier_calendar
   SET promo_buyin_lead_days = 14,
       source_note = COALESCE(source_note,'')
         || ' | promo_buyin_lead_days 7->14 2026-09-09 (RELAY-005 F1b, ENG-082):'
         || ' SEED, UNDERIVED, DEMO_CALIBRATION. 14 is the minimum that admits a'
         || ' DC month-end promo for the imminent delivery (measured on 491@80175,'
         || ' RI4 start 2026-09-22: lead 7 admits only from Wed 16-09, lead 14 from'
         || ' Sat 12-09). Sigma order-window field NOT extracted (ENG-082 B1/B2),'
         || ' so this cannot be derived. Successor: F1a, then retire this seed.'
 WHERE promo_buyin_lead_days = 7;

-- Proof the write did what it says, and nothing else moved.
DO $check$
DECLARE n_14 int; n_other int;
BEGIN
  SELECT count(*) FILTER (WHERE promo_buyin_lead_days = 14),
         count(*) FILTER (WHERE promo_buyin_lead_days <> 14)
    INTO n_14, n_other FROM supplier_calendar;
  RAISE NOTICE 'promo_buyin_lead_days: % routes at 14, % routes at another value', n_14, n_other;
  IF n_14 <> 20 THEN
    RAISE WARNING 'expected 20 routes at 14 -- re-read supplier_calendar before trusting the promo sheet';
  END IF;
END $check$;
