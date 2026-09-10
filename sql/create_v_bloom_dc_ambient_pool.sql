-- create_v_bloom_dc_ambient_pool.sql
--
-- public.v_bloom_dc_ambient_pool -- THE DC-AMBIENT BUY-AND-SELL POOL (SB-CC-DCBUDGET-001,
-- ENG-091, 2026-08-16). The ONE definition of "DC ambient" as a supplier stream: the
-- store's RULED DC cycle department set (bloom_dc_config.dc_cycle_dept_nrs) crossed with
-- World-1 lines (l2_stock_position.class = 'NORMAL'). Created live 2026-08-16 (migration
-- dcbudget_ambient_pool_view_and_per_delivery_balance, 20260816163755). No create file
-- followed, so a rebuild from this repo did not produce it. That is BUG-LOG ENG-175
-- half (a), and this file closes it.
--
-- THIS FILE CARRIES THE LIVE DDL, read back from the catalog on 2026-09-10. The body is
-- pg_get_viewdef(..., true), md5 abd24dac072cde2b5b03c8c1148221fb at capture. Before
-- commit it was gated against live: a temp view built from this exact body returned the
-- same pg_get_viewdef md5, and the COMMENT body below hashes to the live comment.
-- Re-applying this file to the live database is a no-op.
--
-- READERS, verified at source on 2026-09-10: refresh_order_budget_ledger_needs and
-- rpc_bloom_delivery_budget.
--
-- THE LIVE COMMENT NAMES A THIRD CONSUMER THAT DOES NOT READ IT. It lists
-- rpc_project_route_sales_budget, and that function never references this view. It
-- carries the same predicate INLINE (bloom_dc_config.dc_cycle_dept_nrs plus
-- class = 'NORMAL'), which DB-SCHEMA's own entry for this view calls drift: "a second
-- copy of this predicate anywhere is drift." The two copies agree only for as long as
-- nobody edits one of them. Named here and not changed: the projection feeds the NEEDS
-- budget, so a repoint touches the money path and lands on its own R22.
--
-- CASCADE-CLASS: this view reads the matview l2_stock_position, so
-- DROP MATERIALIZED VIEW l2_stock_position CASCADE drops it. It was created after the
-- 2026-08-08 re-derivation of that list and appears in neither canon §13 nor DB-SCHEMA.
-- Re-derive the dependent set at the rebuild, never trust a written list.
--
-- ACCESS, live: no reloptions, so the view runs with its OWNER's rights (postgres), not
-- the caller's (security_invoker is not set). The `m` (MAINTAIN) privilege on anon and
-- authenticated comes from the platform's default privileges and is reproduced, not
-- granted, here. Live ACL at capture:
--   {postgres=arwdDxtm/postgres,anon=rm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}

CREATE OR REPLACE VIEW public.v_bloom_dc_ambient_pool AS
 SELECT sp.store_code,
    sp.product_code,
    sp.department_nr,
    dc.format_group
   FROM l2_stock_position sp
     JOIN bloom_dc_config dc ON dc.store_code = sp.store_code AND dc.status = 'RULED'::text
  WHERE (sp.department_nr = ANY (dc.dc_cycle_dept_nrs)) AND sp.class = 'NORMAL'::text;

COMMENT ON VIEW public.v_bloom_dc_ambient_pool IS $c$GRADE: CALCULATED. The DC ambient buy and sell pool. The config department set crossed with World-1 lines.
THE DC-ambient buy-and-sell pool (SB-CC-DCBUDGET-001, 2026-08-16). Ambient departments from bloom_dc_config.dc_cycle_dept_nrs x World-1 (l2_stock_position.class = NORMAL). This is the ONE definition of "DC ambient" as a supplier stream: the budget is projected over it, the committed/landed figure is measured on it, and the per-delivery balance is cut from it. DC fresh, production, non-stock and unclassified lines are out by construction, and directs/dropship are out because they are not type-Z DC supply at all. Store #6 inherits it unchanged: the dept set is config, the class is derived. Consumers: rpc_project_route_sales_budget, refresh_order_budget_ledger_needs, rpc_bloom_delivery_budget.$c$;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_bloom_dc_ambient_pool FROM anon, authenticated;
GRANT SELECT ON public.v_bloom_dc_ambient_pool TO anon, authenticated;
