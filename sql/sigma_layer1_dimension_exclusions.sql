-- sigma_layer1_dimension_exclusions.sql
-- SB-CC-CHECK8-001 v3 -- estate-wide non-merch dimension exclusion rules
-- 2026-06-05
--
-- Run in three separate SQL Editor steps (one result grid each).
-- Step 1: table + seed rules  Step 2: view  Step 3: verify

-- =============================================================================
-- STEP 1 -- table + seed (paste this block, run, confirm 2 rows returned)
-- =============================================================================

DROP TABLE IF EXISTS sigma_dimension_exclusions CASCADE;

CREATE TABLE sigma_dimension_exclusions (
    rule_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id     TEXT        NOT NULL,
    rule_name     TEXT        NOT NULL,
    rule_type     TEXT        NOT NULL,
    department_nr SMALLINT,
    store_code    TEXT,
    reason        TEXT        NOT NULL,
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (client_id, rule_name),
    CHECK (rule_type IN ('DEPT_CODE', 'SUBDEPT_ORPHAN')),
    CHECK (rule_type != 'DEPT_CODE' OR department_nr IS NOT NULL)
);

GRANT SELECT ON sigma_dimension_exclusions TO anon, authenticated;

-- Source client_id from sigma_articles (TEXT slug e.g. 'socialbrand'),
-- NOT from clients table (which holds UUID PKs -- a different id space).
INSERT INTO sigma_dimension_exclusions (client_id, rule_name, rule_type, department_nr, reason)
SELECT client_id, 'DEPT_ZERO_PLACEHOLDER', 'DEPT_CODE', 0,
    'Dept-0 placeholder articles absent from sigma_departments. Zero stock/sales.'
FROM sigma_articles LIMIT 1;

INSERT INTO sigma_dimension_exclusions (client_id, rule_name, rule_type, reason)
SELECT client_id, 'SUBDEPT_ORPHAN', 'SUBDEPT_ORPHAN',
    'Sub-dept codes absent from sigma_subdepts (GL/accounting expense accounts borrowing merch number range). Self-maintaining per store.'
FROM sigma_articles LIMIT 1;

SELECT rule_name, rule_type, department_nr FROM sigma_dimension_exclusions;
-- Expected: 2 rows

-- =============================================================================
-- STEP 2 -- view (paste this block, run, confirm article count returned)
-- =============================================================================

CREATE OR REPLACE VIEW v_sigma_merch_articles AS
SELECT a.*
FROM sigma_articles a
WHERE
    NOT EXISTS (
        SELECT 1 FROM sigma_dimension_exclusions x
        WHERE x.client_id  = a.client_id
          AND x.is_active  = TRUE
          AND x.rule_type  = 'DEPT_CODE'
          AND (x.store_code IS NULL OR x.store_code = a.store_code)
          AND x.department_nr = a.department_nr
    )
    AND (
        NOT EXISTS (
            SELECT 1 FROM sigma_dimension_exclusions x
            WHERE x.client_id = a.client_id
              AND x.is_active = TRUE
              AND x.rule_type = 'SUBDEPT_ORPHAN'
              AND (x.store_code IS NULL OR x.store_code = a.store_code)
        )
        OR EXISTS (
            SELECT 1 FROM sigma_subdepts s
            WHERE s.client_id    = a.client_id
              AND s.store_code   = a.store_code
              AND s.merch_group_nr = a.merch_group_nr
        )
    );

GRANT SELECT ON v_sigma_merch_articles TO anon, authenticated;

SELECT COUNT(*) AS merch_articles FROM v_sigma_merch_articles;
-- Expected: 69,681  (69,798 total - 117 excluded)

-- =============================================================================
-- STEP 3 -- verify exclusion counts (paste this block, run, confirm totals)
-- =============================================================================

SELECT x.rule_name, COUNT(*) AS excluded_articles
FROM sigma_articles a
JOIN sigma_dimension_exclusions x
  ON x.client_id = a.client_id
 AND x.is_active = TRUE
 AND (x.store_code IS NULL OR x.store_code = a.store_code)
 AND (
       (x.rule_type = 'DEPT_CODE'
        AND a.department_nr = x.department_nr)
    OR (x.rule_type = 'SUBDEPT_ORPHAN'
        AND NOT EXISTS (
            SELECT 1 FROM sigma_subdepts s
            WHERE s.client_id    = a.client_id
              AND s.store_code   = a.store_code
              AND s.merch_group_nr = a.merch_group_nr
        ))
     )
GROUP BY x.rule_name
ORDER BY x.rule_name;
-- Expected: DEPT_ZERO_PLACEHOLDER = 20, SUBDEPT_ORPHAN = 97
