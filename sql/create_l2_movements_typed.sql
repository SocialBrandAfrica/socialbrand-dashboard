-- =============================================================================
-- create_l2_movements_typed.sql
-- SocialBrand Intelligence Platform -- Layer 2, Step 1
-- =============================================================================
-- Reference   : SB-CC-L2-001 v1.0 (build-order step 1)
-- Version     : 1.0
-- Date        : 2026-06-07
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Source      : sigma_movements (dw220sdb.DBBEBE, Layer 1)
--
-- WHAT THIS IS
--   Layer 2 materialised view over sigma_movements that classifies every
--   movement row by cTyp/cVorg. IDT and (future) IBT are flagged
--   is_excluded=TRUE so every KPI and classification query can simply filter
--   on that column without repeating the type/process logic.
--
--   Movement classes (derived from RULE-BOOK R13/R14, NORTH_STAR Rules 13-14):
--     RECEIPT        cTyp='R' AND cVorg='W'  -- goods received from supplier
--     IDT            cTyp='I' AND cVorg='M'  -- inter-dept transfer (R0 signature,
--                                               never a sale, NORTH_STAR Rule 13)
--     ADJUSTMENT     cTyp='S'                -- returns, reversals, write-offs
--     EOD_CORRECTION cTyp='K'               -- end-of-day stock corrections
--     OTHER          everything else
--
--   IBT (inter-branch transfer): NORTH_STAR Rule 13 says IBTs appear in DBBEBE
--   with the receiving store code as supplier_nr. With only 10116 loaded, no IBT
--   rows exist yet. The is_excluded flag is designed to absorb IBT without schema
--   change when multi-store data lands: add the supplier_nr check inside the CASE.
--
-- OBSERVED DISTRIBUTION (10116, verified 2026-06-07, 1,340,758 rows):
--   K/null   1,082,607 rows  EOD corrections (81%)
--   R/W        169,144 rows  receipts
--   I/M         45,297 rows  IDT (cost_value = R0 confirmed)
--   S/O         30,503 rows  adjustment
--   S/l          7,165 rows  adjustment
--   S/Z          3,282 rows  adjustment
--   S/M            922 rows  adjustment
--   S/L            721 rows  adjustment (positive retail -- reversal)
--   S/G            640 rows  adjustment
--   S/D            476 rows  adjustment
--   E/W              1 row   other
--
-- HOW TO RUN
--   Supabase SQL Editor or apply_migration. DROP before CREATE (Rule 19).
--   REFRESH MATERIALIZED VIEW l2_movements_typed; -- nightly, before l2_rate_of_sale
-- =============================================================================


-- Drop and clean recreate (Rule 19: no ALTER workarounds)
DROP MATERIALIZED VIEW IF EXISTS l2_movements_typed CASCADE;


CREATE MATERIALIZED VIEW l2_movements_typed AS
SELECT
    -- Source keys (pass-through for joins)
    id                  AS source_id,
    client_id,
    store_code,
    movement_id,
    product_code,

    -- Movement identity
    movement_type,
    movement_process,
    movement_date,
    movement_time,

    -- Quantities and values
    qty,
    new_soh,
    retail_value,
    cost_value,

    -- References
    supplier_nr,
    order_nr,
    grv_nr,
    module,
    user_name,
    article_text,
    ingested_at,

    -- Layer 2 classification (NORTH_STAR Rules 13-14, RULE-BOOK R13)
    CASE
        WHEN movement_type = 'R' AND movement_process = 'W' THEN 'RECEIPT'
        WHEN movement_type = 'I' AND movement_process = 'M' THEN 'IDT'
        WHEN movement_type = 'S'                            THEN 'ADJUSTMENT'
        WHEN movement_type = 'K'                            THEN 'EOD_CORRECTION'
        ELSE                                                     'OTHER'
    END AS movement_class,

    -- Convenience flag: TRUE = exclude from revenue/capital figures
    -- IDT: R0 signature, moves stock between departments, never a sale.
    -- IBT: will be added here when multi-store data is loaded -- see note above.
    (movement_type = 'I' AND movement_process = 'M') AS is_excluded

FROM sigma_movements;


-- Indexes for the three primary access patterns:
--   1. Per-product movement history (stock position engine, integrity checks)
CREATE UNIQUE INDEX IF NOT EXISTS idx_l2_mvtyped_movid
    ON l2_movements_typed (store_code, movement_id);

CREATE INDEX IF NOT EXISTS idx_l2_mvtyped_prod_date
    ON l2_movements_typed (store_code, product_code, movement_date DESC);

--   2. Class-level sweep (e.g. all RECEIPTs in a window for stock integrity)
CREATE INDEX IF NOT EXISTS idx_l2_mvtyped_class_date
    ON l2_movements_typed (store_code, movement_class, movement_date DESC);

--   3. Exclusion filter (is_excluded = TRUE for IDT/IBT audit)
CREATE INDEX IF NOT EXISTS idx_l2_mvtyped_excluded
    ON l2_movements_typed (store_code, is_excluded, movement_date DESC)
    WHERE is_excluded = TRUE;


COMMENT ON MATERIALIZED VIEW l2_movements_typed IS
    'Layer 2 movement classification over sigma_movements (DBBEBE). '
    'Adds movement_class (RECEIPT/IDT/ADJUSTMENT/EOD_CORRECTION/OTHER) and '
    'is_excluded flag (TRUE for IDT; IBT to be added when multi-store loads). '
    'Refresh nightly before l2_rate_of_sale. SB-CC-L2-001 step 1.';
