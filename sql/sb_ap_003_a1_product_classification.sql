-- =============================================================================
-- SB-AP-003 Action A1 — Create product_classification table
--
-- This table holds a DERIVED classification fact for each product line, kept
-- separate from the observed Sigma data in daily_snapshots and product_catalog.
-- It is versioned (classifier_version + scored_at) and safe to re-run.
--
-- KEY DESIGN RULES (from brief §6):
--   • Never overwrite observed Sigma facts — this is a derived layer only.
--   • Keyed on (store_code, ean) — matches the daily_snapshots PK.
--   • classifier_version + scored_at let you see which run produced each row.
--   • confirmed_by / confirmed_at track human review decisions (Action A5).
--
-- BANDS (from classifier — score thresholds):
--   AUTO_EXCLUDE  score >= 5   P=93.8% R=75.0%  Safe to drop from Capital Tied.
--   REVIEW        score 2-4    P=58.8% R=100%   Must be human-confirmed.
--   STOCK         score < 2    Default treatment — retail stock.
--
-- Run once. Safe to re-run — table exists check prevents duplicate creation.
-- Load data with scripts/load_product_classification.py after this runs.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.product_classification (
    store_code          text        NOT NULL,
    ean                 text        NOT NULL,

    -- Derived classification (PRODUCTION / RETAIL / INERT / SUSPECT)
    -- Set by the loader from production_flag + quadrant fields in the CSV.
    classification      text,

    -- Actionable band: AUTO_EXCLUDE, REVIEW, or STOCK.
    -- AUTO_EXCLUDE items are excluded from Capital Tied and slow-mover count.
    -- REVIEW items need human confirmation before they become AUTO_EXCLUDE.
    band                text,

    -- Raw signal count from the classifier (0-6).
    score               int,

    -- Human-readable reasons the item was flagged (semicolon-separated).
    why_flagged         text,

    -- Which version of production_classifier.py produced this row.
    classifier_version  text,

    -- When this row was scored (set by loader).
    scored_at           timestamptz DEFAULT now(),

    -- Human review fields. NULL = auto-classified. Set by rpc_confirm_production.
    confirmed_by        text,
    confirmed_at        timestamptz,

    PRIMARY KEY (store_code, ean)
);

-- Read access: needed so views (v_kpi_by_date, rpc_*) can JOIN to this table.
GRANT SELECT ON public.product_classification TO anon, authenticated;

-- Write access: loader script and confirm RPC need this.
GRANT INSERT, UPDATE ON public.product_classification TO anon, authenticated;

-- Index on band — used by the review queue view and ghost stock report.
CREATE INDEX IF NOT EXISTS idx_pc_band
    ON public.product_classification (store_code, band);


-- ---------------------------------------------------------------------------
-- VERIFY — should return the table with its columns.
-- ---------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'product_classification'
ORDER  BY ordinal_position;
-- Expected: 11 rows — store_code, ean, classification, band, score,
--           why_flagged, classifier_version, scored_at, confirmed_by, confirmed_at
-- (PRIMARY KEY = store_code + ean)
