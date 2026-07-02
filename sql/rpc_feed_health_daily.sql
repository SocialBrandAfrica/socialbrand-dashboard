-- =============================================================================
-- rpc_feed_health_daily.sql
-- AUDIT-002 Step 2: per-day EOD + reconciliation health for one store / month
-- =============================================================================
-- PURPOSE:
--   Returns one row per calendar day in the requested month.
--   Compares DBUMBA (sigma_sales, exact ledger) vs PRSSALE (daily_snapshots,
--   Catman/TAC export) to detect three failure modes:
--
--   EOD_MISSING  -- sigma_sales has the day, daily_snapshots has nothing.
--                   Cause: store's end-of-day/Catman export did not run.
--                   Action: Pieter / Mari must re-run / regenerate EOD in Sigma.
--
--   DIVERGENT    -- both feeds have the day but |gap| / dbumba_total > 3%.
--                   Observed baseline drift is 0.3-1.3% (rounding); 3% flags
--                   genuine mismatches while ignoring normal drift.
--
--   NO_TRADE     -- both feeds have 0 / NULL. Store was genuinely closed (benign).
--
--   COMPLETE     -- both feeds present AND variance <= 3%.
--
--   FUTURE       -- date > CURRENT_DATE; not yet tradeable (suppress from alerts).
--
-- VERIFIED 2026-06-07 on store 10116:
--   05-29 (Fri) -> EOD_MISSING (DBUMBA R383,388 / PRSSALE R0). Root cause:
--   no TAC60529.zip was ever pushed. All other days 05-25 -> 06-07 -> COMPLETE
--   with variance 0.28-1.26%.
--
-- RELATIONSHIP TO ANOM-001:
--   This is ANOM-001 Family 1 (PIPELINE) elevated to immediate per PM directive
--   in SB-CC-AUDIT-002. The full radar will absorb this detector as Family 1
--   when ANOM-001 is ratified and l2_anomaly_daily is created.
--
-- USED BY:
--   - Consignment sushi applet: completeness strip under the sales table.
--   - Nightly governance check: call for each store, surface EOD_MISSING + DIVERGENT.
--
-- SB-CC-RETIRE-003 (2026-07-02) -- R28 lineage, the PRSSALE-horizon rule:
--   PRSSALE (daily_snapshots) write-retired 2026-06-28. Post-retire dates were
--   coming back EOD_MISSING / 100% variance (verified live: 10116 2026-07-01,
--   DBUMBA R234,998.01, "PRSSALE gap") -- a false alarm for every trading day
--   forever, which trains people to ignore red (R22 damage).
--   GENERAL RULE (no magic date): the two-feed comparison is only valid inside
--   the PRSSALE feed's lifetime for that store = dates <= MAX(snapshot_date)
--   in daily_snapshots. Beyond the horizon the function runs SINGLE-FEED:
--   status COMPLETE when the ledger holds the day, NO_TRADE / FUTURE as before;
--   prssale_total and variance_pct are NULL (absence surfaced, no pretend
--   reconciliation). EOD_MISSING / DIVERGENT can only fire inside the horizon.
--   The "did today land" alarm for the live pipeline is owned by
--   check_l1_feed_freshness v2, not this function.
--   Follow-up (needs a Vercel deploy, held): a distinct SINGLE_FEED status +
--   ConsignmentPanel STATUS_CFG entry so provenance is labelled on the strip
--   (R22 s5), instead of reusing COMPLETE.
-- =============================================================================

-- NOTE: daily_snapshots.client_id is UUID; sigma_sales.client_id is text.
-- Schema inconsistency -- both are single-tenant constants (architecture note:
-- "client_id is a constant, not an isolation key"). client_id filters omitted
-- from both CTEs. Flag for DB-SCHEMA.md pending fixes.

DROP FUNCTION IF EXISTS public.rpc_feed_health_daily(text, text, text);
DROP FUNCTION IF EXISTS public.rpc_feed_health_daily(text, text);

