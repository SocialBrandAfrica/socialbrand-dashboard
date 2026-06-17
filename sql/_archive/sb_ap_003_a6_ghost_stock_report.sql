-- =============================================================================
-- SB-AP-003 Action A6 — Ghost stock report RPC
--
-- Lists all AUTO_EXCLUDE (production/ghost stock) items per store with their
-- current SOH and rand value, so the items can be fixed at source in Sigma
-- rather than merely hidden by the dashboard.
--
-- "Fix at source" means: in Sigma, adjust the stock count or raise a stock
-- write-off for lines that have phantom SOH (e.g. butchery lines where the
-- ledger SOH climbed to 12,400 units of boerewors that clearly don't exist).
--
-- WHY THIS EXISTS (A6 brief requirement):
--   Capital Tied exclusion hides the problem in the dashboard. This report
--   surfaces it so the store manager can see which lines need a Sigma fix.
--   The report is the "source" version — what Capital Tied would include if
--   ghost stock were not excluded.
--
-- USAGE (from reports drawer in the dashboard):
--   SELECT * FROM rpc_ghost_stock_report(ARRAY['10116'], '2026-06-01');
--   -- or via PostgREST:
--   POST /rest/v1/rpc/rpc_ghost_stock_report
--   {"p_store_codes":["10116"],"p_date":"2026-06-01"}
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_ghost_stock_report CASCADE;

CREATE FUNCTION public.rpc_ghost_stock_report(
    p_store_codes  text[],
    p_date         text
)
RETURNS TABLE(
    store_code     text,
    store_name     text,
    ean            text,
    description    text,
    dept_name      text,
    sub_dept_name  text,
    soh            numeric,
    unit_cost      numeric,
    ghost_value    numeric,    -- soh * unit_cost = rand value in Capital Tied before exclusion
    score          int,
    why_flagged    text,
    confirmed_by   text        -- NULL = auto-classified; 'PG' = human-confirmed
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ds.store_code,
        MAX(ds.store_name)                                                     AS store_name,
        ds.ean,
        MAX(ds.description)                                                    AS description,
        MAX(ds.dept_name)                                                      AS dept_name,
        MAX(ds.sub_dept_name)                                                  AS sub_dept_name,
        -- Use the most recent SOH for the given date
        MAX(ds.soh)                                                            AS soh,
        MAX(ds.unit_cost)                                                      AS unit_cost,
        ROUND((MAX(ds.soh) * COALESCE(MAX(ds.unit_cost), 0))::numeric, 2)     AS ghost_value,
        MAX(pc.score)                                                          AS score,
        MAX(pc.why_flagged)                                                    AS why_flagged,
        MAX(pc.confirmed_by)                                                   AS confirmed_by
    FROM daily_snapshots ds
    JOIN product_classification pc
      ON pc.store_code = ds.store_code
     AND pc.ean        = ds.ean
    WHERE ds.store_code    = ANY(p_store_codes)
      AND ds.snapshot_date = p_date::date
      AND pc.band          = 'AUTO_EXCLUDE'
    GROUP BY ds.store_code, ds.ean
    ORDER BY ghost_value DESC;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_ghost_stock_report(text[], text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY — after loading product_classification (A2 complete):
-- ---------------------------------------------------------------------------
-- Total ghost-stock rand value for SPAR Delareyville on most recent date:
SELECT
    COUNT(*)                     AS ghost_lines,
    SUM(ghost_value)             AS total_ghost_rand,
    MAX(ghost_value)             AS largest_single_line
FROM rpc_ghost_stock_report(
    ARRAY['10116'],
    (SELECT MAX(snapshot_date)::text FROM daily_snapshots WHERE store_code = '10116')
);
-- Expected: ghost_lines = 249 (or fewer if some have soh=0 or no matching snapshot).
-- total_ghost_rand should be the figure that drops from Capital Tied after A3 runs.
-- Record this number — it closes AUD-010 by documenting exactly what was removed.
