-- =============================================================================
-- v_l2_soh_effective -- ENG-214. The stock position after the ledger has been allowed
-- to overtake the snapshot.
--
-- GATED TO LIVE 2026-09-23 10:1x SAST (CC): md5(pg_get_viewdef(..., true)) =
--   79ddcf03bf04f039bc12436ba5c190e3
-- Migrations: eng214_v_l2_soh_effective (first cut), then the LATERAL rewrite applied
-- as CREATE OR REPLACE in the same session, then REVOKE SELECT FROM anon.
--
-- WHY IT EXISTS. l2_soh_daily is written ON CONFLICT DO NOTHING and the 19:30 extractor
-- task can fire BEFORE Sigma's end of day. Where it does, that date's snapshot is the
-- position before the day's till depletion, the later run that carries the postings is
-- discarded silently, and the order sheet is built on stock that has already been sold.
-- Measured: 8 store-days in 45 (10116 four of 45), and on 2026-09-21 at 10116 the sheet
-- Delareyville ordered from was short R22,500 / 108 packs / 58 lines.
--
-- WHY TILL-ONLY, AND IT IS MEASURED, NOT ASSUMED. On 9 store-days where the snapshot was
-- read LAST (so snapshot and ledger are directly comparable), the ledger's own running
-- balance new_soh reproduces the snapshot on:
--     K   till       n=8,105  99.6%
--     I/M stocktake  n=1,030  89.2%
--     R/W GRV        n=  388  96.1%
--     S/* channels   n=  279  79-96%
-- Only the till channel is trustworthy enough to correct a snapshot with, and the till
-- channel is exactly what a pre-EOD snapshot is missing. A non-till movement ingested
-- after the snapshot is FLAGGED on the row and never silently applied.
-- Worked counter-example kept so nobody widens this: 80175 product 191 on 21-09 carries
-- I/M rows whose new_soh reads 42 then 39 while the snapshot and the till sequence both
-- say 38. The stocktake channel's running balance is not the store's live balance.
--
-- CONTRACT. One row per (client_id, store_code, product_code, snapshot_date):
--   soh_snapshot            what the extractor read, unchanged, always present
--   snapshot_ingested_at    when it was read (SAST in the story, UTC in the column)
--   till_close_soh          Sigma's own balance after the last till movement of that date
--   till_units              signed till units for that date
--   snapshot_predates_till  the ENG-214 condition
--   soh_effective           the answer a consumer should read
--   soh_basis               snapshot | ledger_till_close | ledger_till_close_other_channel_flagged
--   soh_story               the R29 reason, in the buyer's words
--
-- READERS: rpc_bloom_order_recipe (its soh CTE, since pin b9ad7495). Grants: authenticated
-- and service_role only; anon revoked -- no surface reads it and the recipe is SECURITY
-- DEFINER, so nothing needs the browser key on it.
--
-- R22 AT BUILD, all five DC desks, same data, the pre-change body held as a shadow and
-- dropped after: 10116, 80175, 80176, 80579 identical to the cent, 0 lines differ.
-- 21355 DC_TOPS R65,270.66 -> R72,421.52, 8 lines added, 4 lifted, 0 cut, 30 lines' SOH
-- corrected by 259 units -- its 22-09 snapshot was an 08:17 morning read, because that
-- store missed its 21-09 nightly run entirely.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_l2_soh_effective AS
SELECT s.client_id,
       s.store_code,
       s.product_code,
       s.snapshot_date,
       s.soh                                          AS soh_snapshot,
       s.ingested_at                                  AS snapshot_ingested_at,
       t.till_close_soh,
       t.till_units,
       t.till_first_ingested_at,
       (t.till_first_ingested_at IS NOT NULL AND t.till_first_ingested_at > s.ingested_at) AS snapshot_predates_till,
       (o.other_last_ingested_at IS NOT NULL AND o.other_last_ingested_at > s.ingested_at) AS other_channel_after_snapshot,
       CASE WHEN t.till_first_ingested_at IS NOT NULL AND t.till_first_ingested_at > s.ingested_at
            THEN t.till_close_soh ELSE s.soh END      AS soh_effective,
       CASE WHEN t.till_first_ingested_at IS NULL OR t.till_first_ingested_at <= s.ingested_at THEN 'snapshot'
            WHEN o.other_last_ingested_at IS NOT NULL AND o.other_last_ingested_at > s.ingested_at THEN 'ledger_till_close_other_channel_flagged'
            ELSE 'ledger_till_close' END              AS soh_basis,
       CASE WHEN t.till_first_ingested_at IS NULL OR t.till_first_ingested_at <= s.ingested_at
            THEN 'SNAPSHOT: taken ' || to_char(s.ingested_at AT TIME ZONE 'Africa/Johannesburg','HH24:MI')
                 || ', after the day''s till postings or with none to carry.'
            ELSE 'LEDGER: the snapshot was read at ' || to_char(s.ingested_at AT TIME ZONE 'Africa/Johannesburg','HH24:MI')
                 || ' and the till posted at ' || to_char(t.till_first_ingested_at AT TIME ZONE 'Africa/Johannesburg','HH24:MI')
                 || ', so it is short ' || ROUND(s.soh - t.till_close_soh, 0) || ' units of that day''s sales. '
                 || 'Position taken from the till channel close (ENG-214).'
                 || CASE WHEN o.other_last_ingested_at IS NOT NULL AND o.other_last_ingested_at > s.ingested_at
                         THEN ' FLAG: a non-till movement also posted after the snapshot; only the till leg is corrected.'
                         ELSE '' END END              AS soh_story
FROM public.l2_soh_daily s
LEFT JOIN LATERAL (
  SELECT MIN(m.ingested_at) AS till_first_ingested_at,
         SUM(m.qty)         AS till_units,
         (ARRAY_AGG(m.new_soh ORDER BY m.movement_time DESC NULLS LAST, m.movement_id DESC))[1] AS till_close_soh
  FROM public.sigma_movements m
  WHERE m.store_code = s.store_code AND m.product_code = s.product_code
    AND m.movement_date = s.snapshot_date AND m.movement_type = 'K'
) t ON true
LEFT JOIN LATERAL (
  SELECT MAX(m.ingested_at) AS other_last_ingested_at
  FROM public.sigma_movements m
  WHERE m.store_code = s.store_code AND m.product_code = s.product_code
    AND m.movement_date = s.snapshot_date AND m.movement_type <> 'K'
) o ON true;

COMMENT ON VIEW public.v_l2_soh_effective IS
'GRADE: CALCULATED. ENG-214. The stock position for a (store, product, date) after the ledger has been allowed to overtake the snapshot. soh_effective = the snapshot, unless that date''s till postings were ingested AFTER the snapshot was read, in which case it is the till channel''s own closing balance. Till-only by measurement: on 9 store-days where the snapshot was read last, new_soh reproduces it 99.6% on K (n=8,105) against 89-96% on I/M, R/W and the S channels, so no other channel is trusted to correct a snapshot. A non-till movement ingested after the snapshot is FLAGGED on the row (other_channel_after_snapshot, soh_basis) and never silently applied. Every row carries soh_snapshot beside soh_effective and a story (R29). Readers: rpc_bloom_order_recipe.';

-- A LATERAL probe per snapshot row, deliberately: the first cut grouped the whole of
-- sigma_movements because a qual on the outer side of a LEFT JOIN does not propagate into
-- a grouped subquery, so a single store-date read still aggregated 18M rows and had to be
-- cancelled. Filtered by (store_code, snapshot_date) the LATERAL form costs 3.6s for a
-- whole store's 91,815 rows on idx_sigma_moves_store_prod_date.

REVOKE ALL ON public.v_l2_soh_effective FROM PUBLIC;
REVOKE ALL ON public.v_l2_soh_effective FROM anon;
GRANT SELECT ON public.v_l2_soh_effective TO authenticated, service_role;
