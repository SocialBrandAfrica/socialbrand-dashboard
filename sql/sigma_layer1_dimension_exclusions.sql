-- =============================================================================
-- sigma_layer1_dimension_exclusions.sql
-- SB-CC-CHECK8-001: Orphan carve-out rule (Check 8 follow-up)
-- 2026-06-05
-- =============================================================================
-- Purpose:
--   Creates a reusable, estate-wide rule table for non-merchandise dimension
--   codes and a filtered view of sigma_articles that the Layer 2 classification
--   engine reads instead of the raw table.
--
-- Background (VER-001 Check 8, 2026-06-05, store 10116):
--   117 orphan articles (0.17%) are structurally absent from dimension tables
--   but the merchandise dimensions (29 depts, 510 sub-depts) are intact.
--   Two non-merchandise families:
--     - Dept 0 (20 articles) -- ungrouped placeholder lines, e.g. PROSCRUB.
--       Absent from sigma_departments. Zero stock, zero sales.
--     - Sub-dept codes 2104-2199 (97 articles) -- dept-21 GL/accounting expense
--       accounts (SALARIES, RENT, PAYE, ELECTRICITY, SPAR VOUCHERS, DEBTORS
--       GENERAL, INTER BRANCH TRANSFER, DIRECTOR LOAN ACC, ADVERTISING, etc.)
--       that borrow dept-21's number range but are not merchandise. Correctly
--       absent from sigma_subdepts. Zero stock, zero sales, never in
--       daily_snapshots.
--
-- Pattern recurs estate-wide: every SPAR store piggybacks GL accounts onto a
-- high sub-dept number range. Build once, apply everywhere.
--
-- Integration with SB-AP-004:
--   Layer 2 classification engine reads v_sigma_merch_articles (not raw
--   sigma_articles) so dimension orphans never enter product_classification or
--   any merchandise-facing RPC. Same exclusion pipeline as AUTO_EXCLUDE items
--   identified by the production/ghost-stock classifier.
--
-- Run by: Pieter in Supabase SQL Editor (one step).
-- Idempotent: IF NOT EXISTS guards + INSERT ... WHERE NOT EXISTS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Step 1: create the rule-config table
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sigma_dimension_exclusions (
    rule_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id           UUID        NOT NULL,
    rule_name           TEXT        NOT NULL,
    -- Dept-level exclusion (exact match on department_nr)
    department_nr       SMALLINT,
    -- Sub-dept range exclusion (both columns set = range rule)
    merch_group_min     INTEGER,
    merch_group_max     INTEGER,
    -- Scope: NULL = estate-wide (all stores for this client)
    store_code          TEXT,
    reason              TEXT        NOT NULL,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT sigma_dimension_exclusions_has_criteria CHECK (
        department_nr IS NOT NULL
        OR (merch_group_min IS NOT NULL AND merch_group_max IS NOT NULL)
    ),
    CONSTRAINT sigma_dimension_exclusions_range_complete CHECK (
        (merch_group_min IS NULL) = (merch_group_max IS NULL)
    )
);

COMMENT ON TABLE sigma_dimension_exclusions IS
    'Estate-wide rules for non-merchandise dimension codes (GL accounts, '
    'placeholder depts) that should be excluded from merchandise-facing engine '
    'output. Pattern recurs on every SPAR store. Extend here when a new store '
    'shows the same pattern. Layer 2 engine reads v_sigma_merch_articles '
    'instead of sigma_articles directly. SB-CC-CHECK8-001 / VER-001 Check 8.';

COMMENT ON COLUMN sigma_dimension_exclusions.department_nr IS
    'Exclude all articles where sigma_articles.department_nr = this value.';
COMMENT ON COLUMN sigma_dimension_exclusions.merch_group_min IS
    'Exclude articles where sigma_articles.merch_group_nr BETWEEN merch_group_min AND merch_group_max.';
COMMENT ON COLUMN sigma_dimension_exclusions.store_code IS
    'NULL = estate-wide (all stores). Set a specific store_code to scope the rule.';

