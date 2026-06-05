-- =============================================================================
-- sigma_layer1_dimension_exclusions.sql
-- SB-CC-CHECK8-001 v2: Orphan carve-out rule (Check 8 follow-up)
-- 2026-06-05 — v1 REJECTED (numeric range wrongly excluded 38 legit articles)
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
--     - Dept 0 (20 articles): ungrouped placeholder lines, e.g. PROSCRUB.
--       Absent from sigma_departments. Zero stock, zero sales.
--     - 67 sub-dept codes (97 articles): GL/accounting expense accounts that
--       borrow dept-21 number range but are absent from sigma_subdepts
--       (SALARIES, RENT, PAYE, ELECTRICITY, SPAR VOUCHERS, DEBTORS GENERAL,
--       INTER BRANCH TRANSFER, DIRECTOR LOAN ACC, ADVERTISING, etc.).
--       Zero stock, zero sales, never in daily_snapshots.
--
-- WHY A RANGE RULE WOULD BE WRONG:
--   v1 (commit 6370097) used merch_group_nr BETWEEN 2104 AND 2199.
--   PM verified via MCP: that range also contains 11 legitimate subdepts with
--   38 real merchandise articles (range total = 135, not 97) -- 38 live products
--   would have been wrongly excluded from merchandise-facing views.
--   NEVER key exclusion on a numeric range. Key on the orphan condition.
--
-- CORRECT RULE (this file):
--   DEPT_CODE:    exclude where department_nr = 0 (exact, no range).
--   SUBDEPT_ORPHAN: exclude where merch_group_nr is not present in
--                   sigma_subdepts for the same client+store -- i.e. the
--                   sub-dept has no dimension row. Self-maintaining on rollout:
--                   no hardcoded range, adapts automatically per store.
--
-- Acceptance (store 10116):
--   v_sigma_merch_articles excludes exactly 117 articles:
--     DEPT_ZERO_PLACEHOLDER  -> 20 articles
--     SUBDEPT_ORPHAN         -> 97 articles
--   The 38 legitimate articles in the 2104-2199 range REMAIN in the view.
--
-- Pattern recurs estate-wide: every SPAR store piggybacks GL accounts onto a
-- high sub-dept number range. Add new stores by INSERT -- no code change.
--
-- Integration with SB-AP-004:
--   Layer 2 classification engine reads v_sigma_merch_articles (not raw
--   sigma_articles) so dimension orphans never enter product_classification or
--   any merchandise-facing RPC. Same exclusion pipeline as AUTO_EXCLUDE items.
--
-- Run by: Pieter in Supabase SQL Editor (one step, idempotent).
-- VERIFY with the query at the bottom before considering done.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Step 0: fix column type if table was created with UUID (from aborted first run)
-- sigma_articles.client_id is TEXT; sigma_dimension_exclusions must match.
-- IF NOT EXISTS means CREATE TABLE below is skipped on re-runs, so we ALTER instead.
-- Safe on fresh installs (IF EXISTS is a no-op) and idempotent (TEXT->TEXT is a no-op).
-- -----------------------------------------------------------------------------

ALTER TABLE IF EXISTS sigma_dimension_exclusions
    ALTER COLUMN client_id TYPE TEXT USING client_id::text;

-- -----------------------------------------------------------------------------
-- Step 1: create the rule-config table
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sigma_dimension_exclusions (
    rule_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id           TEXT        NOT NULL,   -- TEXT to match sigma_articles.client_id
    rule_name           TEXT        NOT NULL,
    -- DEPT_CODE    : exclude articles where department_nr = this value (exact)
    -- SUBDEPT_ORPHAN: exclude articles whose merch_group_nr has no row in
    --                 sigma_subdepts for the same client + store
    rule_type           TEXT        NOT NULL,
    department_nr       SMALLINT,              -- required when rule_type = 'DEPT_CODE'
    store_code          TEXT,                  -- NULL = estate-wide (all stores)
    reason              TEXT        NOT NULL,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT sigma_dimension_exclusions_uq      UNIQUE (client_id, rule_name),
    CONSTRAINT sigma_dimension_exclusions_type    CHECK  (rule_type IN ('DEPT_CODE', 'SUBDEPT_ORPHAN')),
    CONSTRAINT sigma_dimension_exclusions_dept_nr CHECK  (rule_type != 'DEPT_CODE' OR department_nr IS NOT NULL)
);

COMMENT ON TABLE sigma_dimension_exclusions IS
    'Estate-wide rules for non-merchandise dimension codes (GL accounts, '
    'placeholder depts) excluded from merchandise-facing engine output. '
    'Two rule types: DEPT_CODE (exact dept match) and SUBDEPT_ORPHAN (merch '
    'group absent from sigma_subdepts for the same store -- self-maintaining, '
    'no hardcoded range). Layer 2 engine reads v_sigma_merch_articles. '
    'SB-CC-CHECK8-001 v2 / VER-001 Check 8 / SB-AP-004.';

COMMENT ON COLUMN sigma_dimension_exclusions.rule_type IS
    'DEPT_CODE: excludes articles where department_nr equals the stored value. '
    'SUBDEPT_ORPHAN: excludes articles whose merch_group_nr has no matching row '
    'in sigma_subdepts for the same client+store (orphan condition -- never a range).';

GRANT SELECT ON sigma_dimension_exclusions TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- Step 2: insert the two initial estate-wide rules (idempotent)
-- -----------------------------------------------------------------------------

-- Rule 1: dept-0 placeholder articles (exact dept match)
INSERT INTO sigma_dimension_exclusions
    (client_id, rule_name, rule_type, department_nr, reason)
