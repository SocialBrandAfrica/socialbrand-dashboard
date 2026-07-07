-- =============================================================================
-- v_never_sold.sql (function: rpc_never_sold)
-- RETIRED IN PLACE 2026-07-07 (R28 lineage, effective_from 2026-07-07, scope GENERAL).
--   Zero live consumers verified (grep across src/ and public/: no calls found;
--   the only hits repo-wide are DEPLOY-LOG.md history and this file). Superseded
--   by l2_classification PHANTOM_ZERO/DEAD_ZERO buckets (TILL-ONLY K-channel
--   signal here missed S/L injections -- see CLEANUP-ENGINE-CANON canon).
--   Kept live (not dropped) as part of the daily_snapshots archive/truncate
--   clearance (PM ruling 2026-07-07): reads daily_snapshots directly below, so
--   after truncate it returns 0 rows -- harmless, nothing calls it.
--
-- Products that have stock on hand but have NEVER recorded a sale.
-- last_sales_date_iso IS NULL = Sigma has no sales history for this EAN.
--
-- These are distinct from Non-Movers (which sold at some point in the past
-- year but not in the last 4 weeks). Never-sold items represent either:
--   - Dead stock ordered but never sold through
--   - Incorrectly listed items
--   - New ranging not yet activated
--
-- Non-Movers (rpc_top20, p_activity='non_movers') already excludes never-sold
-- items correctly: the BETWEEN on last_sales_date_iso is NULL-safe and NULLs
-- fall outside any BETWEEN range. No change to rpc_top20 required.
--
-- Returns top N by capital tied (soh * sell_price).
-- =============================================================================

CREATE OR REPLACE FUNCTION rpc_never_sold(
    p_store_codes  text[],
    p_date         text,
    p_dept_names   text[]  DEFAULT NULL,
    p_subdept      text    DEFAULT NULL,
    p_limit        int     DEFAULT 100
)
RETURNS TABLE(
    ean           text,
    description   text,
    dept_name     text,
    sub_dept_name text,
    size          text,
    unit          text,
    soh           numeric,
    sell_price    numeric,
    capital_tied  numeric,
    store_code    text,
    store_name    text
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT
        ean,
        description,
        dept_name,
        sub_dept_name,
        size,
        unit,
        soh::numeric,
        sell_price::numeric,
        ROUND((soh * COALESCE(sell_price, 0))::numeric, 2) AS capital_tied,
        store_code,
        store_name
    FROM  daily_snapshots
    WHERE store_code          = ANY(p_store_codes)
      AND snapshot_date       = p_date::date
      AND last_sales_date_iso IS NULL
      AND soh                 > 0
      AND NOT is_placeholder
      AND (p_dept_names IS NULL OR dept_name     = ANY(p_dept_names))
      AND (p_subdept    IS NULL OR sub_dept_name = p_subdept)
    ORDER BY (soh * COALESCE(sell_price, 0)) DESC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION rpc_never_sold(text[], text, text[], text, int)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SELECT COUNT(*) FROM rpc_never_sold(ARRAY['10116'], CURRENT_DATE::text);