GRANT SELECT ON sigma_dimension_exclusions TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- Step 2: insert the two initial estate-wide rules (idempotent)
-- -----------------------------------------------------------------------------

-- Rule 1: dept-0 placeholder articles
INSERT INTO sigma_dimension_exclusions
    (client_id, rule_name, department_nr, reason)
SELECT
    client_id,
    'DEPT_ZERO_PLACEHOLDER',
    0,
    'Dept-0 ungrouped placeholder articles (e.g. PROSCRUB) -- absent from '
    'sigma_departments, zero stock, zero sales, never in daily_snapshots.'
FROM clients
LIMIT 1
ON CONFLICT DO NOTHING;

-- Rule 2: dept-21 GL/accounting sub-dept range 2104-2199
INSERT INTO sigma_dimension_exclusions
    (client_id, rule_name, merch_group_min, merch_group_max, reason)
SELECT
    client_id,
    'DEPT21_GL_ACCOUNTS',
    2104,
    2199,
    'Sub-dept codes 2104-2199 borrow dept-21 number range but are GL/accounting '
    'expense accounts (SALARIES, RENT, PAYE, ELECTRICITY, SPAR VOUCHERS, '
    'DEBTORS GENERAL, INTER BRANCH TRANSFER, DIRECTOR LOAN ACC, ADVERTISING). '
    'Non-merchandise, absent from sigma_subdepts, zero stock/sales, never in '
    'daily_snapshots. Pattern recurs estate-wide.'
FROM clients
LIMIT 1
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- Step 3: filtered view for Layer 2 engine use
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_sigma_merch_articles AS
SELECT a.*
FROM sigma_articles a
WHERE NOT EXISTS (
    SELECT 1
    FROM sigma_dimension_exclusions x
    WHERE x.client_id  = a.client_id
      AND x.is_active  = TRUE
      AND (x.store_code IS NULL OR x.store_code = a.store_code)
      AND (
            -- Dept-level match
            (x.department_nr IS NOT NULL
             AND a.department_nr = x.department_nr)
            -- Sub-dept range match
            OR (x.merch_group_min IS NOT NULL
                AND a.merch_group_nr BETWEEN x.merch_group_min AND x.merch_group_max)
          )
);

COMMENT ON VIEW v_sigma_merch_articles IS
    'sigma_articles filtered to exclude non-merchandise dimension codes '
    '(GL/accounting sub-depts, placeholder depts) per sigma_dimension_exclusions. '
    'Layer 2 classification engine reads this view, not the raw table. '
    'Current estate rules: dept-0 placeholder (rule DEPT_ZERO_PLACEHOLDER) and '
    'sub-dept 2104-2199 GL accounts (rule DEPT21_GL_ACCOUNTS). '
    'To add a new store''s non-merch codes: INSERT into sigma_dimension_exclusions '
    'with the appropriate store_code (or NULL for estate-wide). '
    'SB-CC-CHECK8-001 / VER-001 Check 8 / SB-AP-004.';

GRANT SELECT ON v_sigma_merch_articles TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- Step 4: verification query (run after applying -- shows excluded articles)
-- -----------------------------------------------------------------------------
-- SELECT
--     x.rule_name,
--     x.reason,
--     COUNT(*) AS excluded_articles
-- FROM sigma_articles a
-- JOIN sigma_dimension_exclusions x
--   ON x.client_id = a.client_id
--  AND x.is_active = TRUE
--  AND (x.store_code IS NULL OR x.store_code = a.store_code)
--  AND (
--        (x.department_nr IS NOT NULL AND a.department_nr = x.department_nr)
--        OR (x.merch_group_min IS NOT NULL
--            AND a.merch_group_nr BETWEEN x.merch_group_min AND x.merch_group_max)
--      )
-- GROUP BY x.rule_name, x.reason
-- ORDER BY x.rule_name;
-- Expected for store 10116:
--   DEPT_ZERO_PLACEHOLDER  -- 20 articles
--   DEPT21_GL_ACCOUNTS     -- 97 articles
