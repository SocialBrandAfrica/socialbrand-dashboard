-- create_bloom_route_config_natbrands_10116.sql
-- SB-CC-BLOOM-009 wave 3, item 1 (PM queue 2026-07-17). CONFIG ONLY -- no
-- schema change, no RPC change. `rpc_bloom_order_recipe` already generalises on
-- the `DIRECT\_%` pattern and reads `direct_supplier_nrs` off a RULED row, so a
-- desk is a config row plus a frontend entry (R32, the applet contract: the
-- rollout test is zero schema changes, and this passes it).
--
-- SHIPS ALONE. The other half of item 1, DIRECT_MONDELEZ 10116, is HELD -- see
-- the block at the foot of this file. Do not seed it from this pattern without
-- reading that first.
--
-- ============================ IDENTITY (receipt-proven, never name-matched) ===
-- canon 7d: attribution is by RECEIPTS, never links. A link says a price was
-- agreed, not that a truck came (Isicebi: R69k/wk on links, ZERO direct
-- receipts, DC-supplied). canon 7d also: supplier_nr is store-local AND collides
-- across stores (1226 = PB LAAS at 80175, FRONERI at 10116) -- everything below
-- is 10116-scoped and nothing here may be copied to another store unchecked.
--
-- National Brands at 10116 carries THREE link accounts. Resolved live, 182d:
--   99   NATIONAL BRANDS LIMITED   103 linked   64 selling(91d)  64 recv by NB   0 recv by DC
--   2071 NATIONAL BRANDS GROCGROP   71 linked   10 selling(91d)  10 recv by NB   0 recv by DC
--   1543 NATIONAL BRANDS(BISC        6 linked    0 selling        0 recv          0 recv by DC
--
-- => direct_supplier_nrs = {99, 2071}. UNIONED, not dominant-only. The dominant
--    (99, by link count) MISSES 10 selling lines that sit on 2071 and are
--    received by National Brands itself -- the wave-1 dominant-only method would
--    have silently dropped them (PM's item-1 gate, fired as designed).
-- => 1543 EXCLUDED: zero selling, zero receipts in 182d. A dead account is not
--    unioned in "just in case" -- it would widen the pool with lines no truck
--    brings (R21, exclusions earned and surfaced).
-- => recv_by_DC = 0 on all three: this route is genuinely direct, unlike Isicebi.
-- Product MEMBERSHIP stays behaviour-led via each product's own active non-Z
-- sigma_supplier_link row. This array names WHICH ACCOUNTS constitute the brand,
-- a one-time human-reviewable mapping -- never a hardcoded product list.
--
-- ============================== CADENCE (canon 7f, ledger-derived) ============
-- 182d window (canon 7d: 28d read Mondelez as weekly off 2 observations).
-- median drop gap = 10.5 over 16 gaps_observed (R29 -- the count travels with
-- the figure). 10.5/7 = 1.50 EXACTLY.
--
-- canon 7f: cycle_weeks = round(median_gap / 7), TIES AND DOUBT RESOLVE WEEKLY.
-- 1.50 is the tie. It lands on 1. => cycle_weeks = 1 = WEEKLY = today's live
-- behaviour, so this desk has NO grain dependency and does not wait on 7e.
--
-- *** IMPLEMENTATION TRAP, recorded so it is never re-introduced: Postgres
--     ROUND(1.5) = 2 (half away from zero). That is 7f BACKWARDS on the tie and
--     would seed this exact desk FORTNIGHTLY, halving nothing but doubling its
--     cover. 7f's rounding must be written half-DOWN explicitly:
--         CASE WHEN median_gap/7.0 <= 1.5 THEN 1 ELSE round(...) END
--     The one desk on the board that sits precisely on the tie is this one.
--
-- STABLE under the free parameter: median 10.5 / 16 gaps at a >=1, >=2 AND >=3
-- lines-per-day noise floor. The figure does not move, so the desk is safe to
-- seed regardless of how the floor question (below) is ruled.
--
-- HONEST LIMIT (R29, surfaced not buried): the gap distribution is perfectly
-- BIMODAL -- 8 gaps near 7 and 8 near 14, nothing in between. The median 10.5 is
-- a value that never actually occurs; it is the empty valley between two humps.
-- 7f's tie rule resolves it weekly and that is the ruled-safe direction: a
-- weekly desk at a supplier that skips a week just generates a small order,
-- which `direct_min_order_value` (queue item 2) will flag and the buyer
-- accumulates -- the accumulate-to-next-cycle behaviour v9 item 7 describes.
-- The 14-day legs run 7 days of cover until 7f's received-drop arbiter lands
-- (deliberately its own brief, queued after the fortnightly three).
--
-- ============================== DELIVERY DAY (ledger-derived) =================
-- Tue = 13 of 17 qualifying drop days (76%). Mon 2 (12%), Wed 2 (12%).
-- SINGLE dominant day, not the observed set -- rpc_bloom_next_deliveries walks
-- delivery_dows forward and returns the first TWO matches as delivery+following,
-- so encoding adjacent days collapses the lead to 1 and starves the band target
-- (caught live on wave 1's Coca-Cola {4,5} config). Tue at 76% is unambiguous.
-- =============================================================================

INSERT INTO public.bloom_route_config
  (store_code, route_key, direct_supplier_nrs, direct_cycle_weeks, status, scope, effective_from, notes)
VALUES
  ('10116','DIRECT_NATBRANDS', ARRAY[99,2071]::bigint[], 1, 'RULED', 'DEMO_CALIBRATION', CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 3 (PM queue item 1, 2026-07-17). R7.4k/wk. Identity receipt-proven 182d: 99 (64 selling, 64 recv by NB) UNION 2071 (10 selling the dominant misses, 10 recv by NB); 1543 excluded (0 selling, 0 receipts). recv_by_DC=0 on all -- genuinely direct. Cadence: median drop gap 10.5 over 16 gaps_observed, STABLE at >=1/>=2/>=3 lines-per-day floors; 10.5/7=1.50 = the exact tie, canon 7f resolves ties WEEKLY -> cycle_weeks=1 = today behaviour, no grain dependency. Distribution is bimodal 8x~7d / 8x~14d -- median is the valley between the humps, surfaced not buried (R29); the 14d legs run 7d cover until 7f''s received-drop arbiter lands. Delivery Tue 13/17 drop days (76%), single dominant day.')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  direct_supplier_nrs=EXCLUDED.direct_supplier_nrs, direct_cycle_weeks=EXCLUDED.direct_cycle_weeks,
  status=EXCLUDED.status, scope=EXCLUDED.scope, notes=EXCLUDED.notes, updated_at=now();

INSERT INTO public.supplier_calendar (store_code, route_key, delivery_dows, effective_from, source_note)
VALUES
  ('10116','DIRECT_NATBRANDS', ARRAY[2]::smallint[], CURRENT_DATE,
   'SB-CC-BLOOM-009 wave 3: receipt DOW fingerprint, 182d, supplier_nr 99+2071 -- Tue dominant, 13/17 qualifying drop days (76%) vs Mon 2, Wed 2. SINGLE day, never the observed set: next-deliveries returns the first two matching days as delivery+following, so adjacent days collapse the lead to 1 and starve the band (the wave-1 Coca-Cola {4,5} bug).')
ON CONFLICT (store_code, route_key) DO UPDATE SET
  delivery_dows=EXCLUDED.delivery_dows, source_note=EXCLUDED.source_note, updated_at=now();

SELECT pg_notify('pgrst', 'reload schema');

-- =============================================================================
-- 🔴 DIRECT_MONDELEZ 10116 IS DELIBERATELY NOT IN THIS FILE. HELD, not forgotten.
--
-- PM's queue put it in item 1 as weekly on canon 7f's stated figure (gap 9 over
-- 13 observations). Re-derived live it does not hold, and it fails item 1's own
-- gates two ways:
--
-- 1. ITS CADENCE FLIPS ON AN UNDOCUMENTED PARAMETER -- the lines-per-day noise
--    floor, which no canon item states:
--        floor >=1 : 13 gaps, median  9.0 -> 1.29 -> WEEKLY       <- 7f's figure
--        floor >=2 : 12 gaps, median 12.0 -> 1.71 -> FORTNIGHTLY
--        floor >=3 : 12 gaps, median 12.0 -> 1.71 -> FORTNIGHTLY  <- the brief's
--                                                       own mandated method
--    SB-CC-BLOOM-009 rule 2 mandates ">=3 lines/day noise floor". Canon 7d/7f's
--    figures were computed WITHOUT it. The two give OPPOSITE answers and the
--    answer decides item 1 vs item 5. 7b's accuracy gate is explicit: a desk is
--    never seeded at a known-wrong number to close a ticket. I cannot tell which
--    number is right, so I do not seed it. (The account set is NOT the cause --
--    950-only and 950+1586 give byte-identical gaps at every floor.)
--
-- 2. IT HAS NO DOMINANT DELIVERY DAY. Wed 5/13 (38%) and Thu 5/13 (38%) are tied
--    and ADJACENT. Encoding both is the exact wave-1 bug (lead collapses to 1);
--    picking one at 38% is a coin toss wearing a config value. The gate "dows
--    derived from the ledger" cannot be met -- the ledger does not carry an
--    answer.
--
-- Distribution supports the hold: bimodal, 5 gaps near 7 vs 6 near 14, max gap
-- 42 -- 7e's own "fortnightly supplier with an extra drop", which reads
-- cycle_weeks=2, which needs the 7e grain, which is queue item 3.
--
-- OPEN FOR PM: state the noise floor as a config constant (DEMO_CALIBRATION,
-- R28) and re-rule Mondelez 10116 with it. On the brief's own >=3 it is
-- fortnightly and belongs with the other three in queue item 5.
-- =============================================================================
