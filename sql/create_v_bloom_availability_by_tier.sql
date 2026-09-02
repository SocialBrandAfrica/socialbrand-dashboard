-- v_bloom_availability_by_tier -- availability by (store, route, tier).
-- SB-CC-BLOOM-029 item 6. Applied live 2026-09-02 as migration
-- `bloom029_item6_availability_by_tier`. Body below is what was applied.
--
-- WHY A VIEW AND NOT A NEW FACT (R32 §2, R33). The pantry already carries every
-- column this needs: l2_population_verdict holds tier, route_key, soh and
-- passes_life_gate per (store, product). Building a second object to compute a
-- ratio over facts that already exist would be the app-local re-implementation
-- R33 clause 3 forbids. This is a thin published interface over the one home.
--
-- 🔴 IT IS A FLOOR ON AVAILABILITY, NOT A MEASUREMENT OF IT, and the label is
-- part of the deliverable. `in_stock` means LEDGER soh > 0. The ledger is the
-- claim under audit, never proof of presence -- NORTH_STAR: presence is proven by
-- sales or counts, never by SOH. A line counted in_stock here can be empty on the
-- shelf. Every consumer states that or it publishes a number it has not earned.
--
-- 🔴 IT STATES ITS OWN MOMENT, and this corrects the brief's R22 as written.
-- `as_of` is the soh_date of the SINGLE snapshot l2_population_verdict holds.
-- Measured 2026-09-02: that table carries exactly ONE date (2026-09-01, 36,704
-- rows, computed 20:15 UTC by job 15) because refresh_l2_pipeline REPLACES it
-- nightly rather than appending. The brief asks for the view to be "re-run
-- against 02-09 soh_date and both dates published". That cannot be done: there is
-- no 02-09 row today, and when tonight's job 15 writes one it REPLACES 09-01, so
-- two dates can never be present together. A history of this measure would need
-- its own snapshot table, which is not in this sprint.
--
-- R22 (PM's three F9 figures, reproduced through the view AS ANON):
--   10116 DC_AMBIENT  TOP_1000   554 / 584 = 94.9    as_of 2026-09-01
--   21355 DC_TOPS     TOP_1000   320 / 490 = 65.3    as_of 2026-09-01
--   80176 DIRECT_BEER TOP_100      2 /  11 = 18.2    as_of 2026-09-01
--
-- CROSS-APP (R33): one fact, every app reads it. Pulse's availability card and any
-- Bloom desk header read THIS view; neither re-derives the ratio. Pack item 4
-- repoints to it (PM relay).

CREATE OR REPLACE VIEW public.v_bloom_availability_by_tier AS
SELECT
  v.store_code,
  v.route_key,
  v.tier,
  count(*)::int                                                              AS lines,
  count(*) FILTER (WHERE v.soh > 0)::int                                     AS in_stock,
  round(100.0 * count(*) FILTER (WHERE v.soh > 0) / nullif(count(*), 0), 1)  AS availability_pct,
  max(v.soh_date)                                                            AS as_of
FROM public.l2_population_verdict v
WHERE v.passes_life_gate
GROUP BY v.store_code, v.route_key, v.tier;

-- Published interface: read-only, both browser roles (R30 §1).
GRANT SELECT ON public.v_bloom_availability_by_tier TO anon, authenticated;

COMMENT ON VIEW public.v_bloom_availability_by_tier IS
'GRADE: CALCULATED. Availability by (store, route, tier) over l2_population_verdict, life-gated lines only. SB-CC-BLOOM-029 item 6.
IT IS A FLOOR ON AVAILABILITY, NOT A MEASUREMENT OF IT: in_stock means LEDGER soh > 0, and the ledger is the claim under audit, never proof of presence (NORTH_STAR: presence is proven by sales or counts, never by SOH). A line counted in_stock here may be empty on the shelf.
STATES ITS OWN MOMENT: as_of is the soh_date of the single snapshot l2_population_verdict holds. That table is REPLACED nightly by job 15 (refresh_l2_pipeline, 22:15 SAST), so it carries exactly one date at a time and this view can never show two. A figure quoted from it carries as_of or it is a claim about the past presented as the present.
R33: one fact, every app reads it -- Pulse''s availability card and any Bloom desk header read THIS view rather than re-deriving the ratio.';
