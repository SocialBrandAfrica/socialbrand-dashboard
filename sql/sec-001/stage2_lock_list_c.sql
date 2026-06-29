-- =============================================================================
-- stage2_lock_list_c.sql
-- SB-CC-SEC-001 Stage 2b -- lock list C tables
-- Branch: sec-001-rls  |  ON PIETER: apply AFTER stage2_wrap_list_c.sql
--                                    AND after front-end is deployed + verified
--
-- Enables RLS on list C tables. By this point every dashboard read of these
-- tables has been routed through a SECURITY DEFINER RPC (stage2_wrap_list_c).
-- Rollback per table: ALTER TABLE x DISABLE ROW LEVEL SECURITY;
-- =============================================================================

-- push_log: PushStatusStrip + date-picker now use rpc_push_status /
--           rpc_push_available_dates. dev-corner API is server-side (service key).
ALTER TABLE public.push_log                 ENABLE ROW LEVEL SECURITY;

-- product_search_index: page.jsx now uses rpc_product_search_index.
ALTER TABLE public.product_search_index     ENABLE ROW LEVEL SECURITY;

-- product_catalog: page.jsx now uses rpc_supplier_by_ean.
ALTER TABLE public.product_catalog          ENABLE ROW LEVEL SECURITY;

-- products: FocusDrilldown now uses rpc_eans_by_supplier.
ALTER TABLE public.products                 ENABLE ROW LEVEL SECURITY;

-- daily_snapshots: retired from dashboard. dev-corner API runs server-side.
ALTER TABLE public.daily_snapshots          ENABLE ROW LEVEL SECURITY;

-- user_profiles: already RLS-on per Supabase Auth setup -- no-op if already set.
ALTER TABLE public.user_profiles            ENABLE ROW LEVEL SECURITY;
