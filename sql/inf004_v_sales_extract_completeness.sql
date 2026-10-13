-- =============================================================================
-- inf004_v_sales_extract_completeness.sql  (BUG-LOG INF-004, platform lane 14-10-2026)
-- The silence half of INF-004: a partial or missing sigma_sales day was visible only
-- to someone who already suspected it. v_push_health is table-level freshness; it
-- cannot see a day that landed short. This view is the database-side detector.
--
-- One row per active store x completed sale_date in the last 28 days (SAST).
--   lines           sigma_sales rows landed for that store-date
--   baseline_lines  median lines of the previous 4 same-weekday dates for the store
--   pct_of_baseline lines / baseline_lines
--   verdict         MISSING   no rows on a date the store traded on in >=2 of its previous 4 same weekdays
--                   SHORT     lines < 60% of baseline (weekday-matched, so short Sundays are not flagged)
--                   OK        otherwise;  NO_BASELINE when fewer than 3 of the previous 4 same weekdays traded
-- It states what landed against what usually lands. It does NOT prove completeness at
-- source; only a source (store-server) count does that. Store list comes from
-- store_extract_config (is_active), nothing hard-coded (R25).
-- =============================================================================
create or replace view public.v_sales_extract_completeness as
with cfg as (
    select client_id, store_code, coalesce(time_zone,'Africa/Johannesburg') tz
    from public.store_extract_config where is_active
),
days as (
    select c.client_id, c.store_code, g::date as sale_date
    from cfg c
    cross join lateral generate_series(
        (now() at time zone c.tz)::date - 56, (now() at time zone c.tz)::date - 1, interval '1 day') g
),
landed as (
    select store_code, sale_date, count(*) lines, round(sum(sales_incl_vat)) sales_incl_vat
    from public.sigma_sales
    where sale_date >= current_date - 60
    group by 1,2
),
j as (
    select d.client_id, d.store_code, d.sale_date, coalesce(l.lines,0) lines, coalesce(l.sales_incl_vat,0) sales_incl_vat
    from days d left join landed l using (store_code, sale_date)
),
b as (
    select j.*,
        (select count(*) from j p where p.store_code=j.store_code and p.lines>0 and p.sale_date in
            (j.sale_date-7, j.sale_date-14, j.sale_date-21, j.sale_date-28)) prior_traded,
        (select (percentile_cont(0.5) within group (order by p.lines))::numeric from j p
            where p.store_code=j.store_code and p.lines>0 and p.sale_date in
            (j.sale_date-7, j.sale_date-14, j.sale_date-21, j.sale_date-28)) baseline_lines
    from j
)
select client_id, store_code, sale_date, to_char(sale_date,'Dy') dow, lines, sales_incl_vat,
       round(baseline_lines) baseline_lines,
       case when baseline_lines>0 then round(100.0*lines/baseline_lines,1) end pct_of_baseline,
       case when prior_traded<3 then 'NO_BASELINE'
            when lines=0 and prior_traded>=2 then 'MISSING'
            when lines < 0.6*baseline_lines then 'SHORT'
            else 'OK' end verdict
from b
where sale_date >= (select min(sale_date) from j) + 28;

comment on view public.v_sales_extract_completeness is
 'INF-004 detector: per active store and completed sale_date (last 28), sigma_sales lines landed vs the median of the previous 4 same-weekday dates. SHORT <60%, MISSING = none on a day the store normally trades. Says what landed vs usual, not source-complete.';
