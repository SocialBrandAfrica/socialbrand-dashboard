-- =============================================================================
-- Fresh Start Schema Fix
-- SB-AP-006 -- 2026-05-17
--
-- Run in Supabase SQL Editor before the backfill push.
--
-- What this does:
--   1. Recreates departments and sub_departments with store_code in the PK
--   2. Wipes stock_snapshots for store 10116 (stale pre-EOD snapshot)
-- =============================================================================


-- ---------------------------------------------------------------------------
-- STEP 1 -- Recreate departments with store_code in the primary key
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS departments;

CREATE TABLE departments (
    client_id  UUID  NOT NULL REFERENCES clients(client_id),
    store_code TEXT  NOT NULL,
    dept_code  TEXT  NOT NULL,
    dept_name  TEXT,
    PRIMARY KEY (client_id, store_code, dept_code)
);


-- ---------------------------------------------------------------------------
-- STEP 2 -- Recreate sub_departments with store_code in the primary key
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS sub_departments;

CREATE TABLE sub_departments (
    client_id     UUID  NOT NULL REFERENCES clients(client_id),
    store_code    TEXT  NOT NULL,
    sub_dept_code TEXT  NOT NULL,
    sub_dept_name TEXT,
    dept_code     TEXT,
    PRIMARY KEY (client_id, store_code, sub_dept_code)
);


-- ---------------------------------------------------------------------------
-- STEP 3 -- Wipe stale stock_snapshots for store 10116
-- The EOD-time snapshot is from before day-end close. It will repopulate
-- on the next nightly push run.
-- ---------------------------------------------------------------------------

DELETE FROM stock_snapshots WHERE store_code = '10116';


-- ---------------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------------

SELECT 'departments'    AS tbl, COUNT(*) AS rows FROM departments
UNION ALL
SELECT 'sub_departments', COUNT(*) FROM sub_departments
UNION ALL
SELECT 'stock_snapshots (10116)', COUNT(*) FROM stock_snapshots WHERE store_code = '10116';
