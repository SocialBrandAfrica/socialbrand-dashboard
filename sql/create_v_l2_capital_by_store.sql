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
-- excluded buckets (DEAD_ZERO/PHANTOM_ZERO/COST_ERROR/DEPOSIT/...) for reference;
-- this is the tile's raw comparator (~R21M, SB-CC-DASH raw-chip fix).
-- capital_deposits = deposit/returnable float carved out of the headline
-- (SB-CC-DEPOSIT-001); surfaced as its own line, never in capital_purified.
--
-- Deployed 2026-06-13 via Supabase MCP (additive); capital_deposits added
-- 2026-06-15 (deposit_001_v_l2_capital_add_deposits). Anon SELECT.
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
       COUNT(*) AS rows,
       SUM(c.capital_value) FILTER (WHERE c.bucket = 'DEPOSIT') AS capital_deposits,
       COUNT(*) FILTER (WHERE c.bucket = 'DEPOSIT') AS deposit_lines
FROM public.l2_classification c
JOIN latest l ON l.store_code = c.store_code AND c.snapshot_date = l.d
GROUP BY c.store_code, c.snapshot_date;

GRANT SELECT ON public.v_l2_capital_by_store TO anon, authenticated;
