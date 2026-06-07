-- =============================================================================
-- create_sigma_promotions.sql
-- SocialBrand Intelligence Platform -- Layer 1 Sigma Promotions
-- =============================================================================
-- Reference   : SB-CC-L2-001 (PM-approved 2026-06-07)
-- Version     : 1.0
-- Date        : 2026-06-09
-- Target      : Supabase (PostgreSQL), project socialbrand-data
-- Sources     : dw220sdb.dbo.DBAKTK (headers), dw220sdb.dbo.DBAKTP (lines)
--
-- WHAT THIS IS
--   Two Layer 1 tables storing Sigma promotion data extracted nightly.
--   sigma_promotions  : one row per promotion header (DBAKTK)
--   sigma_promotion_articles : one row per article-on-promotion (DBAKTP)
--
-- HOW TO RUN:
--   Run once in Supabase SQL editor. Safe to re-run (DROP IF EXISTS).
-- =============================================================================


-- =============================================================================
-- TABLE 1: sigma_promotions (DBAKTK -- promotion headers)
-- =============================================================================

DROP TABLE IF EXISTS sigma_promotions CASCADE;

CREATE TABLE sigma_promotions (
    client_id       text        NOT NULL,
    store_code      text        NOT NULL,
    promo_nr        bigint      NOT NULL,   -- lNummer
    start_date      date,                   -- dtStart
    end_date        date,                   -- dtEnde
    promo_type      smallint,               -- siArt
    description     text,                   -- cText
    no_changes      smallint,               -- siKeineAend
    status          text,                   -- cStatus
    extracted_at    timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (client_id, store_code, promo_nr)
);

CREATE INDEX idx_sigma_promos_store_dates
    ON sigma_promotions (store_code, start_date, end_date);

CREATE INDEX idx_sigma_promos_active
    ON sigma_promotions (store_code, end_date)
    WHERE status IS DISTINCT FROM 'I';

COMMENT ON TABLE sigma_promotions IS
    'Sigma promotion headers (DBAKTK). One row per promotion per store. '
    'Refreshed nightly by Invoke-ExtractFromSigmaSQL.ps1. SB-CC-L2-001.';

GRANT SELECT ON sigma_promotions TO anon, authenticated;


-- =============================================================================
-- TABLE 2: sigma_promotion_articles (DBAKTP -- promotion lines)
-- =============================================================================

DROP TABLE IF EXISTS sigma_promotion_articles CASCADE;

CREATE TABLE sigma_promotion_articles (
    client_id           text        NOT NULL,
    store_code          text        NOT NULL,
    line_id             bigint      NOT NULL,   -- lAZaehler (auto-inc PK)
    promo_nr            bigint,                 -- lNummer (FK to sigma_promotions)
    product_code        bigint,                 -- dArtNr
    indicator           smallint,               -- siKz
    promo_date          date,                   -- dtDatum
    old_price           numeric(12,4),          -- dVkAlt
    new_price           numeric(12,4),          -- dVkNeu
    start_date          date,                   -- dtStart
    end_date            date,                   -- dtEnde
    status              text,                   -- cStatus
    level               text,                   -- cEbene
    list_cost           numeric(12,4),          -- dEKListe
    promo_qty_d1        numeric(12,4),          -- dPMg7Ta1
    promo_qty_d2        numeric(12,4),          -- dPMg7Ta2
    promo_qty_d3        numeric(12,4),          -- dPMg7Ta3
    promo_qty_d4        numeric(12,4),          -- dPMg7Ta4
    promo_qty_d5        numeric(12,4),          -- dPMg7Ta5
    promo_qty_d6        numeric(12,4),          -- dPMg7Ta6
    promo_qty_d7        numeric(12,4),          -- dPMg7Ta7
    promo_qty_w1        numeric(12,4),          -- dPMg7Wo1
    promo_qty_w2        numeric(12,4),          -- dPMg7Wo2
    promo_qty_w3        numeric(12,4),          -- dPMg7Wo3
    promo_qty_w4        numeric(12,4),          -- dPMg7Wo4
    promo_qty_w5        numeric(12,4),          -- dPMg7Wo5
    promo_qty_w6        numeric(12,4),          -- dPMg7Wo6
    qty                 numeric(12,4),          -- dMenge
    last_sale_date      date,                   -- dtVkLetzt
    follow_nr           bigint,                 -- lFolgNr
    valuation           numeric(12,4),          -- dBewert
    multi_buy_type      smallint,               -- siMultiV
    discount_amount     numeric(12,4),          -- dRabattDM
    discount_pct        numeric(8,4),           -- dRabattProz
    discount_amount_old numeric(12,4),          -- dRabattDMAlt
    discount_pct_old    numeric(8,4),           -- dRabattProzAlt
    old_price_2         numeric(12,4),          -- dVkAlt2
    new_price_2         numeric(12,4),          -- dVkNeu2
    end_stock           numeric(12,4),          -- dEndBestand
    discount_variant    smallint,               -- siRabVar
    multi_buy_group     bigint,                 -- lMultiGr
    multi_buy_min_qty   smallint,               -- siMultiMg
    multi_group_ref     bigint,                 -- lMMGr
    extracted_at        timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (client_id, store_code, line_id)
);

CREATE INDEX idx_sigma_promo_art_promo
    ON sigma_promotion_articles (store_code, promo_nr);

CREATE INDEX idx_sigma_promo_art_product
    ON sigma_promotion_articles (store_code, product_code);

CREATE INDEX idx_sigma_promo_art_dates
    ON sigma_promotion_articles (store_code, start_date, end_date);

COMMENT ON TABLE sigma_promotion_articles IS
    'Sigma promotion lines (DBAKTP). One row per article per promotion per store. '
    'line_id = lAZaehler (Sigma auto-increment PK). '
    'Refreshed nightly by Invoke-ExtractFromSigmaSQL.ps1. SB-CC-L2-001.';

GRANT SELECT ON sigma_promotion_articles TO anon, authenticated;
