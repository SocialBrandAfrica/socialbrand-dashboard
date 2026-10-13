CREATE OR REPLACE FUNCTION public.refresh_l2_last_counted(p_store text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_rows int;
BEGIN
  DELETE FROM public.l2_last_counted WHERE store_code = p_store;

  INSERT INTO public.l2_last_counted (store_code, product_code, last_counted_date, last_counted_soh, counted_91d)
  SELECT DISTINCT ON (m.store_code, m.product_code)
    m.store_code, m.product_code, m.movement_date, m.new_soh,
    (m.movement_date >= CURRENT_DATE - 91)
  FROM public.sigma_movements m
  WHERE m.store_code = p_store AND m.movement_type = 'I'
  ORDER BY m.store_code, m.product_code, m.movement_date DESC;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object('store_code', p_store, 'rows', v_rows,
    'seconds', ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_t0)::numeric, 1));
END;
$function$
