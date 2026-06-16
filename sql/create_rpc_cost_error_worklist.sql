-- =============================================================================
-- create_rpc_cost_error_worklist.sql
-- SB-CC-COST-001 Steps 1 + 3 -- impossible-cost detection (ratio test) + the
-- floor repair worklist. Read-only: the engine FLAGS the bad cost, never edits
-- Sigma (R25). Pieter/Sparrie repair pack size + cost on the floor; the engine
-- reads the corrected cost on the next push.
-- =============================================================================
-- A line is a cost error when its sigma COGS-implied unit cost (cost_value / qty)
-- exceeds the ex-VAT shelf price by a material factor (p_ratio, default 1.5x) --
-- a pack-size cost ghost (e.g. CASTLE LITE NRB_6 at R1,643/unit vs R87 sell).
-- The RATIO test (not a margin test) is per the brief: it catches the impossible
-- lines and leaves real low-margin / clearance lines alone -- proven by
-- cogs_overstated, which is ~0 for a genuine low-margin line (sane cost == sigma
-- cost, e.g. PADDYS at 1.6x) and large for a true cost ghost (sane << sigma).
--
-- sane_unit_cost = supplier list_cost / pack (l2_stock_position.unit_cost, R25
-- Sigma-native). When it is also unsound (0 / pack-bad), the line is an
-- exclude-and-surface case (brief Step 2 fallback), flagged by a non-positive or
-- still-impossible sane figure -- never invent a cost.
--
-- Window = last p_days from each store's MAX(sale_date), period_kind='T',txn_kind=1.
-- Reconcile (live, 2026-06-15, 21355): Castle Lite R49.3k + Black Crown_6 R24.4k
-- overstated; removing the cost-error lines lifts 21355 GP 3.14% -> 15.4%
-- (-> ~17% with Step 2 sane-cost substitution). Other 4 stores tie Sparrie.
--
-- Function-change protocol: single signature, DROP + CREATE, reload schema.
-- SECURITY DEFINER, anon + authenticated EXECUTE.
-- =============================================================================
DROP FUNCTION IF EXISTS public.rpc_cost_error_worklist(text[], int, numeric);

CREATE FUNCTION public.rpc_cost_error_worklist(
    p_store_codes text[],
    p_days        int     DEFAULT 28,
    p_ratio       numeric DEFAULT 1.5
)
RETURNS TABLE(
    store_code text, product_code bigint, description text, dept_name text,
    units numeric, sigma_unit_cost numeric, ex_vat_sell_unit numeric,
    cost_to_sell_ratio numeric, sane_unit_cost numeric,
    bad_cogs numeric, sane_cogs numeric, cogs_overstated numeric
)
LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  WITH maxd AS (
    SELECT store_code, MAX(sale_date) AS d FROM sigma_sales
    WHERE store_code = ANY(p_store_codes) AND period_kind='T' AND txn_kind=1
    GROUP BY store_code
  ),
  agg AS (
    SELECT ss.store_code, ss.product_code,
           SUM(ss.sales_incl_vat - ss.vat_value) AS rev_exvat,
           SUM(ss.cost_value)                    AS cogs,
           SUM(ss.qty)                           AS units
    FROM sigma_sales ss JOIN maxd m ON m.store_code = ss.store_code
    WHERE ss.period_kind='T' AND ss.txn_kind=1 AND ss.sale_date >= m.d - p_days
    GROUP BY ss.store_code, ss.product_code
  )
  SELECT a.store_code, a.product_code, sp.description, sp.dept_name,
         a.units,
         ROUND(a.cogs / NULLIF(a.units,0), 2)                                   AS sigma_unit_cost,
         ROUND(a.rev_exvat / NULLIF(a.units,0), 2)                              AS ex_vat_sell_unit,
         ROUND((a.cogs / NULLIF(a.units,0)) / NULLIF(a.rev_exvat / NULLIF(a.units,0),0), 2) AS cost_to_sell_ratio,
         ROUND(sp.unit_cost, 2)                                                 AS sane_unit_cost,
         ROUND(a.cogs, 2)                                                       AS bad_cogs,
         ROUND(sp.unit_cost * a.units, 2)                                       AS sane_cogs,
         ROUND(a.cogs - COALESCE(sp.unit_cost,0) * a.units, 2)                  AS cogs_overstated
  FROM agg a
  LEFT JOIN l2_stock_position sp ON sp.store_code = a.store_code AND sp.product_code = a.product_code
  WHERE a.units > 0 AND a.rev_exvat > 0
    AND (a.cogs / a.units) > p_ratio * (a.rev_exvat / a.units)
  ORDER BY (a.cogs - COALESCE(sp.unit_cost,0) * a.units) DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_cost_error_worklist(text[], int, numeric) TO anon, authenticated;
SELECT pg_notify('pgrst','reload schema');
