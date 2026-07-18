-- create_v_supplier_class.sql
-- Programmatic supplier delivery/payment classification, derived from the Sigma-native supplier type
-- (DBLFTS.TYP), NEVER from names (R21/R22). One row per (store, supplier). Makes the dropshipment
-- class a first-class, queryable fact so creditors, repayment terms and supplier-performance modules
-- are defined up front (Pieter ruling 2026-07-18). Applied live, migration supplier_class_01_v_supplier_class.
--
-- Class map (DEDUCTIVE -- true by construction of the Sigma type code; NORTH_STAR Z=DC/S=DRP/F=DIR):
--   Z -> DC        : delivered AND payable via the SPAR DC.
--   S -> DROPSHIP  : DRP -- delivers on its OWN truck (own R/W receipts) but is PAYABLE via the DC
--                    creditor. NOT pooled into the DC for orders/deliveries; tracked distinctly for
--                    creditor/repayment/performance. All brand desks (Clover/Coca-Cola/Simba/Danone/
--                    National Brands/Mondelez-via-Super-Group) are this class.
--   F -> DIRECT    : delivers on its own AND is payable direct (own creditor). e.g. SAB.
-- Group-wide (2026-07-18): DROPSHIP 12,871 (142 deliver own), DIRECT 822 (64), DC 101 (8). No nulls/other.
--
-- delivers_own_182d = liveness: which suppliers actually ran a truck lately. Active dropship desks =
-- DROPSHIP + delivers_own_182d + supplier_group=3.
--
-- KNOWN L1 GAP (R23): creditor_nr is NULL on ALL 13,794 rows -- the "payable-via" creditor account
-- (the DC creditor a DROPSHIP supplier settles through) is not yet extracted (Sigma DBLFTB). Add it to
-- L1 before the finance modules resolve WHICH creditor a dropshipment supplier pays through. Named, not
-- silently assumed; supplier_type is the current dropshipment marker.
CREATE OR REPLACE VIEW public.v_supplier_class AS
SELECT
  sm.store_code,
  sm.supplier_nr,
  sm.supplier_type,
  sm.supplier_group,
  CASE sm.supplier_type
    WHEN 'Z' THEN 'DC'
    WHEN 'S' THEN 'DROPSHIP'
    WHEN 'F' THEN 'DIRECT'
    ELSE 'UNKNOWN'
  END AS supplier_class,
  sm.creditor_nr,            -- L1 GAP: NULL on all rows (see header)
  sm.terms_nr,
  sm.order_method,
  sm.settle_disc_1_pct, sm.settle_disc_1_days,
  sm.settle_disc_2_pct, sm.settle_disc_2_days,
  sm.status,
  sm.name,
  EXISTS (
    SELECT 1 FROM sigma_movements m
    WHERE m.store_code = sm.store_code AND m.supplier_nr = sm.supplier_nr
      AND m.movement_type = 'R' AND m.movement_process = 'W'
      AND m.movement_date >= CURRENT_DATE - 182
  ) AS delivers_own_182d
FROM sigma_supplier_master sm;

COMMENT ON VIEW public.v_supplier_class IS
  'Supplier delivery/payment class derived from Sigma supplier_type (Z=DC, S=DROPSHIP/DRP, F=DIRECT), R21/R22. DROPSHIP delivers own but pays via the DC creditor -- never pooled into DC ordering, tracked distinctly for creditors/repayment/performance (Pieter 2026-07-18). L1 GAP: creditor_nr NULL on all rows, the DC-creditor linkage is not yet extracted (R23).';

REVOKE ALL ON public.v_supplier_class FROM PUBLIC;
GRANT SELECT ON public.v_supplier_class TO authenticated;
