-- =============================================================================
-- create_l2_cost_quarantine.sql
-- SB-CC-COST-001 Steps 2 (quarantine, do not delete) + 3 (route to the manager's
-- report). Builds on v_l2_cost_error -- deploy create_l2_cost_error.sql FIRST.
-- Read-only, never edits Sigma (R25). The flagged value still shows, marked.
-- Branch only; not deployed (awaits PM sign-off + live check).
-- =============================================================================

-- ---- Step 2a: quarantine surface -- the "quarantined: R x across n lines" line
-- that each affected measure displays. rand_impact is the phantom cost removed.
DROP VIEW IF EXISTS public.v_l2_cost_quarantine_summary CASCADE;
CREATE VIEW public.v_l2_cost_quarantine_summary AS
SELECT store_code, fault_type, channel,
       count(*)                                                      AS lines,
       count(*) FILTER (WHERE unverified)                            AS unverified_lines,
       round(sum(abs(rand_impact)) FILTER (WHERE NOT unverified), 2) AS quarantined_rand,
       round(sum(abs(recorded_value)) FILTER (WHERE unverified), 2)  AS unverified_recorded
FROM public.v_l2_cost_error
GROUP BY store_code, fault_type, channel;
GRANT SELECT ON public.v_l2_cost_quarantine_summary TO anon, authenticated;

-- ---- Step 2b: corrected GP measure (self-contained; proves the quarantine) ----
-- SALES_COST ghosts capped at receipt WAC (or ex-VAT sell when no recent receipt).
-- Verified lift (30d): 21355 3.27->15.29, 80579 14.25->15.64, 80176 15.86->15.98,
-- 10116 17.99->19.90, 80175 18.07->18.86. TOPS GP stops reading abnormally low.
DROP VIEW IF EXISTS public.v_l2_gp_quarantined CASCADE;
CREATE VIEW public.v_l2_gp_quarantined AS
WITH md AS (SELECT store_code, max(movement_date) AS dmax FROM sigma_movements GROUP BY store_code),
wac AS (
  SELECT m.store_code, m.product_code, sum(m.cost_value)/NULLIF(sum(m.qty),0) AS ruc
  FROM sigma_movements m JOIN md ON md.store_code=m.store_code
  WHERE m.movement_type='R' AND m.movement_process='W' AND m.qty>0 AND m.movement_date > md.dmax-120
  GROUP BY m.store_code, m.product_code),
sl AS (
  SELECT s.store_code, s.product_code, sum(s.cost_value) cost, sum(s.qty) qty,
         sum(s.sales_incl_vat - s.vat_value) rev, max(w.ruc) ruc
  FROM sigma_sales s JOIN md ON md.store_code=s.store_code
  LEFT JOIN wac w ON w.store_code=s.store_code AND w.product_code=s.product_code
  WHERE s.period_kind='T' AND s.txn_kind=1 AND s.qty>0 AND s.sale_date > md.dmax-30
  GROUP BY s.store_code, s.product_code),
q AS (
  SELECT store_code, cost, rev, qty, ruc,
    (qty>0 AND rev>0 AND (cost/qty) > (rev/qty) AND (ruc IS NULL OR (cost/qty) > 2*ruc)) AS flagged,
    CASE WHEN qty>0 AND rev>0 AND (cost/qty) > (rev/qty) AND (ruc IS NULL OR (cost/qty) > 2*ruc)
         THEN LEAST(cost, COALESCE(ruc, rev/NULLIF(qty,0))*qty) ELSE cost END AS quar_cost
  FROM sl)
SELECT store_code,
       round(sum(rev),2)                                                 AS rev_exvat,
       round(100*(sum(rev)-sum(cost))/NULLIF(sum(rev),0),2)              AS raw_gp_pct,
       round(100*(sum(rev)-sum(quar_cost))/NULLIF(sum(rev),0),2)         AS quarantined_gp_pct,
       round(sum(cost-quar_cost),2)                                      AS quarantined_rand,
       count(*) FILTER (WHERE flagged)                                   AS quarantined_lines
FROM q GROUP BY store_code;
GRANT SELECT ON public.v_l2_gp_quarantined TO anon, authenticated;

-- l2_kpi_daily fold-in (PM sign-off, NOT applied here): in sales_agg replace
-- SUM(cost_value) with the capped expression above so gp_pct is quarantined at source.

-- ---- Step 3: route to the floor-repair report -----------------------------
-- One row per flagged line: real vs recorded cost, rand impact, channel, dept and
-- the capturer who entered the qty (so the floor confirms the Sigma cost setup).
DROP VIEW IF EXISTS public.v_l2_cost_repair_worklist CASCADE;
CREATE VIEW public.v_l2_cost_repair_worklist AS
WITH md AS (SELECT store_code, max(movement_date) AS dmax FROM sigma_movements GROUP BY store_code)
SELECT e.store_code, e.product_code, e.fault_type,
       COALESCE(e.description, a.short_description, a.description) AS description,
       sd.name AS sub_dept, e.channel, e.units,
       e.real_unit_cost, e.recorded_unit_cost, e.factor, e.rand_impact,
       e.first_seen, e.unverified, cap.captured_by
FROM public.v_l2_cost_error e
LEFT JOIN sigma_articles a
  ON a.store_code=e.store_code AND a.client_id='socialbrand' AND a.product_code=e.product_code
LEFT JOIN sigma_subdepts sd
  ON sd.store_code=a.store_code AND sd.client_id=a.client_id AND sd.merch_group_nr=a.merch_group_nr
LEFT JOIN md ON md.store_code=e.store_code
LEFT JOIN LATERAL (
  SELECT string_agg(DISTINCT m.user_name, ', ') AS captured_by
  FROM sigma_movements m
  WHERE m.store_code=e.store_code AND m.product_code=e.product_code
    AND m.movement_type='S' AND m.movement_process NOT IN ('M','G') AND m.qty<0
    AND m.movement_date > md.dmax - 30
) cap ON e.fault_type='ADJUSTMENT_COST'
ORDER BY abs(e.rand_impact) DESC NULLS LAST;
GRANT SELECT ON public.v_l2_cost_repair_worklist TO anon, authenticated;
-- SELECT pg_notify('pgrst','reload schema');   -- run on deploy
