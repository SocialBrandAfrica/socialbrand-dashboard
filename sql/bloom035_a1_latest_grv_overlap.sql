-- =============================================================================
-- BLOOM-035 ruling A1 (PM, 13-10-2026 21:55, inside Pieter's R7): WHEN MORE THAN ONE DESK RECEIVED A PRODUCT
-- IN THE CURRENT REGIME, THE DESK WHOSE SUPPLIER DELIVERED IT LATEST OWNS IT. The DC-preferred clause of
-- ORDERING-CANON SSA2 is retired (R28, retired_on 2026-10-13, PM's canon edit). A same-day tie still goes to DC.
--
-- WHAT CHANGES, in refresh_l2_population_verdict only (the one function that ever read it, checked against
-- every body in pg_proc 14-10-2026):
--   1. the overlap ranking loses `(rc.rcpt_desks IS NOT NULL AND p.is_dc) DESC`, so `desk_last DESC` decides
--      among the desks that receipted the product in the window;
--   2. the label DC_PREFERRED becomes LATEST_RECEIPT;
--   3. the comment above the rule and the column comment say so; the engine version string moves to v2.3.
-- Nothing else in the 20,062-character body moves. Applied as an ASSERTED REPLACE on the live definition (each
-- anchor must occur exactly once or the whole migration raises).
--
-- THE RECOUNT THE RULING ASKED FOR (14-10-2026 00:5x SAST, DEDUCTIVE on the whole overlap population, read from
-- sigma_movements R/W DIWAREPR qty > 0 against l2_population_verdict desk_basis DC_PREFERRED and
-- ANOMALY_DC_AND_DIRECT): 17 DC_PREFERRED products (10116: 9, 80175: 8) and 1 ANOMALY (80176 product 1023).
-- Under latest-GRV, 15 of the 17 move from DC_AMBIENT to their direct desk (10116: 7 of 9, all to the Clover
-- supplier 1610, 12341 and 105825 stay on DC; 80175: all 8, supplier 1286) and the anomaly moves to the desk of
-- supplier 590 (last receipt 2026-06-23 against the DC account's 2026-05-13). ENG-183 add.6 said "at most 10":
-- the count is 17 today.
--
-- ORDER OF RUN: apply this, then refresh_l2_population_verdict per store (the nightly chain does it), then
-- refresh_supplier_desks and refresh_l2_received_placement read the new desks. R22: the stored orders of the
-- 15 moved products change desk, nothing else moves; read the order cache of both desks before and after.
-- ROLLBACK: restore the live body from sql/_archive/refresh_l2_population_verdict_pre_a1.sql.
-- =============================================================================

DO $mig$
DECLARE
  def text;
  n int;
BEGIN
  def := pg_get_functiondef('public.refresh_l2_population_verdict(text)'::regprocedure);

  n := (length(def) - length(replace(def, $a$p.desk_rcpt DESC, (rc.rcpt_desks IS NOT NULL AND p.is_dc) DESC, p.desk_last DESC NULLS LAST,$a$, ''))) / length($a$p.desk_rcpt DESC, (rc.rcpt_desks IS NOT NULL AND p.is_dc) DESC, p.desk_last DESC NULLS LAST,$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'A1 anchor 1 found % times', n; END IF;
  def := replace(def, $a$p.desk_rcpt DESC, (rc.rcpt_desks IS NOT NULL AND p.is_dc) DESC, p.desk_last DESC NULLS LAST,$a$, $b$p.desk_rcpt DESC, p.desk_last DESC NULLS LAST,$b$);

  n := (length(def) - length(replace(def, $a$              WHEN f.dc_rcpt THEN 'DC_PREFERRED'$a$, ''))) / length($a$              WHEN f.dc_rcpt THEN 'DC_PREFERRED'$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'A1 anchor 2 found % times', n; END IF;
  def := replace(def, $a$              WHEN f.dc_rcpt THEN 'DC_PREFERRED'$a$, $b$              WHEN f.dc_rcpt THEN 'LATEST_RECEIPT'$b$);

  n := (length(def) - length(replace(def, $a$    -- In the current regime: one receiving desk owns it, more than one goes to DC, because DC is the preferred
    -- supplier always where there are multiple suppliers. Not received in the regime: the desk whose supplier
    -- delivered it LAST in our history (DC on a same-day tie). Never received: Sigma's supplier column. Else DC, VERIFY.$a$, ''))) / length($a$    -- In the current regime: one receiving desk owns it, more than one goes to DC, because DC is the preferred
    -- supplier always where there are multiple suppliers. Not received in the regime: the desk whose supplier
    -- delivered it LAST in our history (DC on a same-day tie). Never received: Sigma's supplier column. Else DC, VERIFY.$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'A1 anchor 3 found % times', n; END IF;
  def := replace(def, $a$    -- In the current regime: one receiving desk owns it, more than one goes to DC, because DC is the preferred
    -- supplier always where there are multiple suppliers. Not received in the regime: the desk whose supplier
    -- delivered it LAST in our history (DC on a same-day tie). Never received: Sigma's supplier column. Else DC, VERIFY.$a$, $b$    -- In the current regime: one receiving desk owns it, more than one goes to the desk whose supplier delivered it
    -- LATEST (BLOOM-035 A1, PM 13-10-2026: the latest GRV decides, DC on a same-day tie). Not received in the regime:
    -- the desk whose supplier delivered it LAST in our history (DC on a same-day tie). Never received: Sigma's
    -- supplier column. Else DC, VERIFY.$b$);

  n := (length(def) - length(replace(def, $a$population-verdict v2.2 (ENG-183 desk split, received-from, history, supplier column)$a$, ''))) / length($a$population-verdict v2.2 (ENG-183 desk split, received-from, history, supplier column)$a$);
  IF n <> 1 THEN RAISE EXCEPTION 'A1 anchor 4 found % times', n; END IF;
  def := replace(def, $a$population-verdict v2.2 (ENG-183 desk split, received-from, history, supplier column)$a$, $b$population-verdict v2.3 (ENG-183 desk split, received-from, history, supplier column, A1 latest receipt decides)$b$);

  EXECUTE def;
END
$mig$;

COMMENT ON COLUMN public.l2_population_verdict.desk_basis IS 'ENG-183 (ORDERING-CANON SSA2), A1 amended 13-10-2026. Why the row sits on route_key (Pieter 2026-09-10: the supplier is who the line was received from, GRV-led, then the supplier column in Sigma). SOLE_DESK: one desk links it. RECEIPTS: exactly one linked desk received it in desk_receipt_window_days (the current regime). LATEST_RECEIPT: DC and another desk both received it in the regime, the desk whose supplier delivered it LATEST owns it (DC on a same-day tie), BLOOM-035 A1, PM ruling 13-10-2026, which retires the old DC_PREFERRED rule (retired_on 2026-10-13). ANOMALY_DC_AND_DIRECT: DC and a true DIRECT supplier (type F, outside the DC account) both received it in the regime; the latest receipt decides the desk, it is labelled, and its DC link goes on the Sigma correction list. MULTI_RECEIPT: two direct desks received it in the regime, the latest receipt owns it, surfaced. HISTORY_RECEIPT: no desk received it in the regime, so the desk whose supplier delivered it last in our whole receipt history owns it (DC on a same-day tie). SUPP_CD: never received in our history, so Sigma supplier column (Supp. Cd.) decided it; interim source product_catalog, the DIWAAIS copy pulled 2026-05-24, until ENG-184. NO_RECEIPT: never received and no supplier column match, DC first else desk_sort, VERIFY. SOLE_DESK_OFF_DESK_RECEIPT: one desk, but only a supplier with no desk here received it in the regime, flagged, nothing moves until the store consolidated desk (ENG-202).';
