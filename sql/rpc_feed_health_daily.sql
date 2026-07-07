-- =============================================================================
-- rpc_feed_health_daily.sql
-- AUDIT-002 Step 2: per-day EOD + reconciliation health for one store / month
-- =============================================================================
-- REPOINTED SINGLE-FEED 2026-07-07 (PM ruling, daily_snapshots archive/truncate
-- clearance -- R28 lineage, effective_from 2026-07-07, scope GENERAL).
--
--   The two-feed DBUMBA (sigma_sales) vs PRSSALE (daily_snapshots) comparison
--   this function used to run for dates <= the 2026-06-28 PRSSALE horizon is
--   RETIRED. Every historical verdict (COMPLETE/EOD_MISSING/DIVERGENT/NO_TRADE
--   per store per day, 2025-03-01 through 2026-06-28) was preserved FIRST (R22)
--   into the permanent table public.feed_reconciliation_archive before this
--   repoint -- see sql/create_feed_reconciliation_archive.sql. Query that table
--   for the old two-feed detail; this function no longer reads daily_snapshots
--   at all.
--
--   Every date now runs the single-feed branch that was ALREADY the documented
--   post-horizon behaviour (RETIRE-003, 2026-07-02), now unconditional:
--     COMPLETE  -- sigma_sales holds the day.
--     NO_TRADE  -- no trade recorded that day (benign; store closed).
--     FUTURE    -- date > CURRENT_DATE.
--   EOD_MISSING and DIVERGENT can never fire anymore (there is no second feed
--   to diverge from or go missing against). prssale_total and variance_pct are
--   always NULL. is_flagged is always FALSE.
--
--   Output contract (column names/types) is UNCHANGED so existing consumers
--   need no changes: ConsignmentPanel.jsx (completeness strip) and
--   api/dev-corner/sigma-lines/route.js.
--
--   Follow-up (parked, needs a Vercel deploy): a distinct SINGLE_FEED status +
--   ConsignmentPanel STATUS_CFG entry so provenance is labelled on the strip
--   (R22 s5), instead of reusing COMPLETE. Not done this pass -- out of scope
--   for the truncate-readiness clearance.
-- =============================================================================
-- ORIGINAL PURPOSE (historical, now superseded by the archive table above):
--   Returns one row per calendar day in the requested month.
--   Compared DBUMBA (sigma_sales, exact ledger) vs PRSSALE (daily_snapshots,
--   Catman/TAC export) to detect three failure modes: EOD_MISSING (sigma_sales
--   has the day, daily_snapshots has nothing), DIVERGENT (both feeds present
--   but |gap| / dbumba_total > 3%), NO_TRADE (both feeds have 0/NULL).
--   VERIFIED 2026-06-07 on store 10116: 05-29 (Fri) -> EOD_MISSING (DBUMBA
--   R383,388 / PRSSALE R0). All other days 05-25 -> 06-07 -> COMPLETE with
--   variance 0.28-1.26%. This exact case is preserved in
--   feed_reconciliation_archive and reconciles there to the rand.
--
-- RELATIONSHIP TO ANOM-001:
--   Family 1 (PIPELINE) of the anomaly radar, elevated to immediate per PM
--   directive in SB-CC-AUDIT-002.
--
-- USED BY:
--   - Consignment sushi applet: completeness strip under the sales table.
--   - Nightly governance check: call for each store, surface EOD_MISSING (now
--     dead code path, kept for contract stability) + DIVERGENT.
-- =============================================================================

DROP FUNCTION IF EXISTS public.rpc_feed_health_daily(text, text, text);
DROP FUNCTION IF EXISTS public.rpc_feed_health_daily(text, text);

CREATE FUNCTION public.rpc_feed_health_daily(
    p_store  text,
    p_month  text             -- 'YYYY-MM'
)
RETURNS TABLE (
    sale_date     date,
    day_name      text,
    dbumba_total  numeric,
    prssale_total numeric,    -- always NULL -- PRSSALE feed retired, see feed_reconciliation_archive
    variance_pct  numeric,    -- always NULL -- single-feed mode has nothing to vary against
    status        text,       -- COMPLETE | NO_TRADE | FUTURE (EOD_MISSING/DIVERGENT retired with the feed)
    is_flagged    boolean     -- always FALSE -- single-feed mode never flags
)
LANGUAGE sql STABLE SECURITY DEFINER
SET statement_timeout = '15s'
AS $$
WITH
month_start AS (SELECT (p_month || '-01')::date AS d_start),
month_end AS (
    SELECT (date_trunc('month', (p_month || '-01')::date) + INTERVAL '1 month - 1 day')::date AS d_end
),
date_spine AS (
    SELECT generate_series(
        (SELECT d_start FROM month_start), (SELECT d_end FROM month_end), INTERVAL '1 day'
    )::date AS d
),
dbumba AS (
    SELECT sale_date, ROUND(SUM(sales_incl_vat)::numeric, 2) AS total
    FROM sigma_sales
    WHERE store_code = p_store AND period_kind = 'T' AND txn_kind = 1
      AND sale_date >= (SELECT d_start FROM month_start)
      AND sale_date <= (SELECT d_end FROM month_end)
    GROUP BY sale_date
)
SELECT
    ds.d AS sale_date,
    TO_CHAR(ds.d, 'Dy') AS day_name,
    COALESCE(db.total, 0) AS dbumba_total,
    NULL::numeric AS prssale_total,
    NULL::numeric AS variance_pct,
    CASE
        WHEN ds.d > CURRENT_DATE THEN 'FUTURE'
        WHEN COALESCE(db.total, 0) > 0 THEN 'COMPLETE'
        ELSE 'NO_TRADE'
    END AS status,
    FALSE AS is_flagged
FROM date_spine ds
LEFT JOIN dbumba db ON db.sale_date = ds.d
ORDER BY ds.d;
$$;

COMMENT ON FUNCTION public.rpc_feed_health_daily(text, text) IS
    'Per-day feed completeness for one store/month, SINGLE-FEED on sigma_sales only '
    '(repointed 2026-07-07, PM ruling, daily_snapshots archive/truncate clearance). '
    'COMPLETE = sigma_sales holds the day. NO_TRADE = no trade recorded (benign). '
    'FUTURE = date > CURRENT_DATE. EOD_MISSING/DIVERGENT retired with the PRSSALE '
    'feed (write-retired 2026-06-28) -- the historical two-feed verdicts for every '
    'date up to that horizon are preserved in public.feed_reconciliation_archive.';

GRANT EXECUTE ON FUNCTION public.rpc_feed_health_daily(text, text) TO anon, authenticated;
SELECT pg_notify('pgrst', 'reload schema');

-- =============================================================================
-- VERIFY after deploy (paste separately):
-- =============================================================================
-- -- Must show 05-29 = COMPLETE now (single-feed; sigma_sales holds the day) --
-- -- compare against feed_reconciliation_archive for the old EOD_MISSING verdict:
-- SELECT sale_date, day_name, dbumba_total, prssale_total, variance_pct, status
-- FROM rpc_feed_health_daily('10116', '2026-05')
-- ORDER BY sale_date;
--
-- SELECT sale_date, dbumba_total, prssale_total, status
-- FROM feed_reconciliation_archive
-- WHERE store_code = '10116' AND sale_date = '2026-05-29';
-- =============================================================================