SELECT
    client_id,
    'DEPT_ZERO_PLACEHOLDER',
    'DEPT_CODE',
    0,
    'Dept-0 ungrouped placeholder articles (e.g. PROSCRUB) -- absent from '
    'sigma_departments. Zero stock, zero sales, never in daily_snapshots.'
FROM clients
LIMIT 1
ON CONFLICT (client_id, rule_name) DO NOTHING;

-- Rule 2: subdept orphans (absent from sigma_subdepts, estate-wide)
-- Note: no department_nr column -- the rule is the orphan condition itself.
INSERT INTO sigma_dimension_exclusions
    (client_id, rule_name, rule_type, reason)
SELECT
    client_id,
    'SUBDEPT_ORPHAN',
    'SUBDEPT_ORPHAN',
    'Sub-dept codes present in sigma_articles but absent from sigma_subdepts '
    'for the same store -- GL/accounting expense accounts borrowing a merch '
    'number range (SALARIES, RENT, PAYE, ELECTRICITY, SPAR VOUCHERS, DEBTORS '
    'GENERAL, INTER BRANCH TRANSFER, DIRECTOR LOAN ACC, ADVERTISING, etc.). '
    'Non-merchandise. Self-maintaining: no hardcoded range, auto-adapts per store.'
FROM clients
LIMIT 1
ON CONFLICT (client_id, rule_name) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Step 3: filtered view for Layer 2 engine use
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_sigma_merch_articles AS
SELECT a.*
FROM sigma_articles a
WHERE
    -- DEPT_CODE: exclude articles whose department_nr matches an active rule
    NOT EXISTS (
        SELECT 1
        FROM sigma_dimension_exclusions x
        WHERE x.client_id   = a.client_id
          AND x.is_active   = TRUE
          AND x.rule_type   = 'DEPT_CODE'
          AND (x.store_code IS NULL OR x.store_code = a.store_code)
          AND x.department_nr = a.department_nr
    )
    -- SUBDEPT_ORPHAN: keep the article if either
    --   (a) no SUBDEPT_ORPHAN rule is active for this client+store, OR
    --   (b) the article's merch_group_nr IS present in sigma_subdepts
    -- Exclusion occurs only when a rule is active AND the sub-dept is absent.
    AND (
        NOT EXISTS (
            SELECT 1
            FROM sigma_dimension_exclusions x
            WHERE x.client_id = a.client_id
              AND x.is_active = TRUE
              AND x.rule_type = 'SUBDEPT_ORPHAN'
              AND (x.store_code IS NULL OR x.store_code = a.store_code)
        )
        OR EXISTS (
            SELECT 1
            FROM sigma_subdepts s
            WHERE s.client_id    = a.client_id
              AND s.store_code   = a.store_code
              AND s.merch_group_nr = a.merch_group_nr
        )
    );

COMMENT ON VIEW v_sigma_merch_articles IS
    'sigma_articles pre-filtered to remove non-merchandise dimension codes '
    'per sigma_dimension_exclusions. Layer 2 classification engine reads this '
    'view, not the raw table. DEPT_CODE rules exclude on exact dept match; '
    'SUBDEPT_ORPHAN rules exclude where the sub-dept is absent from '
    'sigma_subdepts (self-maintaining -- no hardcoded range). '
    'Store 10116 expected exclusions: 20 (DEPT_ZERO_PLACEHOLDER) + '
    '97 (SUBDEPT_ORPHAN) = 117. To add a new store rule: '
    'INSERT into sigma_dimension_exclusions with the appropriate store_code '
    '(or NULL for estate-wide). SB-CC-CHECK8-001 v2 / VER-001 Check 8.';

GRANT SELECT ON v_sigma_merch_articles TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- Step 4: MANDATORY verification query
-- Run this after applying. Expected for store 10116: 20 + 97 = 117 excluded.
-- The 38 legitimate articles in the 2104-2199 range must NOT appear here.
-- -----------------------------------------------------------------------------
--
-- -- Excluded counts by rule:
-- SELECT x.rule_name, x.rule_type, COUNT(*) AS excluded_articles
-- FROM sigma_articles a
-- WHERE
--     -- DEPT_CODE match
--     EXISTS (
--         SELECT 1 FROM sigma_dimension_exclusions x
--         WHERE x.client_id = a.client_id AND x.is_active = TRUE
--           AND x.rule_type = 'DEPT_CODE'
--           AND (x.store_code IS NULL OR x.store_code = a.store_code)
--           AND x.department_nr = a.department_nr
--     )
-- CROSS JOIN LATERAL (
--     SELECT rule_name, rule_type FROM sigma_dimension_exclusions
--     WHERE client_id = a.client_id AND is_active = TRUE AND rule_type = 'DEPT_CODE'
--       AND (store_code IS NULL OR store_code = a.store_code)
--       AND department_nr = a.department_nr LIMIT 1
-- ) x
-- GROUP BY x.rule_name, x.rule_type
-- UNION ALL
-- SELECT x.rule_name, x.rule_type, COUNT(*)
-- FROM sigma_articles a
-- JOIN sigma_dimension_exclusions x
--   ON x.client_id = a.client_id AND x.is_active = TRUE
--  AND x.rule_type = 'SUBDEPT_ORPHAN'
--  AND (x.store_code IS NULL OR x.store_code = a.store_code)
-- WHERE NOT EXISTS (
--     SELECT 1 FROM sigma_subdepts s
--     WHERE s.client_id = a.client_id AND s.store_code = a.store_code
--       AND s.merch_group_nr = a.merch_group_nr
-- )
-- GROUP BY x.rule_name, x.rule_type;
--
-- -- Total: must equal 117 for store 10116.
-- -- Total articles in view: must equal 69,798 - 117 = 69,681.
-- SELECT COUNT(*) AS merch_article_count FROM v_sigma_merch_articles;
