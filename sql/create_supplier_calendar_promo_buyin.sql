-- create_supplier_calendar_promo_buyin.sql
-- BUG-LOG ENG-017 / CLEANUP-ENGINE-CANON SS14 v7 item 10 (THE PROMO BUY-IN
-- WINDOW). buyin_lead_days is route/store config (DEMO_CALIBRATION,
-- SocialBrand = 7) -- supplier_calendar already carries the per-route
-- delivery_dows this window's closing bound derives from, so the lead lives
-- alongside it rather than a new table.

ALTER TABLE public.supplier_calendar
  ADD COLUMN IF NOT EXISTS promo_buyin_lead_days smallint NOT NULL DEFAULT 7;
