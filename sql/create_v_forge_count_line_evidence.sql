-- =====================================================================
-- create_v_forge_count_line_evidence.sql
-- THE ACTUAL LINES -- count compliance at line grain (the evidence).
-- SB-CC-TOOLKIT-002 item 3 (Pieter, 2026-08-12).
--
-- PM applied the live view via apply_migration on Pieter's instruction
-- (migration forge_count_line_evidence, version 20260812202924). PM
-- cannot push to this repo, so the canonical sql/create_*.sql was left
-- owed to CC. THIS FILE is that reconcile: its body is byte-faithful to
-- the applied migration, so main and the live DB do not diverge
-- (CLEANUP-ENGINE-CANON section 13 rule 3).
--
-- Author: reconcile CC (Claude Code)   Created: 2026-08-12 (system clock,
-- local / machine-UTC / DB now() cross-checked at +2)
-- Ref: SB-CC-TOOLKIT-002 item 3; companion to v_forge_count_compliance.
--
-- THE MEASURE IS THE INTERSECTION, STATED LINE BY LINE. The toolkit
-- supplies only the WORKLIST side; completion comes only from
-- sigma_movements I/DIWAINV. Every issued worklist line is carried, with
-- the Sigma count posting that stands against it or NULL. counted = a
-- posting exists in [issued_date, +2]; a qty=0 posting = the count
-- confirmed the system quantity (matched). Where a matched and a
-- variance posting both exist, the LATERAL prefers the matched-zero row
-- (ORDER BY movement_date, qty<>0) -- either way it is evidence a count
-- happened.
--
-- SCOPE / R28: GENERAL. Read-only view; zero dependents at creation.
-- =====================================================================

CREATE OR REPLACE VIEW public.v_forge_count_line_evidence AS
SELECT r.run_id,
       r.store_code,
       r.issued_at::date AS issued_date,
       l.product_code,
       l.description,
       l.stratum,
       l.soh_at_issue,
       m.movement_date  AS counted_date,
       m.qty            AS count_delta_qty,
       m.new_soh        AS counted_soh,
       (m.product_code IS NOT NULL) AS counted
FROM forge_count_run r
JOIN forge_count_run_line l ON l.run_id = r.run_id
LEFT JOIN LATERAL (
  SELECT sm.product_code, sm.movement_date, sm.qty, sm.new_soh
  FROM sigma_movements sm
  WHERE sm.store_code = l.store_code AND sm.product_code = l.product_code
    AND sm.movement_type = 'I' AND sm.module = 'DIWAINV'
    AND sm.movement_date BETWEEN r.issued_at::date AND r.issued_at::date + 2
  ORDER BY sm.movement_date, sm.qty <> 0
  LIMIT 1
) m ON true;

GRANT SELECT ON public.v_forge_count_line_evidence TO anon, authenticated;
