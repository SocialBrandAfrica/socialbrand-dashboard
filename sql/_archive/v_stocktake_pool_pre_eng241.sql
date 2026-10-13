-- v_stocktake_pool as shipped by ENG-240 (soh <> 0 pool). Restore with this, then DROP the three
-- added columns by recreating the view WITHOUT them (DROP VIEW then CREATE VIEW, grants as in ENG-240).
CREATE OR REPLACE VIEW public.v_stocktake_pool AS
SELECT sp.client_id,
       sp.store_code,
       sp.product_code,
       sp.description,
       sp.dept_name,
       sp.subdept_name,
       sp.soh,
       sp.capital_value,
       sp.unit_cost,
       lc.last_counted_date,
       (lc.last_counted_date IS NOT NULL
        AND lc.last_counted_date >= ((now() AT TIME ZONE s.timezone)::date - 91)) AS counted_91
FROM public.l2_stock_position sp
JOIN public.sigma_articles a ON a.store_code = sp.store_code AND a.product_code = sp.product_code
JOIN public.stores s ON s.store_code = sp.store_code AND s.is_active
LEFT JOIN public.l2_last_counted lc ON lc.store_code = sp.store_code AND lc.product_code = sp.product_code
WHERE sp.class = 'NORMAL' AND sp.soh <> 0;
