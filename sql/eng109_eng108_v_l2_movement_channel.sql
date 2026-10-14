-- ENG-108 / ENG-109: v_l2_movement_channel, additive. S/L = TRANSFER_IN, S/M = TRANSFER_OUT; the valuation is carried as its own columns (cost_basis, cost_value_money). authenticated and service_role only, no anonymous access.
-- l2_movements_typed (13 dependents) is not rebuilt; its fold-in waits for the next planned L2 chain rebuild.
-- Before (14-10 ~01:13 SAST, matview): 5,000 rows typed ADJUSTMENT = 2,462 S/L + 2,538 S/M, window 2026-04-15..2026-10-14, five stores.
-- After (14-10 ~17:1x SAST, this view): TRANSFER_IN 2,462, TRANSFER_OUT 2,538, sign violations 0, rand reachable 0.
create or replace view public.v_l2_movement_channel as
with decode(movement_type, movement_process, channel_class, transfer_direction, cost_basis) as (
  values ('S','L','TRANSFER_IN','IN','CASE_PRICED_NOT_MONEY'),
         ('S','M','TRANSFER_OUT','OUT','CASE_PRICED_NOT_MONEY'))
select m.id as source_id, m.client_id, m.store_code, m.movement_id, m.product_code,
       m.movement_type, m.movement_process, m.movement_date, m.movement_time,
       m.qty, m.new_soh, m.retail_value, m.cost_value,
       m.supplier_nr, m.order_nr, m.grv_nr, m.module, m.user_name, m.article_text, m.ingested_at,
       coalesce(d.channel_class,
         case when m.movement_type='R' and m.movement_process='W' then 'RECEIPT'
              when m.movement_type='I' and m.movement_process='M' then 'IDT'
              when m.movement_type='S' then 'ADJUSTMENT'
              when m.movement_type='K' then 'EOD_CORRECTION'
              else 'OTHER' end)                              as movement_class,
       (m.movement_type='I' and m.movement_process='M')      as is_excluded,
       d.transfer_direction,
       (d.channel_class is not null)                         as is_group_internal,
       d.cost_basis,
       case when d.cost_basis is null then m.cost_value end  as cost_value_money,
       case d.transfer_direction when 'IN' then m.qty>0 when 'OUT' then m.qty<0 end as leg_sign_ok
from public.sigma_movements m
left join decode d on d.movement_type=m.movement_type and d.movement_process=m.movement_process;
revoke all on public.v_l2_movement_channel from public, anon;
grant select on public.v_l2_movement_channel to authenticated, service_role;
comment on view public.v_l2_movement_channel is 'GRADE: VERDICT. ENG-109/ENG-108. Superset of l2_movements_typed: S/L = TRANSFER_IN, S/M = TRANSFER_OUT, the rest unchanged. cost_value_money is NULL on the transfer legs because their cost_value is case-priced against single qty (BUG-LOG ENG-108): units are sound, the rand is not; cost_basis names why. ACL: authenticated + service_role only. Always filter store_code + movement_type/process (+date) to use idx_sigma_moves_type. S/L is uppercase L, S/l is a different channel. The matview l2_movements_typed still types these rows ADJUSTMENT until the planned rebuild.';
select pg_notify('pgrst','reload schema');