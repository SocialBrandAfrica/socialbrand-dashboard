-- =============================================================================
-- v_l2_capital_by_store  --  per-store purified Capital Tied from the engine
-- =============================================================================
-- SB-CC-DASH-WIRE-001 ticket 1. The dashboard Capital Tied tile reads this so the
-- headline is the engine's PURIFIED capital (canon section 8.8 include-set =
-- HEALTHY + COUNT + AMBIGUOUS + LEAVE_COUNTED), not the ghost-inflated L1
-- SOH x unit_cost. Point-in-time: latest snapshot per store. Frontend sums
-- capital_purified over the selected stores (store-selection aware).
--
-- capital_in_scope_total = all in-scope (NORMAL, soh<>0) capital incl. the
-- excluded buckets (DEAD_ZERO/PHANTOM_ZERO/COST_ERROR/...) for reference; the
-- pre-engine raw chip on the tile still comes from v_kpi_by_date.capital_tied.
--
-- Deployed 2026-06-13 via Supabase MCP (additive). Anon SELECT.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_l2_capital_by_store AS
WITH latest AS (
  SELECT store_code, MAX(snapshot_date) AS d
  FROM public.l2_classification
  GROUP BY store_code
)
SELECT c.store_code,
       c.snapshot_date,
       SUM(c.capital_value) FILTER (
         WHERE c.bucket IN ('HEALTHY','COUNT','AMBIGUOUS','LEAVE_COUNTED')
       ) AS capital_purified,
       SUM(c.capital_value) AS capital_in_scope_total,
       COUNT(*) AS rows
FROM public.l2_classification c
JOIN latest l ON l.store_code = c.store_code AND c.snapshot_date = l.d
GROUP BY c.store_code, c.snapshot_date;

GRANT SELECT ON public.v_l2_capital_by_store TO anon, authenticated;
