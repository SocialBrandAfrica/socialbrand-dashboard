-- =============================================================================
-- create_l2_cost_error.sql
-- SB-CC-COST-001 Step 1 — unified cost-error detector, built ONLY from the raw
-- sigma_movements ledger (R22: every flag traces to a raw movement row).
-- One row per (store_code, product_code, fault_type). General rule over raw data:
-- no store, supplier or product hard-coded, so it runs on any store.
--
-- NEVER edits Sigma (R25). The floor repairs the cost source (Sigma adjustment
-- cost setup + the 6-pack PLU costs); the engine reads the corrected cost next push.
-- Do NOT use cost_sanity_flag: it keys off supplier list-cost and the worst lines
-- carry R0 list-cost, so it both misses these and false-positives low-margin lines.
--
-- real_unit_cost = receipt WAC = SUM(cost_value)/SUM(qty) over R/W (DIWAREPR
-- receipts), trailing 120 days from each store's MAX(movement_date).
--
-- Two faults (work order Step 1):
--   1. ADJUSTMENT_COST  — DIWASOBE stock-book write-offs (movement_type='S'),
--      qty<0, EXCLUDING process M (Coca-Cola/DC supplier return) and G (crate/
--      deposit/empties) per the audit ("not stock back to DC, not crates"). The
--      adjustment posts at a unit cost far above receipt cost (the R550-vs-R182
--      chicken). Flag factor>2x; OR no recent receipt = UNVERIFIED, manual check.
--   2. SALES_COST       — depletion (sigma_sales = the K/DIWATABS ledger) where
--      ex-VAT cost of sales exceeds ex-VAT sell price (negative implied margin),
--      the liquor pack-PLU _6 family (CASTLE LITE NRB_6 etc.).
--
-- Reconciliation to SB-AUD-LEDGER-COST-001_v1.0 (R22):
--   LINE LEVEL matches the audit to the rand: EGGS JUMB -54,770, EGGS XL -41,521,
--   SCHWEPPES -17,080; the IQF chicken proof line is receipt R182 vs write-off
--   R552.71 (audit "R550"). This trace-to-source is the gold-standard check.
--   GROUP (30-day rolling to each store's max movement_date): verified recorded
--   -R2.00m, real -R146k, unverified -R341k. Higher than the audit's verified
--   -R1.66m because the live window now includes a NEW 16 Jun catch -- LARGE
--   MADEIRA LOAF FOIL CONTAINER @10116: 500 units written off at R913.68 vs R1.83
--   receipt = -R456k phantom, factor 500x -- which post-dates the audit's 15 Jun
--   cutoff. Net of that one line ~ -R1.55m, in line with the audit. Window edge +
--   S/O bidirectional treatment account for the rest.
--
-- Object class: VIEW (always current; no stale snapshot, no refresh wiring). If
-- Kong-facing query latency requires it, materialise (one-word change to
-- CREATE MATERIALIZED VIEW + add to refresh_l2_pipeline) — a PM call, see Step 2.
--
-- supersedes the list-cost worklist: rpc_cost_error_worklist may be re-pointed to
-- read SALES_COST rows from this view instead of l2_stock_position.unit_cost.
-- =============================================================================
DROP VIEW IF EXISTS public.v_l2_cost_error CASCADE;

CREATE VIEW public.v_l2_cost_error AS
WITH md AS (
  SELECT store_code, max(movement_date) AS dmax
  FROM sigma_movements GROUP BY store_code
),
wac AS (   -- real_unit_cost: receipt WAC over R/W, trailing 120 days
  SELECT m.store_code, m.product_code,
         sum(m.cost_value) / NULLIF(sum(m.qty),0) AS real_unit_cost
  FROM sigma_movements m JOIN md ON md.store_code = m.store_code
  WHERE m.movement_type='R' AND m.movement_process='W' AND m.qty > 0
    AND m.movement_date > md.dmax - 120
  GROUP BY m.store_code, m.product_code
),
adj AS (   -- ADJUSTMENT_COST candidates: S write-off out-lines, excl M + G.
           -- Detection window = trailing 30 days (rolling month) so rand_impact is
           -- the monthly phantom and reconciles to the audit (~R2.0m -> ~R235k).
  SELECT m.store_code, m.product_code,
         sum(m.cost_value)       AS rec_cost,
         sum(m.qty)              AS rec_qty,
         min(m.movement_date)    AS first_seen,
         max(m.article_text)     AS description
  FROM sigma_movements m JOIN md ON md.store_code = m.store_code
  WHERE m.movement_type='S' AND m.movement_process NOT IN ('M','G') AND m.qty < 0
    AND m.movement_date > md.dmax - 30
  GROUP BY m.store_code, m.product_code
),
sales AS (  -- SALES_COST candidates: depletion cost vs ex-VAT sell, trailing 30d
  SELECT s.store_code, s.product_code,
         sum(s.cost_value)                   AS sales_cost,
         sum(s.qty)                          AS sales_qty,
         sum(s.sales_incl_vat - s.vat_value) AS rev_exvat,
         min(s.sale_date)                    AS first_seen
  FROM sigma_sales s JOIN md ON md.store_code = s.store_code
  WHERE s.period_kind='T' AND s.txn_kind=1 AND s.qty > 0
    AND s.sale_date > md.dmax - 30
  GROUP BY s.store_code, s.product_code
)
-- ---- Fault 1: ADJUSTMENT_COST (DIWASOBE write-off re-valued at receipt WAC) ----
SELECT
  a.store_code,
  a.product_code,
  'ADJUSTMENT_COST'::text                                   AS fault_type,
  a.description,
  round(-a.rec_qty, 0)                                      AS units,            -- units written off (positive)
  round(w.real_unit_cost, 4)                               AS real_unit_cost,
  round(a.rec_cost / NULLIF(a.rec_qty,0), 4)               AS recorded_unit_cost,
  round((a.rec_cost / NULLIF(a.rec_qty,0))
        / NULLIF(w.real_unit_cost,0), 2)                   AS factor,
  round(a.rec_cost, 2)                                      AS recorded_value,   -- signed (negative = write-off)
  round(a.rec_qty * w.real_unit_cost, 2)                   AS real_value,
  round(a.rec_cost - a.rec_qty * w.real_unit_cost, 2)      AS rand_impact,       -- phantom (negative = overstated)
  'DIWASOBE'::text                                          AS channel,
  a.first_seen,
  (w.real_unit_cost IS NULL)                               AS unverified
FROM adj a
LEFT JOIN wac w
  ON w.store_code = a.store_code AND w.product_code = a.product_code
WHERE w.real_unit_cost IS NULL                                       -- unverified: no recent receipt to confirm
   OR (a.rec_cost / NULLIF(a.rec_qty,0)) > 2 * w.real_unit_cost      -- verified: adjustment cost > 2x receipt WAC

UNION ALL
-- ---- Fault 2: SALES_COST (cost of sales above ex-VAT sell = negative margin) ----
SELECT
  s.store_code,
  s.product_code,
  'SALES_COST'::text                                        AS fault_type,
  NULL::text                                                AS description,
  round(s.sales_qty, 0)                                     AS units,
  round(w.real_unit_cost, 4)                                AS real_unit_cost,
  round(s.sales_cost / NULLIF(s.sales_qty,0), 4)            AS recorded_unit_cost,
  round((s.sales_cost / NULLIF(s.sales_qty,0))
        / NULLIF(s.rev_exvat / NULLIF(s.sales_qty,0),0), 2) AS factor,           -- cost-to-sell ratio
  round(s.sales_cost, 2)                                    AS recorded_value,
  round(COALESCE(w.real_unit_cost, s.rev_exvat / NULLIF(s.sales_qty,0))
        * s.sales_qty, 2)                                   AS real_value,
  round(s.sales_cost
        - COALESCE(w.real_unit_cost, s.rev_exvat / NULLIF(s.sales_qty,0))
          * s.sales_qty, 2)                                 AS rand_impact,
  'DIWATABS'::text                                          AS channel,
  s.first_seen,
  (w.real_unit_cost IS NULL)                                AS unverified
FROM sales s
LEFT JOIN wac w
  ON w.store_code = s.store_code AND w.product_code = s.product_code
WHERE s.sales_qty > 0 AND s.rev_exvat > 0
  AND (s.sales_cost / s.sales_qty) > (s.rev_exvat / s.sales_qty)     -- negative implied margin
  AND (w.real_unit_cost IS NULL                                      -- AND it's a cost ghost, not a
       OR (s.sales_cost / s.sales_qty) > 2 * w.real_unit_cost);      -- genuinely low-margin line (cost >> receipt WAC)

GRANT SELECT ON public.v_l2_cost_error TO anon, authenticated;
-- SELECT pg_notify('pgrst','reload schema');   -- run on deploy
