-- =============================================================================
-- bt_001_scope.sql
-- SB-CC-BT-001 Bonnie Tyler Measurement Instruments -- Step 1
-- l2_bt_scope table + seed (12 rows, idempotent)
-- Branch: bt-instruments-001  |  R28: GENERAL, effective_from 2026-06-01
-- ON PIETER: run first -- everything else keys off this table
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.l2_bt_scope (
    store_code      text    NOT NULL,
    merch_group_nr  integer NOT NULL,
    label           text    NOT NULL,
    bucket          text    NOT NULL CHECK (bucket IN ('GROC_DLY','HABA_DLY','HABA_ROOS')),
    effective_from  date    NOT NULL DEFAULT '2026-06-01',
    rule_scope      text    NOT NULL DEFAULT 'GENERAL',
    CONSTRAINT l2_bt_scope_pk PRIMARY KEY (store_code, merch_group_nr)
);

-- Seed 12 rows (ON CONFLICT keeps table idempotent on re-run)
INSERT INTO public.l2_bt_scope (store_code, merch_group_nr, label, bucket)
VALUES
    ('10116', 921,  'Rations Maize',           'GROC_DLY'),
    ('10116', 911,  'B/fast Cereals',           'GROC_DLY'),
    ('10116', 904,  'Bev Sugar & Sweeteners',   'GROC_DLY'),
    ('10116', 930,  'Cooking Oils',             'GROC_DLY'),
    ('10116', 1105, 'Baby Food',                'HABA_DLY'),
    ('10116', 1129, 'Skincare Female H&B',      'HABA_DLY'),
    ('10116', 1124, 'Personal Wash Bar Soap',   'HABA_DLY'),
    ('10116', 1123, 'Oral Care',                'HABA_DLY'),
    ('10116', 1111, 'Deodorants Male',          'HABA_DLY'),
    ('80175', 1134, 'Toilet Paper',             'HABA_ROOS'),
    ('80175', 1122, 'Medicinal',                'HABA_ROOS'),
    ('80175', 1105, 'Baby Food',                'HABA_ROOS')
ON CONFLICT (store_code, merch_group_nr) DO UPDATE SET
    label          = EXCLUDED.label,
    bucket         = EXCLUDED.bucket,
    effective_from = EXCLUDED.effective_from;
