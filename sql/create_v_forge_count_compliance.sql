-- =====================================================================
-- create_v_forge_count_compliance.sql
-- COUNTED MEANS POSTED -- the count-compliance measure, run grain.
-- SB-CC-TOOLKIT-002 item 3 (Pieter ruling 2026-08-12).
--
-- PM applied the live view via apply_migration on Pieter's instruction
-- (migration forge_count_compliance_counted_means_posted, version
-- 20260812202638). PM cannot push to this repo, so the canonical
-- sql/create_*.sql was left owed to CC. THIS FILE is that reconcile:
-- its body is byte-faithful to the applied migration, so main and the
-- live DB do not diverge (CLEANUP-ENGINE-CANON section 13 rule 3).
--
-- Author: reconcile CC (Claude Code)   Reconciled: 2026-08-13 (system clock
-- re-read at the write, +2). The session opened 2026-08-12 and CROSSED MIDNIGHT;
-- the VIEW itself was PM-applied 2026-08-12 (migration 20260812202638), this
-- source reconcile was written 2026-08-13 -- dates taken from the artefacts.
-- Ref: SB-CC-TOOLKIT-002 item 3; Forge/PROJECT.md v3.0; canon section 15.
--
-- THE RULE. A line is counted only when its count POSTING stands in the
-- ledger. A manual confirmation in the toolkit is an assertion, not
-- evidence, and is NOT a completion source (Pieter, 2026-08-12).
--
-- EVIDENCE CHANNEL v1: sigma_movements movement_type='I' AND
-- module='DIWAINV' -- the Sigma count module. A qty=0 posting is a count
-- that CONFIRMED the system quantity (measured 10,059 of 20,942 postings
-- in 60d), so zero-variance counts ARE visible here and are counted as
-- done. A variance-only measure would have read Dice at 42% when it
-- counted 97%. Window: issue date + 2 days.
--
-- OPEN, NAMED (SB-CC-TOOLKIT-002 item 5): the StockFlow correction
-- channel (type S / class ADJUSTMENT) is NOT yet included, pending the
-- purity decode. Until it lands a store counting only via StockFlow
-- under-reads here; CC extends this view when the decode is proven, and
-- the surface states its coverage honestly ("counted, variance posted")
-- rather than dressing the floor as the whole.
--
-- SCOPE / R28: GENERAL. No fitted constant here. Read-only view; zero
-- dependents at creation.
-- =====================================================================

CREATE OR REPLACE VIEW public.v_forge_count_compliance AS
WITH posted AS (
  SELECT r.run_id,
         count(DISTINCT l.product_code) AS lines_posted,
         count(DISTINCT l.product_code) FILTER (WHERE m.qty <> 0) AS variance_posted,
         count(DISTINCT l.product_code) FILTER (WHERE m.qty = 0)  AS matched_posted
  FROM forge_count_run r
  JOIN forge_count_run_line l ON l.run_id = r.run_id
  JOIN sigma_movements m
    ON m.store_code = l.store_code AND m.product_code = l.product_code
   AND m.movement_type = 'I' AND m.module = 'DIWAINV'
   AND m.movement_date BETWEEN r.issued_at::date AND r.issued_at::date + 2
  GROUP BY r.run_id
)
SELECT r.run_id,
       r.store_code,
       r.issued_at::date               AS issued_date,
       r.source,
       r.mode,
       r.line_count                    AS lines_issued,
       COALESCE(p.lines_posted, 0)     AS lines_posted,
       COALESCE(p.variance_posted, 0)  AS variance_posted,
       COALESCE(p.matched_posted, 0)   AS matched_posted,
       round(100.0 * COALESCE(p.lines_posted, 0) / NULLIF(r.line_count, 0), 1) AS pct_counted
FROM forge_count_run r
LEFT JOIN posted p USING (run_id);

GRANT SELECT ON public.v_forge_count_compliance TO anon, authenticated;