CREATE FUNCTION public.rpc_feed_health_daily(
    p_store  text,
    p_month  text             -- 'YYYY-MM'
)
RETURNS TABLE (
    sale_date     date,
    day_name      text,
    dbumba_total  numeric,    -- sigma_sales store total (exact ledger)
    prssale_total numeric,    -- daily_snapshots store total (PRSSALE/TAC)
    variance_pct  numeric,    -- |dbumba - prssale| / dbumba * 100; NULL when no trade
                              -- or past the PRSSALE horizon (single-feed mode)
    status        text,       -- COMPLETE | EOD_MISSING | DIVERGENT | NO_TRADE | FUTURE
    is_flagged    boolean     -- TRUE on EOD_MISSING or DIVERGENT (horizon only)
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
WITH

month_start AS (
    SELECT (p_month || '-01')::date AS d_start
),
month_end AS (
    SELECT (date_trunc('month', (p_month || '-01')::date)
            + INTERVAL '1 month - 1 day')::date AS d_end
),

date_spine AS (
    SELECT generate_series(
        (SELECT d_start FROM month_start),
        (SELECT d_end   FROM month_end),
        INTERVAL '1 day'
    )::date AS d
),

dbumba AS (
    SELECT
        sale_date,
        ROUND(SUM(sales_incl_vat)::numeric, 2) AS total
    FROM sigma_sales
    WHERE store_code  = p_store
      AND period_kind = 'T'
      AND txn_kind    = 1
      AND sale_date  >= (SELECT d_start FROM month_start)
      AND sale_date  <= (SELECT d_end   FROM month_end)
    GROUP BY sale_date
),

prssale AS (
    SELECT
        snapshot_date                           AS sale_date,
        ROUND(SUM(today_sales)::numeric, 2)     AS total
    FROM daily_snapshots
    WHERE store_code     = p_store
      AND snapshot_date >= (SELECT d_start FROM month_start)
      AND snapshot_date <= (SELECT d_end   FROM month_end)
    GROUP BY snapshot_date
),

prssale_horizon AS (
    -- RETIRE-003: the PRSSALE feed's lifetime for this store. The two-feed
    -- comparison is only valid for dates <= this horizon (write-retired
    -- 2026-06-28; general rule, no magic date). NULL when the store never
    -- had PRSSALE rows -> every date runs single-feed.
    SELECT MAX(snapshot_date) AS h FROM daily_snapshots WHERE store_code = p_store
)

SELECT
    ds.d                                                        AS sale_date,
    TO_CHAR(ds.d, 'Dy')                                         AS day_name,
    COALESCE(db.total, 0)                                       AS dbumba_total,

    -- prssale_total: NULL past the horizon (feed retired -- absence surfaced,
    -- never shown as a zero that reads like a missing EOD)
    CASE
        WHEN ds.d <= ph.h THEN COALESCE(pr.total, 0)
        ELSE NULL
    END                                                         AS prssale_total,

    -- variance: NULL when no trade or past the horizon
    CASE
        WHEN COALESCE(db.total, 0) = 0 OR ds.d > ph.h OR ph.h IS NULL THEN NULL
        ELSE ROUND(
            ABS(COALESCE(db.total, 0) - COALESCE(pr.total, 0))
            / db.total * 100,
        2)
    END                                                         AS variance_pct,

    CASE
        WHEN ds.d > CURRENT_DATE                                THEN 'FUTURE'
        -- single-feed mode past the PRSSALE horizon: the ledger alone decides
        WHEN ds.d > ph.h OR ph.h IS NULL THEN
            CASE WHEN COALESCE(db.total, 0) > 0 THEN 'COMPLETE' ELSE 'NO_TRADE' END
        WHEN COALESCE(db.total, 0) = 0
         AND COALESCE(pr.total, 0) = 0                         THEN 'NO_TRADE'
        WHEN COALESCE(db.total, 0) > 0
         AND COALESCE(pr.total, 0) = 0                         THEN 'EOD_MISSING'
        WHEN ABS(COALESCE(db.total, 0) - COALESCE(pr.total, 0))
             / NULLIF(db.total, 0) > 0.03                      THEN 'DIVERGENT'
        ELSE                                                         'COMPLETE'
    END                                                         AS status,

    CASE
        WHEN ds.d > CURRENT_DATE                                THEN FALSE
        WHEN ds.d > ph.h OR ph.h IS NULL                        THEN FALSE
        WHEN COALESCE(db.total, 0) > 0
         AND COALESCE(pr.total, 0) = 0                         THEN TRUE
        WHEN ABS(COALESCE(db.total, 0) - COALESCE(pr.total, 0))
             / NULLIF(db.total, 0) > 0.03                      THEN TRUE
        ELSE                                                         FALSE
    END                                                         AS is_flagged

FROM date_spine ds
CROSS JOIN prssale_horizon ph
LEFT JOIN dbumba  db ON db.sale_date = ds.d
LEFT JOIN prssale pr ON pr.sale_date = ds.d
ORDER BY ds.d;
$$;

COMMENT ON FUNCTION public.rpc_feed_health_daily(text, text) IS
    'AUDIT-002 Step 2: per-day EOD + reconciliation health. '
    'One row per calendar day for the requested store/month. '
    'EOD_MISSING = sigma_sales has the day, daily_snapshots has nothing (EOD export did not run). '
    'DIVERGENT = both feeds present but |gap| / dbumba > 3% (normal baseline 0.3-1.3%). '
    'NO_TRADE = both zero (store closed, benign). '
    'COMPLETE = both present, variance <= 3%. '
    'RETIRE-003 (2026-07-02): two-feed comparison only inside the PRSSALE horizon '
    '(MAX daily_snapshots.snapshot_date per store, frozen 2026-06-28); past it the '
    'function runs single-feed on sigma_sales -- COMPLETE when the ledger holds the '
    'day, prssale_total/variance NULL, EOD_MISSING/DIVERGENT cannot fire. '
    'Verified on 10116 May-2026: 05-29 = EOD_MISSING (R383,388 absent from PRSSALE). '
    'Family 1 of ANOM-001 radar, elevated to immediate per SB-CC-AUDIT-002.';

SELECT pg_notify('pgrst', 'reload schema');

-- =============================================================================
-- VERIFY after deploy (paste separately):
-- =============================================================================
-- -- Must show 05-29 = EOD_MISSING, all others COMPLETE:
-- SELECT sale_date, day_name, dbumba_total, prssale_total, variance_pct, status
-- FROM rpc_feed_health_daily('10116', '2026-05')
-- ORDER BY sale_date;
--
-- -- All stores, current month -- nightly governance use:
-- SELECT store_code, sale_date, day_name, dbumba_total, prssale_total, status
-- FROM (
--     SELECT '10116' AS store_code, * FROM rpc_feed_health_daily('10116', TO_CHAR(CURRENT_DATE,'YYYY-MM'))
--     UNION ALL
--     SELECT '21355', * FROM rpc_feed_health_daily('21355', TO_CHAR(CURRENT_DATE,'YYYY-MM'))
--     UNION ALL
--     SELECT '80175', * FROM rpc_feed_health_daily('80175', TO_CHAR(CURRENT_DATE,'YYYY-MM'))
--     UNION ALL
--     SELECT '80176', * FROM rpc_feed_health_daily('80176', TO_CHAR(CURRENT_DATE,'YYYY-MM'))
--     UNION ALL
--     SELECT '80579', * FROM rpc_feed_health_daily('80579', TO_CHAR(CURRENT_DATE,'YYYY-MM'))
-- ) t
-- WHERE is_flagged = TRUE
-- ORDER BY store_code, sale_date;
-- =============================================================================
