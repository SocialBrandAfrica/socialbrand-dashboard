-- =============================================================================
-- create_upsert_search_index.sql
-- SB-CC-PRSSALE-RETIRE-002 Tier 2 (search path closure).
-- Supersedes: SB-CC-RECONCILE-001 Phase 1 (daily_snapshots-driven upsert).
-- =============================================================================
-- WHY:
--   Old function: SELECT ... FROM daily_snapshots WHERE store_code = p_store_code
--     AND (p_snapshot_date IS NULL OR snapshot_date = p_snapshot_date).
--   daily_snapshots frozen at 2026-06-28. product_search_index therefore frozen
--   at 28 Jun: any product first ranged >= 29 Jun is invisible to the product
--   finder, and rpc_search_products falls back to a zero-result index hit for
--   new EANs. This is the search path completing the RETIRE-002 sweep.
--
-- WHAT CHANGES:
--   Driver: sigma_articles (all currently ranged products at each store).
--   ean: LEFT JOIN v_ean_bridge + COALESCE synthetic EAN (R20 addendum) --
--     INNER JOIN would silently drop 4.8-36% of products (same PLU/produce/TOPS
--     lines that were dropping from sales views; they must appear in search too).
--   dept: sigma_departments via sigma_articles.department_nr; COALESCE 'UNMAPPED'.
--     Dot-strip normalisation preserved (TRIM(REPLACE(...,'.',''))) to match
--     the UI chip labels that consumers read from this table.
--   subdept: sigma_subdepts via sigma_articles.merch_group_nr.
--   stores: ARRAY_AGG(DISTINCT store_code) -- same merge-on-conflict behaviour.
--   last_seen: l2_rate_of_sale.last_sale_date (most recent sale). Products with
--     no sale history get CURRENT_DATE (they are currently ranged, so today is
--     the correct "last seen in catalogue" date). NOT NULL constraint preserved.
--
-- SIGNATURE CHANGE:
--   Old: upsert_search_index(p_store_code text, p_snapshot_date date DEFAULT NULL)
--   New: upsert_search_index(p_store_code text DEFAULT NULL)
--     p_snapshot_date dropped -- sigma_articles has no date dimension (always
--     current). p_store_code made optional: NULL = all stores (pg_cron call);
--     specific value = single-store refresh if ever needed.
--   Old (text, date) overload DROPPED before CREATE to clear the old signature.
--   GRANT re-applied on the new signature.
--
-- SCHEDULE: pg_cron 'refresh-search-index' at 20:30 UTC (22:30 SAST) -- after
--   refresh-l2-pipeline (20:15 UTC, which advances l2_rate_of_sale) and before
--   feed-freshness-check (20:45 UTC). This replaces the per-store Push-script
--   call that was retired with PRSSALE-RETIRE-001.
--
-- SYNTHETIC EAN fallback: LPAD(store_code,5,'0')||LPAD(product_code::text,8,'0')
--   matches old daily_snapshots PLU-expansion convention (13 chars, R20 addendum).
--
-- R22 acceptance on apply: product_search_index row count (post-refresh) >= prior
--   row count (no shrinkage); spot-check a known PLU/produce EAN is now present.
-- Rule 19: DROP old signature + clean CREATE.
-- =============================================================================

DROP FUNCTION IF EXISTS public.upsert_search_index(text, date);

CREATE OR REPLACE FUNCTION public.upsert_search_index(
  p_store_code text DEFAULT NULL
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
AS $function$
INSERT INTO public.product_search_index (ean, description, dept, subdept, stores, last_seen)
SELECT
  COALESCE(b.ean,
    LPAD(a.store_code, 5, '0') || LPAD(a.product_code::text, 8, '0'))         AS ean,
  MAX(a.description)                                                            AS description,
  TRIM(REPLACE(COALESCE(MAX(sd.name), 'UNMAPPED'), '.', ''))                   AS dept,
  MAX(sub.name)                                                                 AS subdept,
  ARRAY_AGG(DISTINCT a.store_code)                                              AS stores,
  COALESCE(MAX(ros.last_sale_date), CURRENT_DATE)                              AS last_seen
FROM public.sigma_articles a
LEFT JOIN public.v_ean_bridge b
  ON  b.store_code   = a.store_code
  AND b.product_code = a.product_code
LEFT JOIN public.sigma_departments sd
  ON  sd.store_code    = a.store_code
  AND sd.department_nr = a.department_nr
LEFT JOIN public.sigma_subdepts sub
  ON  sub.store_code     = a.store_code
  AND sub.merch_group_nr = a.merch_group_nr
LEFT JOIN public.l2_rate_of_sale ros
  ON  ros.store_code   = a.store_code
  AND ros.product_code = a.product_code
WHERE (p_store_code IS NULL OR a.store_code = p_store_code)
GROUP BY
  COALESCE(b.ean, LPAD(a.store_code, 5, '0') || LPAD(a.product_code::text, 8, '0'))
ON CONFLICT (ean) DO UPDATE
  SET description = EXCLUDED.description,
      dept        = EXCLUDED.dept,
      subdept     = COALESCE(EXCLUDED.subdept, product_search_index.subdept),
      stores      = (
        SELECT ARRAY_AGG(DISTINCT s)
        FROM   UNNEST(product_search_index.stores || EXCLUDED.stores) AS s
      ),
      last_seen   = GREATEST(product_search_index.last_seen, EXCLUDED.last_seen);
$function$;

GRANT EXECUTE ON FUNCTION public.upsert_search_index(text)
  TO anon, authenticated;

-- pg_cron: nightly search-index refresh at 20:30 UTC (22:30 SAST).
-- Runs after refresh-l2-pipeline (20:15 UTC) so l2_rate_of_sale is current.
-- cron.schedule upserts by job name -- safe to re-apply.
SELECT cron.schedule(
  'refresh-search-index',
  '30 20 * * *',
  $$SELECT public.upsert_search_index();$$
);
