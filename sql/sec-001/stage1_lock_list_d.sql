-- =============================================================================
-- stage1_lock_list_d.sql
-- SB-CC-SEC-001 Stage 1 -- lock the raw engine tables
-- Branch: sec-001-rls  |  ON PIETER: apply in Supabase SQL editor
--
-- Enables RLS on every raw Sigma / L2 engine table (list D from the brief).
-- NO anon policy is added -- so anon direct SELECT returns zero rows / error.
-- SECURITY DEFINER RPCs bypass RLS (run as postgres, superuser) -- unaffected.
-- Non-security_invoker views (list B) run as owner (postgres) -- unaffected.
-- Matviews store their own data -- unaffected.
-- Rollback per table: ALTER TABLE x DISABLE ROW LEVEL SECURITY;
--
-- Zero UI impact. Verify dashboard panels after applying.
-- =============================================================================

-- ── Sigma L1 raw tables ──────────────────────────────────────────────────────
ALTER TABLE public.sigma_sales              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_movements          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_articles           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_lifecycle          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_orders             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_order_lines        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_supplier_link      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_supplier_master    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_trade_terms        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_ean_master         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_departments        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_subdepts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_scan_refs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_promotions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_promotion_articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sigma_dimension_exclusions ENABLE ROW LEVEL SECURITY;

-- ── L2 engine tables ─────────────────────────────────────────────────────────
ALTER TABLE public.l2_soh_daily             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_classification        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_anomaly_daily         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_consignment_daily     ENABLE ROW LEVEL SECURITY;

-- ── Bonnie Tyler engine tables ───────────────────────────────────────────────
ALTER TABLE public.l2_bt_scope              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.l2_bt_baseline           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bt_actions               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bt_out_events            ENABLE ROW LEVEL SECURITY;

-- ── Internal logs + config (never anon-readable) ─────────────────────────────
ALTER TABLE public.push_errors              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_extract_config     ENABLE ROW LEVEL SECURITY;
