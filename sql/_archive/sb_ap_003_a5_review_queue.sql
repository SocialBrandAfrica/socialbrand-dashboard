-- =============================================================================
-- SB-AP-003 Action A5 — Production review queue
--
-- Two objects:
--   v_production_review_queue  — lists band=REVIEW items with current SOH,
--                                 cost, ghost value, and why they were flagged.
--   rpc_confirm_production     — PG confirms or rejects a line; writes back
--                                 to product_classification.
--
-- WORKFLOW:
--   1. Open the review queue report (A6 surfaces it in the reports drawer).
--   2. PG sees a line and decides: is it really production, or real retail?
--   3. Call rpc_confirm_production(store_code, ean, 'AUTO_EXCLUDE', 'PG')
--      to promote a line from REVIEW to AUTO_EXCLUDE (excluded from Capital Tied).
--      Or call with 'STOCK' to mark it as confirmed retail.
--   4. The next Capital Tied refresh picks up the change automatically
--      (v_kpi_by_date is a live view; mv_kpi_by_date refreshes nightly).
--
-- NOTES:
--   p_verdict must be 'AUTO_EXCLUDE' or 'STOCK'. Any other value is rejected.
--   confirmed_at and confirmed_by are written; scored_at/why_flagged/band updated.
--   Load script (A2) will NOT overwrite confirmed rows unless --force is passed.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- View: v_production_review_queue
--
-- Shows band=REVIEW lines with the most recent SOH and ghost-value for each
-- store. PG uses this to decide which items to promote to AUTO_EXCLUDE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_production_review_queue AS
SELECT
    pc.store_code,
    pc.ean,
    pc.classification,
    pc.score,
    pc.why_flagged,
    pc.confirmed_by,
    pc.confirmed_at,
    -- Latest snapshot for context
    snap.description,
    snap.dept_name,
    snap.sub_dept_name,
    snap.soh,
    snap.unit_cost,
    ROUND((snap.soh * COALESCE(snap.unit_cost, 0))::numeric, 2)   AS ghost_value,
    snap.snapshot_date                                             AS latest_snapshot
FROM product_classification pc
LEFT JOIN LATERAL (
    -- Most recent row for this (store_code, ean)
    SELECT description, dept_name, sub_dept_name, soh, unit_cost, snapshot_date
    FROM   daily_snapshots ds
    WHERE  ds.store_code = pc.store_code
      AND  ds.ean        = pc.ean
    ORDER  BY ds.snapshot_date DESC
    LIMIT  1
) snap ON true
WHERE pc.band = 'REVIEW'
ORDER BY pc.store_code, COALESCE(snap.soh * snap.unit_cost, 0) DESC;

GRANT SELECT ON v_production_review_queue TO anon, authenticated;


-- ---------------------------------------------------------------------------
-- RPC: rpc_confirm_production
--
-- PG calls this to confirm or reject a REVIEW line.
-- p_verdict must be 'AUTO_EXCLUDE' (confirmed production) or 'STOCK' (retail).
--
-- SECURITY: SECURITY DEFINER so it can update product_classification
--           regardless of RLS (there is no RLS on this table, but DEFINER
--           ensures future RLS additions don't silently block confirms).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.rpc_confirm_production CASCADE;

CREATE FUNCTION public.rpc_confirm_production(
    p_store_code   text,
    p_ean          text,
    p_verdict      text,           -- 'AUTO_EXCLUDE' or 'STOCK'
    p_confirmed_by text DEFAULT 'PG'
)
RETURNS TABLE(
    store_code     text,
    ean            text,
    old_band       text,
    new_band       text,
    confirmed_by   text,
    confirmed_at   timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_old_band text;
BEGIN
    -- Validate verdict
    IF p_verdict NOT IN ('AUTO_EXCLUDE', 'STOCK') THEN
        RAISE EXCEPTION 'p_verdict must be AUTO_EXCLUDE or STOCK, got: %', p_verdict;
    END IF;

    -- Capture old band for the return row
    SELECT pc.band INTO v_old_band
    FROM   product_classification pc
    WHERE  pc.store_code = p_store_code AND pc.ean = p_ean;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No classification found for store_code=% ean=%', p_store_code, p_ean;
    END IF;

    -- Write the confirmation
    UPDATE product_classification
    SET    band         = p_verdict,
           confirmed_by = p_confirmed_by,
           confirmed_at = now()
    WHERE  store_code   = p_store_code
      AND  ean          = p_ean;

    RETURN QUERY
    SELECT p_store_code, p_ean, v_old_band, p_verdict, p_confirmed_by, now()::timestamptz;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_confirm_production(text, text, text, text)
    TO anon, authenticated;

SELECT pg_notify('pgrst', 'reload schema');


-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- After loading product_classification (A2 complete):
SELECT band, COUNT(*), ROUND(AVG(score), 1) AS avg_score
FROM   product_classification
WHERE  store_code = '10116'
GROUP  BY band
ORDER  BY band;
-- Expected: AUTO_EXCLUDE=249  REVIEW=742  STOCK=12345

-- Review queue should show 742 rows for store 10116:
SELECT COUNT(*) FROM v_production_review_queue WHERE store_code = '10116';
